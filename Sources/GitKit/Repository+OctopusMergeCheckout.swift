import Foundation
import CGitKit

// The octopus merge's checkout and the files it writes
// (`Repository+OctopusMerge.swift`).
extension Repository {

    /// The paths `index` marks skip-worktree, which git keeps so when a
    /// merge updates them.
    func skipWorktreePaths(_ index: OpaquePointer?) -> [String] {
        (0..<git_index_entrycount(index)).compactMap { i -> String? in
            guard let entry = git_index_get_byindex(index, i)?.pointee,
                  entry.flags_extended & UInt16(GIT_INDEX_ENTRY_SKIP_WORKTREE.rawValue) != 0 else { return nil }
            return String(cString: entry.path)
        }
    }

    /// Set the skip-worktree bit again on those of `paths` whose entry
    /// the checkout rewrote without it.
    func keepSkipWorktree(_ paths: [String]) throws {
        var index: OpaquePointer?
        try check(git_repository_index(&index, repo))
        defer { git_index_free(index) }
        try check(git_index_read(index, 1))
        let bit = UInt16(GIT_INDEX_ENTRY_SKIP_WORKTREE.rawValue)
        let lost = paths.filter { path in
            guard let entry = git_index_get_bypath(index, path, 0) else { return false }
            return entry.pointee.flags_extended & bit == 0
        }
        for path in lost { try setSkipWorktree(true, path: path) }
    }

    /// HEAD's ref couldn't be moved: `lockFile` is in the way.
    struct HeadLocked: Error {
        let lockFile: String
    }

    /// Whether anything is at `path`, a symbolic link counted as itself
    /// even when what it points to is missing (lstat, not stat).
    static func exists(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }

    /// Check out what the merge changes and nothing else, as read-tree
    /// -u updates the entries it changes: a file deleted from the work
    /// tree is written again only where the merge changes it.
    func withCheckout(
        of paths: [String], strategy: UInt32, _ body: (inout git_checkout_options) throws -> Void
    ) throws {
        guard !paths.isEmpty else { return } // no paths would mean every path
        var options = git_checkout_options()
        try check(git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
        options.checkout_strategy = strategy | UInt32(GIT_CHECKOUT_RECREATE_MISSING.rawValue)
            | UInt32(GIT_CHECKOUT_DISABLE_PATHSPEC_MATCH.rawValue)
        var strings: [UnsafeMutablePointer<CChar>?] = paths.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        try strings.withUnsafeMutableBufferPointer { buffer in
            options.paths = git_strarray(strings: buffer.baseAddress, count: buffer.count)
            try body(&options)
        }
    }

    func checkOutConflicts(
        _ merged: OpaquePointer?, from headTree: git_oid, theirLabel: String, keepingOurs: [String],
        mergedContent: [String: git_oid] = [:]
    ) throws {
        // An unmerged path one side deleted has nothing to write where
        // the work tree no longer has it; libgit2 can't recreate it.
        let workdir = git_repository_workdir(repo).map { String(cString: $0) } ?? ""
        let changed = try changes(from: headTree, to: merged).keys.sorted(by: Self.indexOrder)
        // So has one our side lacks where a file HEAD doesn't track
        // stands: git-merge-one-file leaves that file alone.
        let skipped = try changed.filter { path in
            var ancestor, ours, theirs: UnsafePointer<git_index_entry>?
            guard git_index_conflict_get(&ancestor, &ours, &theirs, merged, path) == 0, ours == nil || theirs == nil
            else { return false }
            if !Self.exists(workdir + path) { return true }
            return try ours == nil && withTree(headTree) { try entry($0, path) == nil }
        }
        // A submodule the merge removes keeps its directory and files:
        // read-tree only tries rmdir. The index alone drops it.
        let removedGitlinks = Set(try withTree(headTree) { tree in
            try changed.filter { path in
                try entry(tree, path)?.mode == 0o160000
                    && (0...3).allSatisfy { git_index_get_bypath(merged, path, Int32($0)) == nil }
            }
        })
        let paths = changed.filter { !skipped.contains($0) && !removedGitlinks.contains($0) }
        // Side files libgit2 may write (`<path>~<label>`) that were there
        // before belong to the user.
        let sideFiles = try unmergedPaths(merged).flatMap { path in
            ["HEAD", theirLabel].map { path + "~" + $0 }
        }
        let preexisting = Set(sideFiles.filter { Self.exists(workdir + $0) })
        try withCheckout(of: paths, strategy: UInt32(GIT_CHECKOUT_SAFE.rawValue)
                         | UInt32(GIT_CHECKOUT_ALLOW_CONFLICTS.rawValue)) { options in
            try "HEAD".withCString { ours in
                try theirLabel.withCString { theirs in
                    options.our_label = ours
                    options.their_label = theirs
                    // Checkout writes the merged entries, conflicts and
                    // all, to the repository's index.
                    try check(git_checkout_index(repo, merged, &options))
                }
            }
        }
        // Their stages go to the index all the same, and a path the merge
        // deletes leaves it even where checkout kept its directory (a
        // submodule that still holds files).
        let deleted = changed.filter { path in
            (0...3).allSatisfy { git_index_get_bypath(merged, path, Int32($0)) == nil }
        }
        if !skipped.isEmpty || !deleted.isEmpty {
            var index: OpaquePointer?
            try check(git_repository_index(&index, repo))
            defer { git_index_free(index) }
            for path in deleted { _ = git_index_remove_bypath(index, path) }
            for path in skipped {
                var ancestor, ours, theirs: UnsafePointer<git_index_entry>?
                guard git_index_conflict_get(&ancestor, &ours, &theirs, merged, path) == 0 else { continue }
                _ = git_index_remove_bypath(index, path)
                try check(git_index_conflict_add(index, ancestor, ours, theirs))
            }
            try check(git_index_write(index))
        }
        try restoreWorkTree(merged, workdir: workdir, theirLabel: theirLabel, skipped: skipped,
                            keepingOurs: keepingOurs, mergedContent: mergedContent, preexisting: preexisting)
    }

    /// The work tree as git-merge-one-file leaves it where libgit2's
    /// checkout of `merged` differs: our side's content, merged content,
    /// files over directories, deleted paths and modes.
    func restoreWorkTree(
        _ merged: OpaquePointer?, workdir: String, theirLabel: String, skipped: [String], keepingOurs: [String],
        mergedContent: [String: git_oid], preexisting: Set<String>
    ) throws {
        let root = URL(fileURLWithPath: workdir)
        /// Write `oid` at `path` as an entry of `mode` is: a symbolic
        /// link, a submodule's (empty) directory, or a file, executable
        /// or not. Where a directory stands, a file isn't written.
        func write(_ oid: git_oid, mode: UInt32 = 0o100644, to path: String) throws {
            let url = root.appendingPathComponent(path)
            if mode == 0o160000 {
                if !Self.exists(url.path) {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                }
                return
            }
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if exists, isDirectory.boolValue { return }
            var oid = oid
            var blob: OpaquePointer?
            try check(git_blob_lookup(&blob, repo, &oid))
            defer { git_blob_free(blob) }
            let data = Data(bytes: git_blob_rawcontent(blob), count: Int(git_blob_rawsize(blob)))
            if Self.exists(url.path) { try FileManager.default.removeItem(at: url) }
            if mode == 0o120000 {
                try FileManager.default.createSymbolicLink(atPath: url.path,
                                                           withDestinationPath: String(decoding: data, as: UTF8.self))
                return
            }
            try data.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: mode == 0o100755 ? 0o755 : 0o644],
                                                  ofItemAtPath: url.path)
        }
        // libgit2 writes a side's file next to a directory in its way as
        // `<path>~<label>`; git writes none.
        for path in try unmergedPaths(merged) {
            for label in ["HEAD", theirLabel] {
                let side = root.appendingPathComponent(path + "~" + label)
                let name = path + "~" + label
                if git_index_get_bypath(merged, name, 0) == nil, !preexisting.contains(name) {
                    try? FileManager.default.removeItem(at: side)
                }
            }
        }
        // git-merge-one-file leaves these with our side's content.
        // A merge that failed only on modes leaves its content.
        for (path, oid) in mergedContent { try write(oid, to: path) }
        // An unmerged path our side deleted stays deleted in the work
        // tree, as read-tree -u left it (a directory there stays).
        for path in try unmergedPaths(merged) {
            var ancestor, ours, theirs: UnsafePointer<git_index_entry>?
            guard git_index_conflict_get(&ancestor, &ours, &theirs, merged, path) == 0, ours == nil,
                  !skipped.contains(path) else { continue }
            let file = root.appendingPathComponent(path).path
            let type = (try? FileManager.default.attributesOfItem(atPath: file))?[.type] as? FileAttributeType
            if type == .typeRegular || type == .typeSymbolicLink { try FileManager.default.removeItem(atPath: file) }
        }
        // An unmerged file keeps our side's mode, as read-tree -u wrote it.
        for path in try unmergedPaths(merged) {
            var ancestor, ours, theirs: UnsafePointer<git_index_entry>?
            guard git_index_conflict_get(&ancestor, &ours, &theirs, merged, path) == 0, let ours,
                  [0o100644, 0o100755].contains(ours.pointee.mode) else { continue }
            let file = root.appendingPathComponent(path).path
            guard (try? FileManager.default.attributesOfItem(atPath: file))?[.type] as? FileAttributeType
                    == .typeRegular else { continue }
            try FileManager.default.setAttributes(
                [.posixPermissions: ours.pointee.mode == 0o100755 ? 0o755 : 0o644], ofItemAtPath: file)
        }
        for path in keepingOurs {
            var ancestor, ours, theirs: UnsafePointer<git_index_entry>?
            guard git_index_conflict_get(&ancestor, &ours, &theirs, merged, path) == 0, let ours else { continue }
            // A submodule stays as checkout left it.
            if ours.pointee.mode == 0o160000 { continue }
            try write(ours.pointee.id, mode: ours.pointee.mode, to: path)
        }
        // A merged file where unmerged paths sit below it: read-tree
        // leaves the file, and git-merge-one-file can't add the rest.
        let unmerged = try unmergedPaths(merged)
        for i in 0..<git_index_entrycount(merged) {
            guard let entry = git_index_get_byindex(merged, i)?.pointee, (entry.flags >> 12) & 3 == 0 else { continue }
            let file = String(cString: entry.path)
            let below = unmerged.filter { $0.hasPrefix(file + "/") }
            guard !below.isEmpty else { continue }
            for path in below { try? FileManager.default.removeItem(at: root.appendingPathComponent(path)) }
            let directory = root.appendingPathComponent(file)
            if (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == false { continue }
            try? FileManager.default.removeItem(at: directory)
            try write(entry.id, mode: entry.mode, to: file)
        }
    }

    // MARK: Writing

    func writeOrigHead(_ head: git_oid) throws {
        var head = head
        var ref: OpaquePointer?
        try check(git_reference_create(&ref, repo, "ORIG_HEAD", &head, 1, nil))
        git_reference_free(ref)
    }

    /// `MERGE_HEAD`, `MERGE_MSG` and `MERGE_MODE`, as git leaves them
    /// for the commit that concludes a merge stopped by conflicts.
    func writeMergeState(oids: [git_oid], message: String, conflicts: [String], noFastForward: Bool) throws {
        guard let gitDir = try gitDir() else { return }
        let dir = URL(fileURLWithPath: gitDir)
        let heads = oids.map { oid -> String in
            var oid = oid
            return formatOID(&oid) + "\n"
        }.joined()
        try Data(heads.utf8).write(to: dir.appendingPathComponent("MERGE_HEAD"))
        // Every line commented, as strbuf_add_commented_lines does: the
        // path's first after a tab, any further after a space.
        let comment = try commentString()
        func commented(_ text: String) -> String {
            text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, line in
                index == 0 ? "\(comment)\t\(line)\n" : line.isEmpty ? "\(comment)\n" : "\(comment) \(line)\n"
            }.joined()
        }
        let text = conflicts.isEmpty ? message
            : message + "\n\n\(comment) Conflicts:\n" + conflicts.map(commented).joined()
        try Data(text.utf8).write(to: dir.appendingPathComponent("MERGE_MSG"))
        try Data((noFastForward ? "no-ff" : "").utf8).write(to: dir.appendingPathComponent("MERGE_MODE"))
    }

    /// What starts a comment line: the last of `core.commentChar` and
    /// `core.commentString` configured (one setting to git), else `#`,
    /// as is `auto` when git writes a merge's message.
    func commentString() throws -> String {
        var config: OpaquePointer?
        try check(git_repository_config_snapshot(&config, repo))
        defer { git_config_free(config) }
        var iterator: UnsafeMutablePointer<git_config_iterator>?
        try check(git_config_iterator_glob_new(&iterator, config, "^core\\.comment(char|string)$"))
        defer { git_config_iterator_free(iterator) }
        var value: String?
        var entry: UnsafeMutablePointer<git_config_entry>?
        while git_config_next(&entry, iterator) == 0, let entry {
            value = entry.pointee.value.map { String(cString: $0) }
        }
        guard let value, !value.isEmpty, value.lowercased() != "auto" else { return "#" }
        return value
    }

    /// Check out `tree` and commit it on HEAD with `parents`.
    func commitMerge(
        tree: git_oid, from headTree: git_oid, parents: [git_oid], message: String, author: Signature?,
        env: [String: String]
    ) throws -> String {
        // A path the merge deletes that the work tree no longer has is
        // only the index's business; libgit2 can't "recreate" it.
        let workdir = git_repository_workdir(repo).map { String(cString: $0) } ?? ""
        let changed = try diffEntries(headTree, tree)
        // …and so does a submodule the merge removes, whose directory
        // and files stay as read-tree leaves them.
        let gone = try withTree(headTree) { head in
            try changed.filter { path, change in
                guard change.oid == nil else { return false }
                if !Self.exists(workdir + path) { return true }
                return try entry(head, path)?.mode == 0o160000
            }
        }
        let paths = changed.keys.filter { gone[$0] == nil }.sorted(by: Self.indexOrder)
        var commits: [OpaquePointer?] = []
        defer { commits.forEach { git_commit_free($0) } }
        for parent in parents {
            var oid = parent
            var commit: OpaquePointer?
            try check(git_commit_lookup(&commit, repo, &oid))
            commits.append(commit)
        }
        let authorSig = try SignatureResolver.resolve(role: .author, override: author, repo: repo, env: env)
        defer { git_signature_free(authorSig) }
        let committerSig = try SignatureResolver.resolve(role: .committer, repo: repo, env: env)
        defer { git_signature_free(committerSig) }

        return try withTree(tree) { tree in
            try withCheckout(of: paths, strategy: UInt32(GIT_CHECKOUT_SAFE.rawValue)) { options in
                try check(git_checkout_tree(repo, tree, &options))
            }
            if !gone.isEmpty {
                var index: OpaquePointer?
                try check(git_repository_index(&index, repo))
                defer { git_index_free(index) }
                for path in gone.keys { _ = git_index_remove_bypath(index, path) }
                try check(git_index_write(index))
            }
            var commitOID = git_oid()
            _ = try commits.withUnsafeMutableBufferPointer { buffer in
                try message.withCString { text in
                    try check(git_commit_create(
                        &commitOID, repo, nil, authorSig, committerSig, nil,
                        text, tree, buffer.count, buffer.baseAddress))
                }
            }
            // HEAD need not be the first parent, so move it by hand.
            let reflog = "merge: Merge made by the 'octopus' strategy."
            var head: OpaquePointer?
            try check(git_repository_head(&head, repo))
            defer { git_reference_free(head) }
            // A symbolic HEAD moves whatever it names (a branch, or any
            // other ref); only a detached HEAD is set itself.
            let detached = git_repository_head_detached(repo) != 0
            let rc: Int32
            if !detached {
                var moved: OpaquePointer?
                rc = git_reference_set_target(&moved, head, &commitOID, reflog)
                git_reference_free(moved)
            } else {
                rc = git_repository_set_head_detached(repo, &commitOID)
            }
            if rc < 0 {
                // Another process holds the ref's lock: git leaves the
                // merge for `git commit` to conclude.
                let directory = detached ? git_repository_path(repo) : git_repository_commondir(repo)
                let lock = (directory.map { String(cString: $0) } ?? "")
                    + (detached ? "HEAD" : String(cString: git_reference_name(head))) + ".lock"
                if Self.exists(lock) { throw HeadLocked(lockFile: lock) }
                try check(rc)
            }
            return formatOID(&commitOID)
        }
    }

    func mergeStats(from old: git_oid, to new: git_oid) throws
        -> (summary: String, added: [String], deleted: [String]) {
        try withTree(old) { old in
            try withTree(new) { new in
                var diff: OpaquePointer?
                try check(git_diff_tree_to_tree(&diff, repo, old, new, nil))
                defer { git_diff_free(diff) }
                var stats: OpaquePointer?
                try check(git_diff_get_stats(&stats, diff))
                defer { git_diff_stats_free(stats) }
                var buf = git_buf()
                try check(git_diff_stats_to_buf(&buf, stats, GIT_DIFF_STATS_FULL, 80))
                defer { git_buf_dispose(&buf) }
                let summary = (buf.ptr.map { String(cString: $0) } ?? "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
                var added: [String] = [], deleted: [String] = []
                for i in 0..<git_diff_num_deltas(diff) {
                    guard let delta = git_diff_get_delta(diff, i)?.pointee else { continue }
                    if delta.status == GIT_DELTA_ADDED {
                        added.append(" create mode \(String(format: "%06o", delta.new_file.mode)) "
                                     + String(cString: delta.new_file.path))
                    } else if delta.status == GIT_DELTA_DELETED {
                        deleted.append(" delete mode \(String(format: "%06o", delta.old_file.mode)) "
                                       + String(cString: delta.old_file.path))
                    }
                }
                return (summary, added, deleted)
            }
        }
    }
}

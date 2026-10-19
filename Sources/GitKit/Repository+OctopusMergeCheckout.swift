import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif
import CGitKit

#if !os(Windows)
/// Create `path` as a new file with mode 0777 (less the umask); outside
/// `Repository`, whose `open` would shadow open(2).
private func createScratchFile(_ path: String) -> Bool {
    let fd = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o777)
    guard fd >= 0 else { return false }
    close(fd)
    return true
}
#endif

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
    struct HeadNotUpdated: Error {
        let lockFile: String
        let reason: String
    }

    /// HEAD's ref moved on while the merge was made.
    struct HeadMoved: Error {
        let expected: String
        let actual: String
    }

    /// Give the file at `path` the permissions checkout creates a file
    /// with in its directory, executable or not.
    static func setExecutable(_ executable: Bool, at path: String, modes: CreationModeCache) throws {
        let created = modes.modes(for: path)
        let mode = executable ? created.executable : created.plain
        let current = (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? 0
        if mode != current { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path) }
    }

    /// The permissions git's checkout gives a new file: 0666, or 0777
    /// for an executable, less the umask, each bit on its own.
    struct CreationModes {
        let plain: Int
        let executable: Int
    }

    /// Creation modes per directory: a directory's default ACL or the
    /// filesystem may give its new files other permissions than the
    /// umask alone, so each file's own directory is asked.
    final class CreationModeCache {
        private var byDirectory: [String: CreationModes] = [:]

        func modes(for file: String) -> CreationModes {
            let directory = (file as NSString).deletingLastPathComponent
            if let modes = byDirectory[directory] { return modes }
            let modes = Repository.creationModes(in: directory)
            byDirectory[directory] = modes
            return modes
        }
    }

    /// Learned from a scratch file the kernel creates as 0777 in
    /// `directory`, so the umask is never set (which every thread would
    /// see) to be read.
    static func creationModes(in directory: String) -> CreationModes {
        #if os(Windows)
        return CreationModes(plain: 0o644, executable: 0o755)
        #else
        let probe = (directory as NSString).appendingPathComponent(".gitkit-mode-\(UUID().uuidString)")
        guard createScratchFile(probe) else { return CreationModes(plain: 0o644, executable: 0o755) }
        defer { unlink(probe) }
        let mode = ((try? FileManager.default.attributesOfItem(atPath: probe))?[.posixPermissions] as? Int) ?? 0o755
        return CreationModes(plain: mode & 0o666, executable: mode & 0o777)
        #endif
    }

    /// Whether anything is at `path`, a symbolic link counted as itself
    /// even when what it points to is missing (lstat, not stat).
    static func exists(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }

    /// Check out what the merge changes and nothing else, as read-tree
    /// -u updates the entries it changes: a file deleted from the work
    /// tree is written again only where the merge changes it. `target`
    /// gives a path's merged entry, for those a sparse checkout keeps out.
    func withCheckout(
        of paths: [String], strategy: UInt32, target: (String) throws -> Entry?,
        _ body: (inout git_checkout_options) throws -> Void
    ) throws {
        // In a sparse checkout, a merged path outside it stays out of the
        // work tree: unpack-trees updates only its index entry.
        let workdir = git_repository_workdir(repo).map { String(cString: $0) } ?? ""
        let outside = try sparseExclusions(of: paths, workdir: workdir).compactMap { path in
            try target(path).map { (path, $0) }
        }
        let skipped = Set(outside.map(\.0))
        // libgit2's safe checkout refuses skip-worktree and assume-
        // unchanged entries; the preflight has found them up to date, as
        // read-tree requires, so they are checked out by force.
        let hidden = Set(try hiddenPaths())
        let wanted = paths.filter { !skipped.contains($0) }
        try checkout(wanted.filter { !hidden.contains($0) }, strategy: strategy, body)
        let force = (strategy & ~UInt32(GIT_CHECKOUT_SAFE.rawValue)) | UInt32(GIT_CHECKOUT_FORCE.rawValue)
        try checkout(wanted.filter(hidden.contains), strategy: force, body)
        try recordOutsideWorkTree(outside)
    }

    private func checkout(
        _ paths: [String], strategy: UInt32, _ body: (inout git_checkout_options) throws -> Void
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

    /// The index's skip-worktree and assume-unchanged paths.
    func hiddenPaths() throws -> [String] {
        var index: OpaquePointer?
        try check(git_repository_index(&index, repo))
        defer { git_index_free(index) }
        return (0..<git_index_entrycount(index)).compactMap { i -> String? in
            guard let entry = git_index_get_byindex(index, i)?.pointee,
                  entry.flags_extended & UInt16(GIT_INDEX_ENTRY_SKIP_WORKTREE.rawValue) != 0
                    || entry.flags & UInt16(GIT_INDEX_ENTRY_VALID.rawValue) != 0 else { return nil }
            return String(cString: entry.path)
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
        let mergedEntry = { (path: String) -> Entry? in
            git_index_get_bypath(merged, path, 0).map { Entry(oid: $0.pointee.id, mode: $0.pointee.mode) }
        }
        try withCheckout(of: paths, strategy: UInt32(GIT_CHECKOUT_SAFE.rawValue)
                         | UInt32(GIT_CHECKOUT_ALLOW_CONFLICTS.rawValue), target: mergedEntry) { options in
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
        let modes = CreationModeCache()
        let symlinks = (try? honorsSymlinks()) ?? true
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
            if Self.exists(url.path) { try FileManager.default.removeItem(at: url) }
            if mode == 0o120000, !symlinks {
                // core.symlinks=false: a file holding the link's target.
                try Data(bytes: git_blob_rawcontent(blob), count: Int(git_blob_rawsize(blob))).write(to: url)
                try Self.setExecutable(false, at: url.path, modes: modes)
                return
            }
            if mode == 0o120000 {
                // The target's bytes as they are: git allows any but NUL.
                let bytes = UnsafeRawBufferPointer(start: git_blob_rawcontent(blob), count: Int(git_blob_rawsize(blob)))
                var target = Array(bytes.bindMemory(to: CChar.self))
                target.append(0)
                #if os(Windows)
                try FileManager.default.createSymbolicLink(atPath: url.path,
                                                           withDestinationPath: String(cString: target))
                #else
                guard symlink(target, url.path) == 0 else {
                    throw Libgit2Error(code: -1, klass: 0, message: "unable to create symlink '\(path)'")
                }
                #endif
                return
            }
            // Through the checkout filters (eol, smudge, …), as checkout
            // writes a file.
            var options = git_blob_filter_options()
            try check(git_blob_filter_options_init(&options, UInt32(GIT_BLOB_FILTER_OPTIONS_VERSION)))
            var buffer = git_buf()
            try check(git_blob_filter(&buffer, blob, path, &options))
            defer { git_buf_dispose(&buffer) }
            let data = buffer.ptr.map { Data(bytes: $0, count: buffer.size) } ?? Data()
            try data.write(to: url)
            try Self.setExecutable(mode == 0o100755, at: url.path, modes: modes)
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
            try Self.setExecutable(ours.pointee.mode == 0o100755, at: file, modes: modes)
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

    /// Check out `tree` and commit it on HEAD with `parents`, moving
    /// HEAD from `start`, the commit the merge began at.
    func commitMerge(
        tree: git_oid, from headTree: git_oid, start: git_oid, parents: [git_oid], message: String,
        author: Signature?, env: [String: String]
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
            let target = { (path: String) throws -> Entry? in try self.entry(tree, path) }
            try withCheckout(of: paths, strategy: UInt32(GIT_CHECKOUT_SAFE.rawValue), target: target) { options in
                try check(git_checkout_tree(repo, tree, &options))
            }
            if !gone.isEmpty {
                var index: OpaquePointer?
                try check(git_repository_index(&index, repo))
                defer { git_index_free(index) }
                for path in gone.keys { _ = git_index_remove_bypath(index, path) }
                try check(git_index_write(index))
                // A removed submodule's directory goes when it's empty, as
                // unpack-trees' rmdir takes it; one with files stays.
                for path in gone.keys {
                    let dir = workdir + path, files = FileManager.default
                    guard (try? files.attributesOfItem(atPath: dir))?[.type] as? FileAttributeType == .typeDirectory,
                          (try? files.contentsOfDirectory(atPath: dir))?.isEmpty == true else { continue }
                    try? files.removeItem(atPath: dir)
                }
            }
            var commitOID = git_oid()
            _ = try commits.withUnsafeMutableBufferPointer { buffer in
                try message.withCString { text in
                    try check(git_commit_create(
                        &commitOID, repo, nil, authorSig, committerSig, nil,
                        text, tree, buffer.count, buffer.baseAddress))
                }
            }
            // HEAD need not be the first parent, so move it by hand, and
            // only from where the merge began, as git's update_ref checks.
            let reflog = "merge: Merge made by the 'octopus' strategy."
            var head: OpaquePointer?
            try check(git_repository_head(&head, repo))
            defer { git_reference_free(head) }
            // A symbolic HEAD moves whatever it names (a branch, or any
            // other ref); only a detached HEAD is set itself.
            let detached = git_repository_head_detached(repo) != 0
            let name = detached ? "HEAD" : String(cString: git_reference_name(head))
            var expected = start
            var moved: OpaquePointer?
            let rc = git_reference_create_matching(&moved, repo, name, &commitOID, 1, &expected, reflog)
            git_reference_free(moved)
            if rc == GIT_EMODIFIED.rawValue, let actual = git_reference_target(head) {
                var actual = actual.pointee
                throw HeadMoved(expected: formatOID(&expected), actual: formatOID(&actual))
            }
            if rc < 0 {
                // The merge is checked out but HEAD can't move (another
                // process holds the lock, or it can't be created): git
                // leaves the merge for `git commit` to conclude.
                let directory = detached ? git_repository_path(repo) : git_repository_commondir(repo)
                let lock = (directory.map { String(cString: $0) } ?? "") + name + ".lock"
                let message = Libgit2Error.last(code: rc).message
                let reason = Self.exists(lock) ? "File exists"
                    : message.range(of: "': ", options: .backwards).map { String(message[$0.upperBound...]) } ?? message
                throw HeadNotUpdated(lockFile: lock, reason: reason)
            }
            return formatOID(&commitOID)
        }
    }
}

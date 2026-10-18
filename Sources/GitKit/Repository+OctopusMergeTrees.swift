import Foundation
import CGitKit

// The octopus merge's work on trees, the index and the working tree
// (`Repository+OctopusMerge.swift`).
extension Repository {

    // MARK: Trees

    /// One path's change between two trees, or a tree and an index.
    struct Change: Equatable {
        /// The object name after, `nil` where the path is gone.
        let oid: String?
        let mode: UInt32
    }

    /// The paths that differ between trees `from` and `to`, renames not
    /// looked for, as `read-tree` sees them.
    func diffEntries(_ from: git_oid, _ to: git_oid) throws -> [String: Change] {
        try withTree(from) { old in
            try withTree(to) { new in
                var diff: OpaquePointer?
                try check(git_diff_tree_to_tree(&diff, repo, old, new, nil))
                defer { git_diff_free(diff) }
                var changes: [String: Change] = [:]
                for i in 0..<git_diff_num_deltas(diff) {
                    guard let delta = git_diff_get_delta(diff, i)?.pointee else { continue }
                    var newID = delta.new_file.id
                    let path = String(cString: delta.new_file.path ?? delta.old_file.path)
                    changes[path] = Change(
                        oid: delta.status == GIT_DELTA_DELETED ? nil : formatOID(&newID),
                        mode: UInt32(delta.new_file.mode))
                }
                return changes
            }
        }
    }

    /// One path's entry in a tree.
    struct Entry: Equatable {
        let oid: git_oid
        let mode: UInt32
        var hex: String {
            var oid = oid
            return withUnsafePointer(to: &oid) { pointer in
                var text = [CChar](repeating: 0, count: 41)
                git_oid_tostr(&text, 41, pointer)
                return String(cString: text)
            }
        }
        static func == (lhs: Entry, rhs: Entry) -> Bool {
            var a = lhs.oid, b = rhs.oid
            return lhs.mode == rhs.mode && git_oid_equal(&a, &b) == 1
        }
    }

    /// What read-tree's three-way merge (`--aggressive`, every best base
    /// at once) leaves for git-merge-one-file, in index order: the paths
    /// both sides changed, differently, where a side changed a path
    /// unless it has it as one of the bases does. A side that has it as
    /// one base and the other side as another leaves it unmerged with no
    /// ancestor, as if both had added it. `merged`, libgit2's merge,
    /// gets git's conflicts for paths it resolved otherwise.
    func unmerged(
        bases: [git_oid], ours: git_oid, theirs: git_oid, merged: OpaquePointer?
    ) throws -> [OctopusPathMerge] {
        var paths: Set<String> = []
        for base in bases {
            paths.formUnion(try diffEntries(base, ours).keys)
            paths.formUnion(try diffEntries(base, theirs).keys)
        }
        let emptyBlobMissing = !(try hasEmptyBlob())
        var result: [OctopusPathMerge] = []
        try withTrees([ours, theirs] + bases) { trees in
            for path in paths.sorted(by: Self.indexOrder) {
                let our = try entry(trees[0], path), their = try entry(trees[1], path)
                guard our != their else { continue }
                let baseEntries = try trees.dropFirst(2).map { try entry($0, path) }
                let oursKept = baseEntries.contains(our), theirsKept = baseEntries.contains(their)
                if oursKept != theirsKept { continue }
                var ancestor = oursKept ? nil : baseEntries.first ?? nil
                if baseEntries.contains(where: { $0 == nil }) { ancestor = nil }
                if our != nil, their != nil, ancestor != nil {
                    var a: UnsafePointer<git_index_entry>?, o: UnsafePointer<git_index_entry>?
                    var t: UnsafePointer<git_index_entry>?
                    let conflicted = git_index_conflict_get(&a, &o, &t, merged, path) == 0
                    result.append(conflicted ? .conflict(path: path) : .merged(path: path))
                    continue
                }
                if our != nil, their != nil {
                    result.append(.addedInBoth(path: path, emptyBlobMissing: emptyBlobMissing))
                } else {
                    result.append(.notHandled(path: path, base: ancestor?.hex ?? "",
                                              ours: our?.hex ?? "", theirs: their?.hex ?? ""))
                }
                // git-merge-one-file always fails these.
                try conflict(path, ancestor: ancestor, ours: our, theirs: their, in: merged)
            }
        }
        // A file where the other side has a directory: libgit2 leaves it
        // unmerged, and git reports their side's path.
        let reported = Set(result.map(\.path))
        for path in try unmergedPaths(merged) where !reported.contains(path) {
            guard let other = paths.first(where: { $0.hasPrefix(path + "/") || path.hasPrefix($0 + "/") })
            else { continue }
            let theirPath = try withTrees([theirs, ours]) { trees in
                try entry(trees[0], path) != nil && entry(trees[1], path) == nil ? path : other
            }
            let file = path.count > other.count ? other : path
            let deeper = paths.filter { $0.hasPrefix(file + "/") }
            result.append(.addedOverDirectory(path: theirPath, file: deeper.sorted(by: Self.indexOrder).first ?? other))
            // As read-tree leaves it: the file merged, the paths below it
            // unmerged with the side that has them.
            try withTrees([ours, theirs]) { trees in
                guard let fileEntry = try entry(trees[0], file) ?? entry(trees[1], file) else { return }
                _ = git_index_conflict_remove(merged, file)
                _ = git_index_remove_bypath(merged, file)
                for path in deeper {
                    let our = try entry(trees[0], path), their = try entry(trees[1], path)
                    _ = git_index_remove_bypath(merged, path)
                    try conflict(path, ancestor: nil, ours: our, theirs: their, in: merged)
                }
                var added = git_index_entry()
                added.id = fileEntry.oid
                added.mode = fileEntry.mode
                try file.withCString { cPath in
                    added.path = cPath
                    try check(git_index_add(merged, &added))
                }
            }
        }
        return result.sorted { Self.indexOrder($0.path, $1.path) }
    }

    func withTrees<T>(_ oids: [git_oid], _ body: ([OpaquePointer?]) throws -> T) throws -> T {
        var trees: [OpaquePointer?] = []
        defer { trees.forEach { git_tree_free($0) } }
        for oid in oids {
            var oid = oid
            var tree: OpaquePointer?
            try check(git_tree_lookup(&tree, repo, &oid))
            trees.append(tree)
        }
        return try body(trees)
    }

    func entry(_ tree: OpaquePointer?, _ path: String) throws -> Entry? {
        var entry: OpaquePointer?
        let rc = git_tree_entry_bypath(&entry, tree, path)
        if rc == GIT_ENOTFOUND.rawValue { return nil }
        try check(rc)
        defer { git_tree_entry_free(entry) }
        if git_tree_entry_type(entry) == GIT_OBJECT_TREE { return nil }
        return Entry(oid: git_tree_entry_id(entry).pointee, mode: UInt32(git_tree_entry_filemode(entry).rawValue))
    }

    func hasEmptyBlob() throws -> Bool {
        var oid = git_oid()
        var odb: OpaquePointer?
        try check(git_repository_odb(&odb, repo))
        defer { git_odb_free(odb) }
        try check(git_odb_hash(&oid, "", 0, GIT_OBJECT_BLOB))
        return git_odb_exists(odb, &oid) == 1
    }

    /// Replace `path` in `index` with an unmerged entry, stages for the
    /// sides that have it.
    func conflict(
        _ path: String, ancestor: Entry?, ours: Entry?, theirs: Entry?, in index: OpaquePointer?
    ) throws {
        _ = git_index_conflict_remove(index, path)
        _ = git_index_remove_bypath(index, path)
        try path.withCString { cPath in
            func make(_ entry: Entry?) -> git_index_entry? {
                guard let entry else { return nil }
                var made = git_index_entry()
                made.id = entry.oid
                made.mode = entry.mode
                made.path = cPath
                return made
            }
            var a = make(ancestor), o = make(ours), t = make(theirs)
            func pointer(
                _ entry: inout git_index_entry?, _ body: (UnsafePointer<git_index_entry>?) throws -> Void
            ) rethrows {
                if entry == nil { try body(nil) } else { try withUnsafePointer(to: &entry!) { try body($0) } }
            }
            try pointer(&a) { ap in
                try pointer(&o) { op in
                    try pointer(&t) { tp in try check(git_index_conflict_add(index, ap, op, tp)) }
                }
            }
        }
    }

    /// What `index` changes relative to `tree`: each path's new object,
    /// `nil` where it is gone, an unmerged path as written.
    func changes(from tree: git_oid, to index: OpaquePointer?) throws -> [String: Change] {
        var changes: [String: Change] = [:]
        try withTree(tree) { tree in
            var diff: OpaquePointer?
            try check(git_diff_tree_to_index(&diff, repo, tree, index, nil))
            defer { git_diff_free(diff) }
            for i in 0..<git_diff_num_deltas(diff) {
                guard let delta = git_diff_get_delta(diff, i)?.pointee else { continue }
                var newID = delta.new_file.id
                let path = String(cString: delta.new_file.path ?? delta.old_file.path)
                changes[path] = Change(oid: delta.status == GIT_DELTA_DELETED ? nil : formatOID(&newID),
                                       mode: UInt32(delta.new_file.mode))
            }
        }
        for path in try unmergedPaths(index) where changes[path] == nil {
            changes[path] = Change(oid: "", mode: 0)
        }
        return changes
    }

    /// The tree to merge against: the one base's, else the bases merged
    /// one into the other, each pair against their own bases merged the
    /// same way (git's recursive strategy), conflicts kept as markers
    /// (libgit2's virtual base).
    func virtualBase(_ bases: [git_oid]) throws -> git_oid? {
        guard let first = bases.first else { return nil }
        var virtual = try treeOID(ofCommit: first)
        var merged = [first]
        for base in bases.dropFirst() {
            let ancestor = try virtualBase(try mergeBases(base, merged))
            let index = try mergeTrees(base: ancestor, ours: virtual, theirs: try treeOID(ofCommit: base),
                                       virtualBase: true)
            defer { git_index_free(index) }
            var oid = git_oid()
            try check(git_index_write_tree_to(&oid, index, repo))
            virtual = oid
            merged.append(base)
        }
        return virtual
    }

    func mergeTrees(base: git_oid?, ours: git_oid, theirs: git_oid, virtualBase: Bool = false) throws
        -> OpaquePointer? {
        var options = git_merge_options()
        try check(git_merge_options_init(&options, UInt32(GIT_MERGE_OPTIONS_VERSION)))
        // No rename detection, as read-tree and merge-one-file.
        options.flags = virtualBase ? UInt32(GIT_MERGE_VIRTUAL_BASE.rawValue) : 0
        func merge(_ base: OpaquePointer?) throws -> OpaquePointer? {
            try withTree(ours) { ours in
                try withTree(theirs) { theirs in
                    var index: OpaquePointer?
                    try check(git_merge_trees(&index, repo, base, ours, theirs, &options))
                    return index
                }
            }
        }
        guard let base else { return try merge(nil) }
        return try withTree(base) { try merge($0) }
    }

    /// git's index order: byte-wise by path.
    static func indexOrder(_ a: String, _ b: String) -> Bool {
        Array(a.utf8).lexicographicallyPrecedes(Array(b.utf8))
    }

    func unmergedPaths(_ index: OpaquePointer?) throws -> [String] {
        var iterator: OpaquePointer?
        try check(git_index_conflict_iterator_new(&iterator, index))
        defer { git_index_conflict_iterator_free(iterator) }
        var paths: [String] = []
        while true {
            var ancestor: UnsafePointer<git_index_entry>?
            var ours: UnsafePointer<git_index_entry>?
            var theirs: UnsafePointer<git_index_entry>?
            let rc = git_index_conflict_next(&ancestor, &ours, &theirs, iterator)
            if rc == GIT_ITEROVER.rawValue { break }
            try check(rc)
            if let path = (ours ?? theirs ?? ancestor)?.pointee.path { paths.append(String(cString: path)) }
        }
        return paths
    }

    // MARK: Index and working tree

    func changedPaths(from tree: git_oid, toIndex index: OpaquePointer?) throws -> [String] {
        try withTree(tree) { tree in
            var diff: OpaquePointer?
            try check(git_diff_tree_to_index(&diff, repo, tree, index, nil))
            defer { git_diff_free(diff) }
            return (0..<git_diff_num_deltas(diff)).compactMap { i in
                git_diff_get_delta(diff, i).map { delta in
                    String(cString: delta.pointee.new_file.path ?? delta.pointee.old_file.path)
                }
            }.sorted(by: Self.indexOrder)
        }
    }

    /// Working tree paths that differ from the index: `true` for a file
    /// the index doesn't track.
    func workingTreeChanges(index: OpaquePointer?) throws -> [String: Bool] {
        guard git_repository_is_bare(repo) == 0 else { return [:] }
        var options = git_diff_options()
        try check(git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION)))
        options.flags = UInt32(GIT_DIFF_INCLUDE_UNTRACKED.rawValue) | UInt32(GIT_DIFF_RECURSE_UNTRACKED_DIRS.rawValue)
        var diff: OpaquePointer?
        try check(git_diff_index_to_workdir(&diff, repo, index, &options))
        defer { git_diff_free(diff) }
        var changes: [String: Bool] = [:]
        for i in 0..<git_diff_num_deltas(diff) {
            guard let delta = git_diff_get_delta(diff, i)?.pointee else { continue }
            changes[String(cString: delta.new_file.path ?? delta.old_file.path)] = delta.status == GIT_DELTA_UNTRACKED
        }
        return changes
    }

    /// The first of `paths` (in index order) whose working tree change a
    /// merge step would overwrite, as `read-tree -u -m` refuses it.
    /// Earlier steps would have stopped at any path they changed, so the
    /// working tree as the merge found it is what counts.
    /// A path the step writes a file to also collides with untracked
    /// files below it, or with an untracked file where one of its
    /// directories goes.
    func overwrites(_ changes: [String: Change], worktree: [String: Bool]) -> OctopusMergeFailure? {
        let untracked = worktree.filter(\.value).keys.sorted(by: Self.indexOrder)
        for (path, change) in changes.sorted(by: { Self.indexOrder($0.key, $1.key) }) {
            if let isUntracked = worktree[path] {
                return isUntracked ? .untrackedWouldBeOverwritten(path: path) : .notUpToDate(path: path)
            }
            guard change.oid != nil else { continue }
            if untracked.contains(where: { $0.hasPrefix(path + "/") }) {
                return .untrackedFilesInDirectory(path: path)
            }
            if let file = untracked.first(where: { path.hasPrefix($0 + "/") }) {
                return .untrackedWouldBeOverwritten(path: file)
            }
        }
        return nil
    }

    func checkOutConflicts(_ merged: OpaquePointer?, theirLabel: String, keepingOurs: [String]) throws {
        var options = git_checkout_options()
        try check(git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
        options.checkout_strategy = UInt32(GIT_CHECKOUT_SAFE.rawValue)
            | UInt32(GIT_CHECKOUT_ALLOW_CONFLICTS.rawValue)
        try "HEAD".withCString { ours in
            try theirLabel.withCString { theirs in
                options.our_label = ours
                options.their_label = theirs
                // Checkout writes the merged entries, conflicts and all,
                // to the repository's index.
                try check(git_checkout_index(repo, merged, &options))
            }
        }
        guard let workdir = git_repository_workdir(repo).map({ String(cString: $0) }) else { return }
        let root = URL(fileURLWithPath: workdir)
        func write(_ oid: git_oid, to path: String) throws {
            var oid = oid
            var blob: OpaquePointer?
            try check(git_blob_lookup(&blob, repo, &oid))
            defer { git_blob_free(blob) }
            let data = Data(bytes: git_blob_rawcontent(blob), count: Int(git_blob_rawsize(blob)))
            try data.write(to: root.appendingPathComponent(path))
        }
        // git-merge-one-file leaves these with our side's content.
        for path in keepingOurs {
            var ancestor, ours, theirs: UnsafePointer<git_index_entry>?
            guard git_index_conflict_get(&ancestor, &ours, &theirs, merged, path) == 0, let ours else { continue }
            try write(ours.pointee.id, to: path)
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
            try write(entry.id, to: file)
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
        let text = message + "\n\n# Conflicts:\n" + conflicts.map { "#\t\($0)\n" }.joined()
        try Data(text.utf8).write(to: dir.appendingPathComponent("MERGE_MSG"))
        try Data((noFastForward ? "no-ff" : "").utf8).write(to: dir.appendingPathComponent("MERGE_MODE"))
    }

    /// Check out `tree` and commit it on HEAD with `parents`.
    func commitMerge(
        tree: git_oid, parents: [git_oid], message: String, author: Signature?, env: [String: String]
    ) throws -> String {
        var options = git_checkout_options()
        try check(git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
        options.checkout_strategy = UInt32(GIT_CHECKOUT_SAFE.rawValue)
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
            try check(git_checkout_tree(repo, tree, &options))
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
            if git_reference_is_branch(head) == 1 {
                var moved: OpaquePointer?
                try check(git_reference_set_target(&moved, head, &commitOID, reflog))
                git_reference_free(moved)
            } else {
                try check(git_repository_set_head_detached(repo, &commitOID))
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

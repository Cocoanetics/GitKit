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
        bases: [git_oid], ours: git_oid, theirs: git_oid, merged: OpaquePointer?, headTree: git_oid,
        mergedContent: inout [String: git_oid]
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
                // read-tree keeps a base's entry as the ancestor even where
                // another base lacks the path.
                let ancestor = oursKept ? nil : baseEntries.compactMap { $0 }.first
                let modes: [UInt32] = [our?.mode, their?.mode].compactMap { $0 }
                let special = modes.contains(0o120000) || modes.contains(0o160000)
                if our != nil, their != nil, ancestor != nil, !special {
                    var a: UnsafePointer<git_index_entry>?, o: UnsafePointer<git_index_entry>?
                    var t: UnsafePointer<git_index_entry>?
                    let conflicted = git_index_conflict_get(&a, &o, &t, merged, path) == 0
                    // Modes that differ fail git-merge-one-file however
                    // the content merged, which stays in the work tree.
                    if let our, let their, let ancestor, our.mode != their.mode {
                        result.append(.permissionsConflict(
                            path: path, base: String(ancestor.mode, radix: 8), ours: String(our.mode, radix: 8),
                            theirs: String(their.mode, radix: 8), contentConflict: conflicted))
                        if !conflicted, let clean = git_index_get_bypath(merged, path, 0) {
                            mergedContent[path] = clean.pointee.id
                        }
                        try conflict(path, ancestor: ancestor, ours: our, theirs: their, in: merged)
                        continue
                    }
                    result.append(conflicted ? .conflict(path: path) : .merged(path: path))
                    continue
                }
                // Before anything else, git-merge-one-file refuses
                // symbolic links, then submodules.
                if let our, let their, [our.mode, their.mode].contains(0o120000) {
                    result.append(.symlink(path: path))
                } else if let our, let their, [our.mode, their.mode].contains(0o160000) {
                    result.append(.submodule(path: path))
                } else if let our, let their, ancestor == nil, our.hex == their.hex {
                    // "Added in both, identically" but for the mode.
                    result.append(.addedWithDifferentModes(path: path, ours: String(our.mode, radix: 8),
                                                           theirs: String(their.mode, radix: 8)))
                } else if our != nil, their != nil {
                    result.append(.addedInBoth(path: path, emptyBlobMissing: emptyBlobMissing))
                } else if let ancestor, let kept = our ?? their, kept.hex == ancestor.hex {
                    // Deleted on one side, only its mode changed on the other.
                    result.append(.deletedWithModeChange(path: path))
                } else {
                    result.append(.notHandled(path: path, base: ancestor?.hex ?? "",
                                              ours: our?.hex ?? "", theirs: their?.hex ?? ""))
                }
                // git-merge-one-file always fails these.
                try conflict(path, ancestor: ancestor, ours: our, theirs: their, in: merged)
            }
        }
        var reported = Set(result.map(\.path))
        try readTreeDirectoryFileCases(paths: paths, bases: bases, ours: ours, theirs: theirs, merged: merged,
                                       headTree: headTree, result: &result, reported: &reported)

        // A file where the other side has a directory: libgit2 leaves it
        // unmerged, and git reports their side's path.
        for path in try unmergedPaths(merged) where !reported.contains(path) {
            guard let other = paths.first(where: { $0.hasPrefix(path + "/") || path.hasPrefix($0 + "/") })
            else { continue }
            let theirPath = try withTrees([theirs, ours]) { trees in
                try entry(trees[0], path) != nil && entry(trees[1], path) == nil ? path : other
            }
            let file = path.count > other.count ? other : path
            let deeper = paths.filter { $0.hasPrefix(file + "/") }.sorted(by: Self.indexOrder)
            guard !reported.contains(file) else { continue }
            reported.formUnion([file] + deeper)
            // Their file: one `Adding`, every path below it refused;
            // their paths below the other side's file: one each.
            if theirPath == file {
                result.append(.addedOverDirectory(path: file, files: deeper))
            } else {
                result += deeper.map { .addedOverDirectory(path: $0, files: [$0]) }
            }
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

    /// Where a file and a directory meet over a file the base had,
    /// what read-tree leaves to git-merge-one-file beyond libgit2's
    /// conflicts: a file our side deleted for a directory (`.removed`),
    /// and a path their side adds below a file that doesn't stay.
    private func readTreeDirectoryFileCases(
        paths: Set<String>, bases: [git_oid], ours: git_oid, theirs: git_oid, merged: OpaquePointer?,
        headTree: git_oid, result: inout [OctopusPathMerge], reported: inout Set<String>
    ) throws {
        // A file our side deleted, the others kept, where our side now
        // has a directory: read-tree leaves it, and git-merge-one-file
        // removes it without a word.
        try withTrees([ours, theirs] + bases) { trees in
            for path in paths.sorted(by: Self.indexOrder) where !reported.contains(path) {
                guard try entry(trees[0], path) == nil, let their = try entry(trees[1], path),
                      try trees.dropFirst(2).allSatisfy({ try entry($0, path) == their }),
                      paths.contains(where: { $0.hasPrefix(path + "/") }),
                      try paths.contains(where: { try $0.hasPrefix(path + "/") && entry(trees[0], $0) != nil })
                else { continue }
                result.append(.removed(path: path))
                reported.insert(path)
            }
        }
        // A path their side adds below a file the base had (gone, or
        // unmerged): read-tree leaves it for git-merge-one-file, which
        // adds it.
        try withTrees([ours, theirs] + bases) { trees in
            for path in paths.sorted(by: Self.indexOrder) where !reported.contains(path) {
                guard try entry(trees[1], path) != nil, try entry(trees[0], path) == nil else { continue }
                var parents: [String] = []
                var parent = Substring(path)
                while let slash = parent.lastIndex(of: "/") {
                    parent = parent[..<slash]
                    parents.append(String(parent))
                }
                var inBase = false
                for base in trees.dropFirst(2) where !inBase {
                    inBase = try parents.contains { try entry(base, $0) != nil }
                }
                // …and the merge keeps no file there.
                guard inBase, parents.allSatisfy({ git_index_get_bypath(merged, $0, 0) == nil }) else { continue }
                // A submodule removed for the directory keeps its files.
                let workdir = git_repository_workdir(repo).map { String(cString: $0) } ?? ""
                for parent in parents where !reported.contains(parent) {
                    let gitlink = try ([trees[0]] + trees.dropFirst(2))
                        .contains { try entry($0, parent)?.mode == 0o160000 }
                    let listing = try? FileManager.default.contentsOfDirectory(atPath: workdir + parent)
                    let held = listing?.isEmpty == false
                    if gitlink, held {
                        result.append(.submoduleDirectoryKept(path: parent))
                        reported.insert(parent)
                    }
                }
                reported.insert(path)
                _ = git_index_conflict_remove(merged, path)
                // A file there the index doesn't track: git-merge-one-file
                // refuses to overwrite it, leaving their side unmerged.
                // Untracked: there on disk, and not a file of HEAD's, which
                // an earlier step's read-tree -u would have removed.
                let untracked = try Self.exists(workdir + path) && withTree(headTree) { try entry($0, path) == nil }
                if untracked, let their = try entry(trees[1], path) {
                    result.append(.addedOverUntracked(path: path))
                    try conflict(path, ancestor: nil, ours: nil, theirs: their, in: merged)
                    continue
                }
                result.append(.addedOverDirectory(path: path, files: []))
                // Added, in place of what libgit2 made of it.
                if let their = try entry(trees[1], path) {
                    var added = git_index_entry()
                    added.id = their.oid
                    added.mode = their.mode
                    try path.withCString { cPath in
                        added.path = cPath
                        try check(git_index_add(merged, &added))
                    }
                }
            }
        }
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
        // A submodule's own work tree is the submodule's business: the
        // merge moves only the superproject's gitlink.
        options.flags = UInt32(GIT_DIFF_INCLUDE_UNTRACKED.rawValue) | UInt32(GIT_DIFF_RECURSE_UNTRACKED_DIRS.rawValue)
            | UInt32(GIT_DIFF_IGNORE_SUBMODULES.rawValue)
        var diff: OpaquePointer?
        try check(git_diff_index_to_workdir(&diff, repo, index, &options))
        defer { git_diff_free(diff) }
        var changes: [String: Bool] = [:]
        // A skip-worktree or assume-unchanged entry's file is one diff no
        // longer looks at, but read-tree does: changed content there, or
        // a changed executable bit where core.filemode holds, is a local
        // change. A submodule's directory is the submodule's business.
        let workdir = git_repository_workdir(repo).map { String(cString: $0) } ?? ""
        let fileMode = try honorsFileMode()
        for i in 0..<git_index_entrycount(index) {
            guard let entry = git_index_get_byindex(index, i)?.pointee, entry.mode != 0o160000,
                  entry.flags_extended & UInt16(GIT_INDEX_ENTRY_SKIP_WORKTREE.rawValue) != 0
                    || entry.flags & UInt16(GIT_INDEX_ENTRY_VALID.rawValue) != 0 else { continue }
            let path = String(cString: entry.path)
            // Gone is up to date; otherwise what's there must be what
            // the entry records: a link's target, or a file's content.
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: workdir + path),
                  let type = attributes[.type] as? FileAttributeType else { continue }
            var actual = git_oid(), expected = entry.id
            if entry.mode == 0o120000 {
                guard type == .typeSymbolicLink, let bytes = Self.linkTarget(workdir + path)
                else { changes[path] = false; continue }
                try check(git_odb_hash(&actual, bytes, bytes.count, GIT_OBJECT_BLOB))
            } else {
                // Through the clean filters (eol, ident, …), as the index
                // records the content.
                guard type == .typeRegular,
                      git_repository_hashfile(&actual, repo, workdir + path, GIT_OBJECT_BLOB, path) == 0
                else { changes[path] = false; continue }
                let executable = ((attributes[.posixPermissions] as? Int) ?? 0) & 0o100 != 0
                if fileMode, executable != (entry.mode == 0o100755) { changes[path] = false; continue }
            }
            if git_oid_equal(&actual, &expected) == 0 { changes[path] = false }
        }
        for i in 0..<git_diff_num_deltas(diff) {
            // A file gone from the work tree has nothing to lose: git's
            // verify_uptodate takes it as up to date. Something else in
            // its place (a directory) is a change.
            guard let delta = git_diff_get_delta(diff, i)?.pointee else { continue }
            if delta.status == GIT_DELTA_DELETED,
               !Self.exists(workdir + String(cString: delta.old_file.path)) { continue }
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
    /// With `ignoreCase` (core.ignorecase), paths compare with ASCII case
    /// folded, as git's fspathcmp does; the failure names the path as
    /// the merge writes it.
    func overwrites(_ changes: [String: Change], worktree: [String: Bool], ignoreCase: Bool) -> OctopusMergeFailure? {
        func fold(_ path: String) -> String {
            ignoreCase ? String(decoding: path.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 }, as: UTF8.self)
                : path
        }
        var folded: [String: Bool] = [:]
        for (path, untracked) in worktree { folded[fold(path)] = untracked }
        let untracked = folded.filter(\.value).keys.sorted(by: Self.indexOrder)
        for (path, change) in changes.sorted(by: { Self.indexOrder($0.key, $1.key) }) {
            let key = fold(path)
            if let isUntracked = folded[key] {
                return isUntracked ? .untrackedWouldBeOverwritten(path: path) : .notUpToDate(path: path)
            }
            guard change.oid != nil else { continue }
            if untracked.contains(where: { $0.hasPrefix(key + "/") }) {
                return .untrackedFilesInDirectory(path: path)
            }
            if let file = untracked.first(where: { key.hasPrefix($0 + "/") }) {
                return .untrackedWouldBeOverwritten(path: String(path.utf8.prefix(file.utf8.count))!)
            }
        }
        return nil
    }

    /// Whether the executable bit counts (core.filemode, true unless set).
    func honorsFileMode() throws -> Bool {
        var config: OpaquePointer?
        try check(git_repository_config_snapshot(&config, repo))
        defer { git_config_free(config) }
        var value: Int32 = 1
        return git_config_get_bool(&value, config, "core.filemode") != 0 || value != 0
    }

    /// A symbolic link's target as its bytes, which needn't be UTF-8.
    static func linkTarget(_ path: String) -> [UInt8]? {
        #if os(Windows)
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: path)).map { Array($0.utf8) }
        #else
        var buffer = [CChar](repeating: 0, count: 4096)
        let count = readlink(path, &buffer, buffer.count)
        guard count >= 0 else { return nil }
        return buffer.prefix(count).map { UInt8(bitPattern: $0) }
        #endif
    }

    /// Whether the work tree folds case (core.ignorecase).
    func ignoresCase() throws -> Bool {
        var config: OpaquePointer?
        try check(git_repository_config_snapshot(&config, repo))
        defer { git_config_free(config) }
        var value: Int32 = 0
        return git_config_get_bool(&value, config, "core.ignorecase") == 0 && value != 0
    }
}

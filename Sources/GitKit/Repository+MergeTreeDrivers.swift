import Foundation
import CGitKit

// Fail-closed external merge driver inspection for `Repository.mergeTree(...)`.
// Covers both explicit-tree merges and commit merges (including every step of
// recursive virtual-base construction) against a mempack-backed handle so a
// refused driver never writes objects to disk.

private enum MergeInput {
    case empty
    case tree(OpaquePointer)
    case index(OpaquePointer)
}

private enum CommitOrVirtual {
    case real(git_oid)
    case virtual(index: OpaquePointer, parents: [git_oid])

    var headIDs: [git_oid] {
        switch self {
        case .real(let oid): [oid]
        case .virtual(_, let parents): parents
        }
    }
}

private struct DiffSideEntry {
    let oldPath: String?
    let newPath: String?
    let oid: git_oid
    let mode: UInt32
    let status: git_delta_t
}

extension Repository {

    func checkExternalDriversForTrees(
        base: git_oid?,
        ours: git_oid,
        theirs: git_oid,
        handle: MergeHandle,
        options: MergeTreeOptions
    ) throws {
        guard options.favor == .normal, !handle.configuredDrivers.isEmpty else { return }

        var baseTree: OpaquePointer?
        if var baseLookup = base {
            try check(git_tree_lookup(&baseTree, handle.checkRepo, &baseLookup))
        }
        defer { if baseTree != nil { git_tree_free(baseTree) } }

        var oursTree: OpaquePointer?
        var oursLookup = ours
        try check(git_tree_lookup(&oursTree, handle.checkRepo, &oursLookup))
        defer { git_tree_free(oursTree) }

        var theirsTree: OpaquePointer?
        var theirsLookup = theirs
        try check(git_tree_lookup(&theirsTree, handle.checkRepo, &theirsLookup))
        defer { git_tree_free(theirsTree) }

        guard let oursTree, let theirsTree else { return }
        let baseInput: MergeInput = baseTree.map { .tree($0) } ?? .empty
        try checkExternalDrivers(
            base: baseInput, ours: .tree(oursTree), theirs: .tree(theirsTree),
            handle: handle, options: options)
    }

    func checkExternalDriversForCommits(
        ours: git_oid,
        theirs: git_oid,
        handle: MergeHandle,
        options: MergeTreeOptions
    ) throws {
        guard options.favor == .normal, !handle.configuredDrivers.isEmpty else { return }
        _ = try inspectCommitMergeDrivers(
            ours: .real(ours), theirs: .real(theirs),
            buildVirtualResult: false, handle: handle, options: options)
    }

    /// Mirrors libgit2's `merge_annotated_commits` / `compute_base` recursion
    /// on the mempack-backed `checkRepo` so every recursive virtual-base merge
    /// step and the final top-level merge are checked before any external
    /// driver could be invoked.
    private func inspectCommitMergeDrivers(
        ours: CommitOrVirtual,
        theirs: CommitOrVirtual,
        buildVirtualResult: Bool,
        handle: MergeHandle,
        options: MergeTreeOptions
    ) throws -> OpaquePointer? {
        try Task.checkCancellation()

        // Matches merge.c:2341: insert theirs head IDs, then ours head IDs.
        let bases = try mergeBasesManyList(on: handle.checkRepo, ids: theirs.headIDs + ours.headIDs)

        let computedBase: CommitOrVirtual?
        if bases.isEmpty {
            computedBase = nil
        } else if !options.recursiveBases || bases.count == 1 {
            computedBase = .real(bases[0])
        } else {
            let reversed = Array(bases.reversed())
            var current: CommitOrVirtual = .real(reversed[0])
            var ownedVirtualIndices: [OpaquePointer] = []
            defer { ownedVirtualIndices.forEach { git_index_free($0) } }

            for nextBase in reversed.dropFirst() {
                let virtualIndex = try inspectCommitMergeDrivers(
                    ours: current, theirs: .real(nextBase),
                    buildVirtualResult: true, handle: handle, options: options)
                guard let virtualIndex else {
                    throw Libgit2Error(code: -1, klass: 0, message: "virtual base merge returned no index")
                }
                ownedVirtualIndices.append(virtualIndex)
                current = .virtual(index: virtualIndex, parents: current.headIDs + [nextBase])
            }

            return try runSingleCommitStepDriverCheck(
                base: current, ours: ours, theirs: theirs,
                buildVirtualResult: buildVirtualResult, handle: handle, options: options)
        }

        return try runSingleCommitStepDriverCheck(
            base: computedBase, ours: ours, theirs: theirs,
            buildVirtualResult: buildVirtualResult, handle: handle, options: options)
    }

    private func runSingleCommitStepDriverCheck(
        base: CommitOrVirtual?,
        ours: CommitOrVirtual,
        theirs: CommitOrVirtual,
        buildVirtualResult: Bool,
        handle: MergeHandle,
        options: MergeTreeOptions
    ) throws -> OpaquePointer? {
        try withMergeInput(base, on: handle.checkRepo) { baseInput in
            try withMergeInput(ours, on: handle.checkRepo) { oursInput in
                try withMergeInput(theirs, on: handle.checkRepo) { theirsInput in
                    try checkExternalDrivers(
                        base: baseInput, ours: oursInput, theirs: theirsInput,
                        handle: handle, options: options)
                    guard buildVirtualResult else { return nil }
                    return try mergeForVirtualBase(
                        base: baseInput, ours: oursInput, theirs: theirsInput,
                        handle: handle, options: options)
                }
            }
        }
    }

    private func withMergeInput<T>(
        _ input: CommitOrVirtual?,
        on targetRepo: OpaquePointer,
        _ body: (MergeInput) throws -> T
    ) throws -> T {
        guard let input else { return try body(.empty) }
        switch input {
        case .virtual(let index, _):
            return try body(.index(index))
        case .real(let commitOID):
            var lookup = commitOID
            var commit: OpaquePointer?
            try check(git_commit_lookup(&commit, targetRepo, &lookup))
            defer { git_commit_free(commit) }
            var tree: OpaquePointer?
            try check(git_commit_tree(&tree, commit))
            defer { git_tree_free(tree) }
            guard let tree else { return try body(.empty) }
            return try body(.tree(tree))
        }
    }

    private func mergeForVirtualBase(
        base: MergeInput,
        ours: MergeInput,
        theirs: MergeInput,
        handle: MergeHandle,
        options: MergeTreeOptions
    ) throws -> OpaquePointer? {
        var opts = try makeMergeOptions(options)
        opts.flags &= ~UInt32(GIT_MERGE_FAIL_ON_CONFLICT.rawValue)
        opts.flags |= UInt32(GIT_MERGE_VIRTUAL_BASE.rawValue)

        let baseTree = try materializeTree(base, on: handle.checkRepo)
        defer { if let baseTree { git_tree_free(baseTree) } }
        let oursTree = try materializeTree(ours, on: handle.checkRepo)
        defer { if let oursTree { git_tree_free(oursTree) } }
        let theirsTree = try materializeTree(theirs, on: handle.checkRepo)
        defer { if let theirsTree { git_tree_free(theirsTree) } }

        var index: OpaquePointer?
        try check(git_merge_trees(&index, handle.checkRepo, baseTree, oursTree, theirsTree, &opts))
        return index
    }

    private func materializeTree(_ input: MergeInput, on targetRepo: OpaquePointer) throws -> OpaquePointer? {
        switch input {
        case .empty:
            return nil
        case .tree(let tree):
            var copy: OpaquePointer?
            var oid = git_tree_id(tree).pointee
            try check(git_tree_lookup(&copy, targetRepo, &oid))
            return copy
        case .index(let index):
            var cleanIndex: OpaquePointer?
            try check(git_index_new(&cleanIndex))
            defer { git_index_free(cleanIndex) }
            let count = git_index_entrycount(index)
            for idx in 0..<count {
                guard let entry = git_index_get_byindex(index, idx) else { continue }
                let stage = (entry.pointee.flags >> 12) & 0x3
                if stage == 0 {
                    try check(git_index_add(cleanIndex, entry))
                }
            }
            var treeOID = git_oid()
            try check(git_index_write_tree_to(&treeOID, cleanIndex, targetRepo))
            var tree: OpaquePointer?
            try check(git_tree_lookup(&tree, targetRepo, &treeOID))
            return tree
        }
    }

    private func checkExternalDrivers(
        base: MergeInput,
        ours: MergeInput,
        theirs: MergeInput,
        handle: MergeHandle,
        options: MergeTreeOptions
    ) throws {
        var candidates: Set<String> = []
        if case .index(let baseIndex) = base { candidates.formUnion(try unmergedPaths(baseIndex)) }
        if case .index(let oursIndex) = ours { candidates.formUnion(try unmergedPaths(oursIndex)) }
        if case .index(let theirsIndex) = theirs { candidates.formUnion(try unmergedPaths(theirsIndex)) }

        let oursDeltas = try collectSideDeltas(from: base, to: ours, handle: handle, options: options)
        let theirsDeltas = try collectSideDeltas(from: base, to: theirs, handle: handle, options: options)

        let (oursByOld, oursAdded) = partitionDeltas(oursDeltas)
        let (theirsByOld, theirsAdded) = partitionDeltas(theirsDeltas)

        var oursDeleteCollidesWithTheirs = false
        var theirsDeleteCollidesWithOurs = false

        for (oldPath, ourEntry) in oursByOld {
            guard let theirEntry = theirsByOld[oldPath] else { continue }
            if ourEntry.newPath == theirEntry.newPath,
               ourEntry.mode == theirEntry.mode,
               sameOID(ourEntry.oid, theirEntry.oid) {
                continue
            }
            if ourEntry.status == GIT_DELTA_DELETED { oursDeleteCollidesWithTheirs = true }
            if theirEntry.status == GIT_DELTA_DELETED { theirsDeleteCollidesWithOurs = true }
            candidates.insert(Self.bestMergePath(
                ancestor: oldPath, ours: ourEntry.newPath, theirs: theirEntry.newPath))
            if let path = ourEntry.newPath { candidates.insert(path) }
            if let path = theirEntry.newPath { candidates.insert(path) }
        }

        for (addedPath, ourEntry) in oursAdded {
            if let theirEntry = theirsAdded[addedPath],
               !(ourEntry.mode == theirEntry.mode && sameOID(ourEntry.oid, theirEntry.oid)) {
                candidates.insert(addedPath)
            }
        }

        // Fail-closed guard for rename similarity edge cases between
        // git_diff_find_similar and git_merge_diff_list__find_renames: if one
        // side deleted a path that the other side touched while renames are on,
        // inspect unmatched added paths on the deleting side as well.
        if case .detect = options.renames {
            if oursDeleteCollidesWithTheirs { candidates.formUnion(oursAdded.keys) }
            if theirsDeleteCollidesWithOurs { candidates.formUnion(theirsAdded.keys) }
        }

        for path in candidates.sorted(by: Self.indexOrder) {
            try checkExternalDriver(forPath: path, handle: handle)
        }
    }

    private func partitionDeltas(
        _ deltas: [DiffSideEntry]
    ) -> (byOld: [String: DiffSideEntry], added: [String: DiffSideEntry]) {
        var byOld: [String: DiffSideEntry] = [:]
        var added: [String: DiffSideEntry] = [:]
        for entry in deltas {
            if entry.status == GIT_DELTA_ADDED, let path = entry.newPath {
                added[path] = entry
            } else if let oldPath = entry.oldPath {
                byOld[oldPath] = entry
            }
        }
        return (byOld, added)
    }

    private func collectSideDeltas(
        from base: MergeInput,
        to side: MergeInput,
        handle: MergeHandle,
        options: MergeTreeOptions
    ) throws -> [DiffSideEntry] {
        var diffOpts = git_diff_options()
        try check(git_diff_options_init(&diffOpts, UInt32(GIT_DIFF_OPTIONS_VERSION)))

        var diff: OpaquePointer?
        switch (base, side) {
        case (.empty, .empty):
            return []
        case (.empty, .tree(let sideTree)):
            try check(git_diff_tree_to_tree(&diff, handle.checkRepo, nil, sideTree, &diffOpts))
        case (.tree(let baseTree), .tree(let sideTree)):
            try check(git_diff_tree_to_tree(&diff, handle.checkRepo, baseTree, sideTree, &diffOpts))
        case (.tree(let baseTree), .index(let sideIndex)):
            try check(git_diff_tree_to_index(&diff, handle.checkRepo, baseTree, sideIndex, &diffOpts))
        case (.index(let baseIndex), .tree(let sideTree)):
            diffOpts.flags |= UInt32(GIT_DIFF_REVERSE.rawValue)
            try check(git_diff_tree_to_index(&diff, handle.checkRepo, sideTree, baseIndex, &diffOpts))
        case (.empty, .index(let sideIndex)):
            try check(git_diff_tree_to_index(&diff, handle.checkRepo, nil, sideIndex, &diffOpts))
        case (.index, .empty), (.tree, .empty), (.index, .index):
            let baseTree = try materializeTree(base, on: handle.checkRepo)
            defer { if let baseTree { git_tree_free(baseTree) } }
            let sideTree = try materializeTree(side, on: handle.checkRepo)
            defer { if let sideTree { git_tree_free(sideTree) } }
            try check(git_diff_tree_to_tree(&diff, handle.checkRepo, baseTree, sideTree, &diffOpts))
        }
        defer { git_diff_free(diff) }

        if case .detect(let threshold) = options.renames, case .empty = base {
            _ = threshold
        } else if case .detect(let threshold) = options.renames {
            var findOpts = git_diff_find_options()
            try check(git_diff_find_options_init(&findOpts, UInt32(GIT_DIFF_FIND_OPTIONS_VERSION)))
            findOpts.flags = UInt32(GIT_DIFF_FIND_RENAMES.rawValue)
            findOpts.rename_threshold = UInt16(threshold)
            findOpts.rename_limit = handle.renameLimit
            try check(git_diff_find_similar(diff, &findOpts))
        }

        let count = git_diff_num_deltas(diff)
        var entries: [DiffSideEntry] = []
        entries.reserveCapacity(count)
        for index in 0..<count {
            guard let delta = git_diff_get_delta(diff, index)?.pointee else { continue }
            let oldPath = delta.old_file.path.map { String(cString: $0) }
            let newPath = delta.new_file.path.map { String(cString: $0) }
            entries.append(DiffSideEntry(
                oldPath: delta.status == GIT_DELTA_ADDED ? nil : oldPath,
                newPath: delta.status == GIT_DELTA_DELETED ? nil : newPath,
                oid: delta.new_file.id,
                mode: UInt32(delta.new_file.mode),
                status: delta.status))
        }
        return entries
    }

    private func checkExternalDriver(forPath path: String, handle: MergeHandle) throws {
        var rawValue: UnsafePointer<CChar>?
        try check(git_attr_get(&rawValue, handle.checkRepo, 0, path, "merge"))
        let driverName: String
        switch git_attr_value(rawValue) {
        case GIT_ATTR_VALUE_TRUE:
            driverName = "text"
        case GIT_ATTR_VALUE_FALSE:
            driverName = "binary"
        case GIT_ATTR_VALUE_UNSPECIFIED:
            driverName = handle.defaultDriver ?? "text"
        case GIT_ATTR_VALUE_STRING:
            driverName = rawValue.map { String(cString: $0) } ?? "text"
        default:
            driverName = "text"
        }

        if driverName != "text", driverName != "binary", driverName != "union",
           handle.configuredDrivers.contains(driverName) {
            throw MergeTreeError.externalMergeDriver(path: path, driver: driverName)
        }
    }
}

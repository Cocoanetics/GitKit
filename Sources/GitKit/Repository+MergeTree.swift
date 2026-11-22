import Foundation
import CGitKit

extension Repository {

    /// Reports whether `ancestor` is an ancestor of `descendant` (including
    /// when both resolve to the same commit), matching
    /// `git merge-base --is-ancestor`.
    ///
    /// Both revision specs are resolved once and peeled to commits. Throws
    /// ``MergeTreeError/notACommit(_:)`` if a resolved object does not peel to
    /// a commit, or ``Libgit2Error`` if a spec cannot be resolved.
    public func isAncestor(_ ancestor: String, of descendant: String) throws -> Bool {
        let ancestorOID = try resolvePinnedCommit(ancestor)
        let descendantOID = try resolvePinnedCommit(descendant)
        if sameOID(ancestorOID, descendantOID) { return true }
        return try isDescendant(descendantOID, of: ancestorOID)
    }

    /// Perform a non-mutating three-way merge of two commits (`ours` and
    /// `theirs`), computing merge bases like `git merge-base --all` and
    /// recursively merging multiple bases in memory unless
    /// ``MergeTreeOptions/recursiveBases`` is `false`.
    ///
    /// Refs, reflogs, `HEAD`, `MERGE_*`, the index file, and working-tree
    /// files are never modified. With the default
    /// ``MergeTreeOptions/Objects/inMemory`` policy, no objects are written to
    /// disk and existing object/pack timestamps are untouched.
    ///
    /// Cancellation is checked between stages (before opening, after resolving
    /// inputs, before/during external-driver inspection, before the merge call,
    /// and before writing the result tree); an in-flight libgit2 merge call
    /// itself cannot be interrupted mid-flight.
    public func mergeTree(
        ours: String,
        theirs: String,
        options: MergeTreeOptions = .init()
    ) throws -> MergeTreeResult {
        try validateMergeTreeOptions(options)
        try Task.checkCancellation()

        let oursCommitOID = try resolvePinnedCommit(ours)
        let theirsCommitOID = try resolvePinnedCommit(theirs)
        let oursTreeOID = try treeOID(ofCommit: oursCommitOID)
        let attributeTreeOID = try resolveAttributeTreeOID(options.attributes, oursTreeOID: oursTreeOID)

        try Task.checkCancellation()

        var oursOIDCopy = oursCommitOID
        var theirsOIDCopy = theirsCommitOID
        let oursHex = formatOID(&oursOIDCopy)
        let theirsHex = formatOID(&theirsOIDCopy)

        return try withMergeHandle(options: options, attributeTreeOID: attributeTreeOID) { handle in
            try Task.checkCancellation()
            try checkExternalDriversForCommits(
                ours: oursCommitOID, theirs: theirsCommitOID,
                handle: handle, options: options)
            try Task.checkCancellation()

            let bases = try mergeBasesList(on: handle.mergeRepo, ours: oursCommitOID, theirs: theirsCommitOID)
            let baseHexes = bases.map { oid -> String in
                var copy = oid
                return formatOID(&copy)
            }

            var mergeOpts = try makeMergeOptions(options)
            var oursCommit: OpaquePointer?
            var oursLookup = oursCommitOID
            try check(git_commit_lookup(&oursCommit, handle.mergeRepo, &oursLookup))
            defer { git_commit_free(oursCommit) }

            var theirsCommit: OpaquePointer?
            var theirsLookup = theirsCommitOID
            try check(git_commit_lookup(&theirsCommit, handle.mergeRepo, &theirsLookup))
            defer { git_commit_free(theirsCommit) }

            var mergedIndex: OpaquePointer?
            try check(git_merge_commits(&mergedIndex, handle.mergeRepo, oursCommit, theirsCommit, &mergeOpts))
            defer { git_index_free(mergedIndex) }

            let outcome = try extractMergeTreeOutcome(from: mergedIndex, on: handle.mergeRepo)
            return MergeTreeResult(ours: oursHex, theirs: theirsHex, mergeBases: baseHexes, outcome: outcome)
        }
    }

    /// Perform a non-mutating three-way merge of explicit trees (`base`, `ours`,
    /// `theirs`). Each revision spec is resolved once and peeled to a tree;
    /// `base == nil` performs a merge with no common ancestor (add/add
    /// semantics).
    ///
    /// Refs, reflogs, `HEAD`, `MERGE_*`, the index file, and working-tree
    /// files are never modified. With the default
    /// ``MergeTreeOptions/Objects/inMemory`` policy, no objects are written to
    /// disk and existing object/pack timestamps are untouched.
    public func mergeTree(
        base: String?,
        ours: String,
        theirs: String,
        options: MergeTreeOptions = .init()
    ) throws -> MergeTreeResult {
        try validateMergeTreeOptions(options)
        try Task.checkCancellation()

        let baseTreeOID = try base.map { try resolvePinnedTree($0) }
        let oursTreeOID = try resolvePinnedTree(ours)
        let theirsTreeOID = try resolvePinnedTree(theirs)
        let attributeTreeOID = try resolveAttributeTreeOID(options.attributes, oursTreeOID: oursTreeOID)

        try Task.checkCancellation()

        var oursOIDCopy = oursTreeOID
        var theirsOIDCopy = theirsTreeOID
        let oursHex = formatOID(&oursOIDCopy)
        let theirsHex = formatOID(&theirsOIDCopy)
        let baseHexes: [String] = baseTreeOID.map { oid in
            var copy = oid
            return [formatOID(&copy)]
        } ?? []

        return try withMergeHandle(options: options, attributeTreeOID: attributeTreeOID) { handle in
            try Task.checkCancellation()
            try checkExternalDriversForTrees(
                base: baseTreeOID, ours: oursTreeOID, theirs: theirsTreeOID,
                handle: handle, options: options)
            try Task.checkCancellation()

            var mergeOpts = try makeMergeOptions(options)
            var baseTree: OpaquePointer?
            if var baseLookup = baseTreeOID {
                try check(git_tree_lookup(&baseTree, handle.mergeRepo, &baseLookup))
            }
            defer { if baseTree != nil { git_tree_free(baseTree) } }

            var oursTree: OpaquePointer?
            var oursLookup = oursTreeOID
            try check(git_tree_lookup(&oursTree, handle.mergeRepo, &oursLookup))
            defer { git_tree_free(oursTree) }

            var theirsTree: OpaquePointer?
            var theirsLookup = theirsTreeOID
            try check(git_tree_lookup(&theirsTree, handle.mergeRepo, &theirsLookup))
            defer { git_tree_free(theirsTree) }

            var mergedIndex: OpaquePointer?
            try check(git_merge_trees(&mergedIndex, handle.mergeRepo, baseTree, oursTree, theirsTree, &mergeOpts))
            defer { git_index_free(mergedIndex) }

            let outcome = try extractMergeTreeOutcome(from: mergedIndex, on: handle.mergeRepo)
            return MergeTreeResult(ours: oursHex, theirs: theirsHex, mergeBases: baseHexes, outcome: outcome)
        }
    }
}

// MARK: - Private Handle & Validation

struct MergeHandle {
    /// Private bare handle used for the actual merge (mempack ODB for
    /// `.inMemory`, independently owned disk ODB for `.write`).
    let mergeRepo: OpaquePointer
    /// Private bare handle backed by an in-memory mempack ODB, used for
    /// read-only external-driver inspection (including recursive virtual-base
    /// merges) so a refused driver never writes objects even in `.write` mode.
    /// Identical to `mergeRepo` when `options.objects == .inMemory`.
    let checkRepo: OpaquePointer
    let configuredDrivers: Set<String>
    let defaultDriver: String?
    let renameLimit: Int
}

extension Repository {

    private func validateMergeTreeOptions(_ options: MergeTreeOptions) throws {
        if case .detect(let threshold) = options.renames, !(1...100).contains(threshold) {
            throw MergeTreeError.invalidRenameThreshold(threshold)
        }
    }

    private func resolvePinnedCommit(_ spec: String) throws -> git_oid {
        var object: OpaquePointer?
        try check(git_revparse_single(&object, repo, spec))
        defer { git_object_free(object) }

        var commit: OpaquePointer?
        let rc = git_object_peel(&commit, object, GIT_OBJECT_COMMIT)
        guard rc == 0, let commit else {
            throw MergeTreeError.notACommit(spec)
        }
        defer { git_object_free(commit) }
        return git_object_id(commit).pointee
    }

    private func resolvePinnedTree(_ spec: String) throws -> git_oid {
        var object: OpaquePointer?
        try check(git_revparse_single(&object, repo, spec))
        defer { git_object_free(object) }

        var tree: OpaquePointer?
        let rc = git_object_peel(&tree, object, GIT_OBJECT_TREE)
        guard rc == 0, let tree else {
            throw MergeTreeError.notATree(spec)
        }
        defer { git_object_free(tree) }
        return git_object_id(tree).pointee
    }

    private func resolveAttributeTreeOID(
        _ source: MergeTreeOptions.AttributeSource,
        oursTreeOID: git_oid
    ) throws -> git_oid? {
        switch source {
        case .ours: oursTreeOID
        case .tree(let spec): try resolvePinnedTree(spec)
        case .none: nil
        }
    }

    private func withMergeHandle<T>(
        options: MergeTreeOptions,
        attributeTreeOID: git_oid?,
        _ body: (MergeHandle) throws -> T
    ) throws -> T {
        guard let repoPathPtr = git_repository_path(repo) else {
            throw Libgit2Error(code: -1, klass: 0, message: "repository has no git directory path")
        }
        let repoPath = String(cString: repoPathPtr)

        let mergeRepo = try openPrivateBareRepository(
            at: repoPath,
            inMemoryODB: options.objects == .inMemory,
            attributeTreeOID: attributeTreeOID)
        defer { git_repository_free(mergeRepo) }

        let configInfo = try inspectMergeConfig(on: mergeRepo)

        // In `.write` mode, if custom drivers are configured and favor is `.normal`,
        // run the driver pre-check on a second mempack-backed handle so a refused
        // external driver never writes objects to disk (including virtual bases).
        var separateCheckRepo: OpaquePointer?
        if options.objects == .write, options.favor == .normal, !configInfo.configuredDrivers.isEmpty {
            separateCheckRepo = try openPrivateBareRepository(
                at: repoPath,
                inMemoryODB: true,
                attributeTreeOID: attributeTreeOID)
        }
        defer { if let separateCheckRepo { git_repository_free(separateCheckRepo) } }

        let handle = MergeHandle(
            mergeRepo: mergeRepo,
            checkRepo: separateCheckRepo ?? mergeRepo,
            configuredDrivers: configInfo.configuredDrivers,
            defaultDriver: configInfo.defaultDriver,
            renameLimit: configInfo.renameLimit)
        return try body(handle)
    }

    /// Opens an independently owned bare `git_repository` over `repoPath`
    /// inside the caller's inherited `ConfigIncludePolicy` thread scope,
    /// installs a fresh config snapshot (preserving operation-only config
    /// levels without touching the caller's live config ownership), optionally
    /// attaches a fresh mempack + read-only disk-alternate ODB, and attaches a
    /// fresh in-memory index for attribute lookup.
    private func openPrivateBareRepository(
        at repoPath: String,
        inMemoryODB: Bool,
        attributeTreeOID: git_oid?
    ) throws -> OpaquePointer {
        let restoreThreadPolicy = includePolicy.map { ConfigIncludePolicyBox($0).setForCurrentThread() }
        defer { restoreThreadPolicy?() }

        var raw: OpaquePointer?
        let openFlags = UInt32(GIT_REPOSITORY_OPEN_BARE.rawValue | GIT_REPOSITORY_OPEN_NO_SEARCH.rawValue)
        try check(git_repository_open_ext(&raw, repoPath, openFlags, nil))
        guard let privateRepo = raw else {
            throw Libgit2Error(code: -1, klass: 0, message: "git_repository_open_ext returned no repository")
        }

        do {
            // Snapshot caller config into a brand-new git_config owned solely
            // by privateRepo so callerRepo's live config owner is untouched.
            var snapshot: OpaquePointer?
            try check(git_repository_config_snapshot(&snapshot, repo))
            defer { git_config_free(snapshot) }
            try check(git_repository_set_config(privateRepo, snapshot))
            try check(git_attr_cache_flush(privateRepo))

            if inMemoryODB {
                try installInMemoryODB(on: privateRepo)
            }

            try installAttributeIndex(treeOID: attributeTreeOID, on: privateRepo)
            return privateRepo
        } catch {
            git_repository_free(privateRepo)
            throw error
        }
    }

    private func installInMemoryODB(on privateRepo: OpaquePointer) throws {
        var objectsBuf = git_buf()
        try check(git_repository_item_path(&objectsBuf, privateRepo, GIT_REPOSITORY_ITEM_OBJECTS))
        defer { git_buf_dispose(&objectsBuf) }
        guard let objectsPathPtr = objectsBuf.ptr else {
            throw Libgit2Error(code: -1, klass: 0, message: "repository has no objects directory")
        }

        var odb: OpaquePointer?
        try check(git_odb_new(&odb))
        defer { git_odb_free(odb) }

        var mempack: UnsafeMutablePointer<git_odb_backend>?
        try check(git_mempack_new(&mempack))
        guard let mempack else {
            throw Libgit2Error(code: -1, klass: 0, message: "git_mempack_new returned no backend")
        }
        let addRC = git_odb_add_backend(odb, mempack, 999)
        if addRC < 0 {
            let err = Libgit2Error.last(code: addRC)
            mempack.pointee.free?(mempack)
            throw err
        }

        try check(git_odb_add_disk_alternate(odb, objectsPathPtr))

        // Prevent git_odb_write's freshen pass from touching mtimes on existing
        // loose objects or packfiles inside the read-only disk alternates.
        let backendCount = git_odb_num_backends(odb)
        for index in 0..<backendCount {
            var backend: UnsafeMutablePointer<git_odb_backend>?
            if git_odb_get_backend(&backend, odb, index) == 0, let backend, backend != mempack {
                backend.pointee.freshen = nil
            }
        }

        try check(git_repository_set_odb(privateRepo, odb))
    }

    private func installAttributeIndex(treeOID: git_oid?, on privateRepo: OpaquePointer) throws {
        var attrIndex: OpaquePointer?
        try check(git_index_new(&attrIndex))
        defer { git_index_free(attrIndex) }

        if var treeOID {
            var tree: OpaquePointer?
            try check(git_tree_lookup(&tree, privateRepo, &treeOID))
            defer { git_tree_free(tree) }
            try check(git_index_read_tree(attrIndex, tree))
        }

        try check(git_repository_set_index(privateRepo, attrIndex))
    }

    private struct MergeConfigInfo {
        let configuredDrivers: Set<String>
        let defaultDriver: String?
        let renameLimit: Int
    }

    private func inspectMergeConfig(on privateRepo: OpaquePointer) throws -> MergeConfigInfo {
        var cfg: OpaquePointer?
        try check(git_repository_config(&cfg, privateRepo))
        defer { git_config_free(cfg) }

        var renormalize: Int32 = 0
        let renormRC = git_config_get_bool(&renormalize, cfg, "merge.renormalize")
        if renormRC == 0 {
            if renormalize != 0 { throw MergeTreeError.unsupportedRenormalize }
        } else if renormRC != GIT_ENOTFOUND.rawValue {
            try check(renormRC)
        }

        var iter: UnsafeMutablePointer<git_config_iterator>?
        try check(git_config_iterator_new(&iter, cfg))
        defer { git_config_iterator_free(iter) }

        var configuredDrivers: Set<String> = []
        var defaultDriver: String?
        var mergeRenameLimit: Int32 = 0
        var diffRenameLimit: Int32 = 0

        while true {
            var entry: UnsafeMutablePointer<git_config_entry>?
            let rc = git_config_next(&entry, iter)
            if rc == GIT_ITEROVER.rawValue { break }
            try check(rc)
            guard let e = entry?.pointee, let namePtr = e.name else { continue }
            let name = String(cString: namePtr)
            if name == "merge.default" {
                defaultDriver = e.value.map { String(cString: $0) }
            } else if name.hasPrefix("merge."), name.hasSuffix(".driver"),
                      name.count > "merge.".count + ".driver".count {
                let start = name.index(name.startIndex, offsetBy: "merge.".count)
                let end = name.index(name.endIndex, offsetBy: -".driver".count)
                let driver = String(name[start..<end])
                if driver != "text" && driver != "binary" && driver != "union" {
                    configuredDrivers.insert(driver)
                }
            }
        }

        if git_config_get_int32(&mergeRenameLimit, cfg, "merge.renamelimit") != 0 {
            mergeRenameLimit = 0
        }
        if git_config_get_int32(&diffRenameLimit, cfg, "diff.renamelimit") != 0 {
            diffRenameLimit = 0
        }
        let rawLimit = mergeRenameLimit > 0 ? mergeRenameLimit : diffRenameLimit
        let renameLimit = rawLimit > 0 ? Int(rawLimit) : 1000

        return MergeConfigInfo(
            configuredDrivers: configuredDrivers,
            defaultDriver: defaultDriver,
            renameLimit: renameLimit)
    }

    func makeMergeOptions(_ options: MergeTreeOptions) throws -> git_merge_options {
        var opts = git_merge_options()
        try check(git_merge_options_init(&opts, UInt32(GIT_MERGE_OPTIONS_VERSION)))
        opts.flags |= UInt32(GIT_MERGE_SKIP_REUC.rawValue)
        switch options.renames {
        case .detect(let threshold):
            opts.flags |= UInt32(GIT_MERGE_FIND_RENAMES.rawValue)
            opts.rename_threshold = UInt32(threshold)
        case .off:
            opts.flags &= ~UInt32(GIT_MERGE_FIND_RENAMES.rawValue)
        }
        if !options.recursiveBases {
            opts.flags |= UInt32(GIT_MERGE_NO_RECURSIVE.rawValue)
        }
        opts.file_favor = options.favor.libgit2
        return opts
    }

    private func mergeBasesList(
        on targetRepo: OpaquePointer,
        ours: git_oid,
        theirs: git_oid
    ) throws -> [git_oid] {
        var ours = ours
        var theirs = theirs
        var array = git_oidarray()
        let rc = git_merge_bases(&array, targetRepo, &ours, &theirs)
        if rc == GIT_ENOTFOUND.rawValue { return [] }
        try check(rc)
        defer { git_oidarray_dispose(&array) }
        return (0..<array.count).map { array.ids[$0] }
    }

    func mergeBasesManyList(
        on targetRepo: OpaquePointer,
        ids: [git_oid]
    ) throws -> [git_oid] {
        var input = ids
        var array = git_oidarray()
        let rc = git_merge_bases_many(&array, targetRepo, input.count, &input)
        if rc == GIT_ENOTFOUND.rawValue { return [] }
        try check(rc)
        defer { git_oidarray_dispose(&array) }
        return (0..<array.count).map { array.ids[$0] }
    }

    private func extractMergeTreeOutcome(
        from mergedIndex: OpaquePointer?,
        on targetRepo: OpaquePointer
    ) throws -> MergeTreeResult.Outcome {
        if git_index_has_conflicts(mergedIndex) != 0 {
            return .conflicted(try extractConflicts(from: mergedIndex))
        }
        try Task.checkCancellation()
        var treeOID = git_oid()
        try check(git_index_write_tree_to(&treeOID, mergedIndex, targetRepo))
        return .clean(tree: formatOID(&treeOID))
    }

    private func extractConflicts(from index: OpaquePointer?) throws -> [MergeTreeConflict] {
        var iterator: OpaquePointer?
        try check(git_index_conflict_iterator_new(&iterator, index))
        defer { git_index_conflict_iterator_free(iterator) }

        var conflicts: [MergeTreeConflict] = []
        while true {
            var ancestor: UnsafePointer<git_index_entry>?
            var ours: UnsafePointer<git_index_entry>?
            var theirs: UnsafePointer<git_index_entry>?
            let rc = git_index_conflict_next(&ancestor, &ours, &theirs, iterator)
            if rc == GIT_ITEROVER.rawValue { break }
            try check(rc)

            let ancestorSide = makeConflictSide(ancestor)
            let oursSide = makeConflictSide(ours)
            let theirsSide = makeConflictSide(theirs)
            let path = Self.bestMergePath(
                ancestor: ancestorSide?.path,
                ours: oursSide?.path,
                theirs: theirsSide?.path)
            conflicts.append(MergeTreeConflict(
                path: path,
                ancestor: ancestorSide,
                ours: oursSide,
                theirs: theirsSide))
        }

        return conflicts.sorted { lhs, rhs in
            if lhs.path != rhs.path { return Self.indexOrder(lhs.path, rhs.path) }
            if lhs.ours?.path != rhs.ours?.path {
                return Self.indexOrder(lhs.ours?.path ?? "", rhs.ours?.path ?? "")
            }
            if lhs.theirs?.path != rhs.theirs?.path {
                return Self.indexOrder(lhs.theirs?.path ?? "", rhs.theirs?.path ?? "")
            }
            return Self.indexOrder(lhs.ancestor?.path ?? "", rhs.ancestor?.path ?? "")
        }
    }

    private func makeConflictSide(_ entry: UnsafePointer<git_index_entry>?) -> MergeTreeConflict.Side? {
        guard let raw = entry?.pointee, let pathPtr = raw.path else { return nil }
        var oid = raw.id
        return MergeTreeConflict.Side(
            path: String(cString: pathPtr),
            oid: formatOID(&oid),
            mode: raw.mode)
    }

    static func bestMergePath(ancestor: String?, ours: String?, theirs: String?) -> String {
        if let ancestor {
            if let ours, ours == ancestor, let theirs { return theirs }
            if let theirs, theirs == ancestor, let ours { return ours }
        } else if let ours, let theirs, ours == theirs {
            return ours
        }
        return ours ?? theirs ?? ancestor ?? ""
    }
}

import Foundation
import CGitKit

/// The heads `git merge` records as a merge's parents, after dropping
/// those already reachable from HEAD or from another head
/// (`reduce_heads`).
public struct MergeHeads: Sendable, Equatable {
    /// The heads still to merge, as given, in the order given.
    public let heads: [String]
    /// Whether HEAD is reachable from one of them, so that a merge
    /// commit leaves it out of its parents unless `--no-ff` asks.
    public let headSubsumed: Bool
}

/// One head as git's octopus strategy (`git-merge-octopus`) took it.
public struct OctopusMergeStep: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// `Already up to date with <head>`: HEAD's side already has it.
        case alreadyUpToDate
        /// `Fast-forwarding to: <head>`: nothing merged so far was not
        /// already in it.
        case fastForward
        /// `Trying simple merge with <head>`.
        case merge
    }

    /// The head as it was given.
    public let head: String
    public let kind: Kind
    /// For a merge the trivial (`read-tree --aggressive`) merge couldn't
    /// do, the paths the automatic merge (`git-merge-one-file`) went
    /// over, in index order; `nil` when the trivial merge did it, or when
    /// the step failed before merging.
    public let automatic: [OctopusPathMerge]?
}

/// What `git-merge-one-file` did with one path both sides changed.
public enum OctopusPathMerge: Sendable, Equatable {
    /// `Auto-merging <path>`, merged cleanly.
    case merged(path: String)
    /// `Auto-merging <path>`, then `ERROR: content conflict in <path>`.
    case conflict(path: String)
    /// `Added <path> in both, but differently.`, then `ERROR: content
    /// conflict in <path>`.
    case addedInBoth(path: String)
    /// `ERROR: <path>: Not handling case <base> -> <ours> -> <theirs>`,
    /// each an object name or empty where that side has no such path.
    case notHandled(path: String, base: String, ours: String, theirs: String)

    public var path: String {
        switch self {
        case .merged(let path), .conflict(let path), .addedInBoth(let path),
             .notHandled(let path, _, _, _):
            return path
        }
    }

    /// Whether the path was left unmerged.
    public var failed: Bool {
        if case .merged = self { return false }
        return true
    }
}

/// Why an octopus merge gave up, leaving HEAD, the index and the
/// working tree as they were (git's `Merge with strategy octopus
/// failed.`, exit 2).
public enum OctopusMergeFailure: Sendable, Equatable {
    /// `Error: Your local changes to the following files would be
    /// overwritten by merge`: the index differs from HEAD at these paths.
    case localChanges(paths: [String])
    /// `error: Entry '<path>' not uptodate. Cannot merge.`
    case notUpToDate(path: String)
    /// `error: Untracked working tree file '<path>' would be overwritten by merge.`
    case untrackedWouldBeOverwritten(path: String)
    /// `Unable to find common commit with <head>`.
    case noCommonCommit(head: String)
    /// `Automated merge did not work.` / `Should not be doing an
    /// octopus.`: a head other than the last left conflicts.
    case conflictsBeforeLastHead
}

/// How an octopus merge ended.
public enum OctopusMergeOutcome: Sendable, Equatable {
    /// `Merge made by the 'octopus' strategy.`: the merge commit, and the
    /// diff stat from the old HEAD to it.
    case mergeCommit(sha: String, statSummary: String, addedFiles: [String], deletedFiles: [String])
    /// The last head left conflicts, which are in the index and the
    /// working tree for the user to resolve, with `MERGE_HEAD`,
    /// `MERGE_MSG` and `MERGE_MODE` written for the commit that
    /// concludes the merge.
    case conflicts(paths: [String])
    /// The merge gave up and changed nothing.
    case failed(OctopusMergeFailure)
}

/// An octopus merge's steps and how it ended.
public struct OctopusMergeResult: Sendable, Equatable {
    public let steps: [OctopusMergeStep]
    public let outcome: OctopusMergeOutcome
}

extension Repository {

    /// The heads a merge of `heads` into HEAD records, as `git merge`
    /// reduces them: duplicates and any head reachable from HEAD or from
    /// another head drop out. An empty `heads` in the result means HEAD
    /// already has them all. Each head is anything that names a commit.
    public func mergeHeads(reducing heads: [String]) throws -> MergeHeads {
        let head = try headOID()
        var candidates: [(spec: String, oid: git_oid)] = []
        for spec in heads {
            let oid = try mergeableCommit(spec)
            if !candidates.contains(where: { sameOID($0.oid, oid) }) { candidates.append((spec, oid)) }
        }
        var remaining: [String] = []
        var headSubsumed = false
        for (index, candidate) in candidates.enumerated() {
            if let head, sameOID(head, candidate.oid) || isDescendant(head, of: candidate.oid) { continue }
            let reachable = candidates.indices.contains { other in
                other != index && isDescendant(candidates[other].oid, of: candidate.oid)
            }
            if reachable { continue }
            remaining.append(candidate.spec)
            if let head, isDescendant(candidate.oid, of: head) { headSubsumed = true }
        }
        return MergeHeads(heads: remaining, headSubsumed: headSubsumed)
    }

    /// What `git merge` calls `spec` in its merge message, as git's
    /// `merge_name` does, in `FETCH_HEAD`'s words: `branch 'a'`,
    /// `remote-tracking branch 'origin/a'`, `tag 'v1'`, `branch 'a'
    /// (early part)` for `a~<n>` or `a^`, else `commit '<spec>'`. The
    /// name is the one given (`refs/heads/a` stays so).
    public func mergeName(_ spec: String) -> String {
        var ref: OpaquePointer?
        if git_reference_dwim(&ref, repo, spec) == 0 {
            defer { git_reference_free(ref) }
            let name = String(cString: git_reference_name(ref))
            for (prefix, kind) in [("refs/heads/", "branch"), ("refs/tags/", "tag"),
                                   ("refs/remotes/", "remote-tracking branch")] where name.hasPrefix(prefix) {
                return "\(kind) '\(spec)'"
            }
        }
        // `<branch>~<n>` or `<branch>^…`: the branch's early part.
        var base = Substring(spec)
        var suffix = ""
        if let tilde = spec.lastIndex(of: "~"), spec[spec.index(after: tilde)...].allSatisfy(\.isNumber) {
            base = spec[..<tilde]
            suffix = String(spec[tilde...])
        } else {
            while base.hasSuffix("^") { base = base.dropLast() }
            suffix = String(spec.dropFirst(base.count))
        }
        if !suffix.isEmpty, !base.isEmpty {
            var oid = git_oid()
            if git_reference_name_to_id(&oid, repo, "refs/heads/\(base)") == 0 {
                return "branch '\(base)'" + (suffix == "~0" ? "" : " (early part)")
            }
        }
        return "commit '\(spec)'"
    }

    /// Merge `heads` into HEAD as git's octopus strategy does
    /// (`git-merge-octopus`): one head after the other, fast-forwarding
    /// while nothing has been merged yet, else trying the trivial merge
    /// and then a file-by-file one, of which only the last head's may
    /// leave conflicts for the user. Rename detection plays no part, as
    /// in git.
    ///
    /// `heads` are those ``mergeHeads(reducing:)`` leaves, at least two.
    /// The merge commit's parents are HEAD, unless a head already
    /// contains it and `noFastForward` is false, then the heads. HEAD,
    /// the index and the working tree change only once the merge
    /// succeeds or stops at the last head's conflicts; a working tree
    /// change in a path the merge doesn't touch survives.
    public func octopusMerge(
        heads: [String],
        noFastForward: Bool = false,
        message: String,
        author: Signature? = nil,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> OctopusMergeResult {
        guard let head = try headOID() else {
            throw Libgit2Error(code: -1, klass: 0,
                message: "Can merge only exactly one commit into empty head")
        }
        let oids = try heads.map { try mergeableCommit($0) }
        let headTree = try treeOID(ofCommit: head)

        var index: OpaquePointer?
        try check(git_repository_index(&index, repo))
        defer { git_index_free(index) }
        try check(git_index_read(index, 0))

        // git-merge-octopus refuses an index that differs from HEAD.
        let staged = try changedPaths(from: headTree, toIndex: index)
        if !staged.isEmpty {
            return OctopusMergeResult(steps: [], outcome: .failed(.localChanges(paths: staged)))
        }
        let worktree = try workingTreeChanges(index: index)

        var steps: [OctopusMergeStep] = []
        var mergedCommits = [head]   // git-merge-octopus' MRC
        var mergedTree = headTree    // and MRT
        var nonFastForward = false
        var conflicted: OpaquePointer?
        defer { if conflicted != nil { git_index_free(conflicted) } }
        var conflictedPaths: [String] = []

        for (name, oid) in zip(heads, oids) {
            if conflicted != nil {
                return OctopusMergeResult(steps: steps, outcome: .failed(.conflictsBeforeLastHead))
            }
            let bases = try mergeBases(oid, mergedCommits)
            guard let base = bases.first else {
                return OctopusMergeResult(steps: steps, outcome: .failed(.noCommonCommit(head: name)))
            }
            if bases.count == 1, sameOID(base, oid) {
                steps.append(OctopusMergeStep(head: name, kind: .alreadyUpToDate, automatic: nil))
                continue
            }
            let theirTree = try treeOID(ofCommit: oid)
            if !nonFastForward, bases.count == 1, mergedCommits.count == 1, sameOID(base, mergedCommits[0]) {
                steps.append(OctopusMergeStep(head: name, kind: .fastForward, automatic: nil))
                if let failure = overwrites(try diffEntries(mergedTree, theirTree).keys, worktree: worktree) {
                    return OctopusMergeResult(steps: steps, outcome: .failed(failure))
                }
                mergedCommits = [oid]
                mergedTree = theirTree
                continue
            }

            nonFastForward = true
            let baseTree = try treeOID(ofCommit: base)
            let ours = try diffEntries(baseTree, mergedTree)
            let theirs = try diffEntries(baseTree, theirTree)
            if let failure = overwrites(theirs.keys, worktree: worktree) {
                steps.append(OctopusMergeStep(head: name, kind: .merge, automatic: nil))
                return OctopusMergeResult(steps: steps, outcome: .failed(failure))
            }

            let merged = try mergeTrees(base: baseTree, ours: mergedTree, theirs: theirTree)
            // What the trivial merge leaves unmerged: paths both sides
            // changed, and differently.
            var automatic: [OctopusPathMerge] = []
            for path in Set(ours.keys).intersection(theirs.keys).sorted(by: Self.indexOrder) {
                guard let our = ours[path], let their = theirs[path], our != their else { continue }
                var ancestor, ourEntry, theirEntry: UnsafePointer<git_index_entry>?
                let unmerged = git_index_conflict_get(&ancestor, &ourEntry, &theirEntry, merged, path) == 0
                switch (our.oid == nil, their.oid == nil) {
                case (false, false) where !our.added:
                    automatic.append(unmerged ? .conflict(path: path) : .merged(path: path))
                case (false, false):
                    automatic.append(.addedInBoth(path: path))
                default:
                    automatic.append(.notHandled(path: path, base: our.added ? "" : our.base ?? their.base ?? "",
                                                 ours: our.oid ?? "", theirs: their.oid ?? ""))
                }
            }
            steps.append(OctopusMergeStep(head: name, kind: .merge, automatic: automatic.isEmpty ? nil : automatic))
            mergedCommits.append(oid)
            if git_index_has_conflicts(merged) != 0 || automatic.contains(where: \.failed) {
                conflicted = merged
                conflictedPaths = try unmergedPaths(merged)
                if conflictedPaths.isEmpty { conflictedPaths = automatic.filter(\.failed).map(\.path) }
                continue
            }
            defer { git_index_free(merged) }
            var tree = git_oid()
            try check(git_index_write_tree_to(&tree, merged, repo))
            mergedTree = tree
        }

        try writeOrigHead(head)
        if let conflicted {
            try checkOutConflicts(conflicted, theirLabel: heads.last ?? "")
            try writeMergeState(oids: oids, message: message, conflicts: conflictedPaths,
                                noFastForward: noFastForward)
            return OctopusMergeResult(steps: steps, outcome: .conflicts(paths: conflictedPaths))
        }

        let headSubsumed = oids.contains { isDescendant($0, of: head) }
        let parents = (headSubsumed && !noFastForward ? [] : [head]) + oids
        // git ends a message with a newline.
        let text = message.hasSuffix("\n") ? message : message + "\n"
        let sha = try commitMerge(tree: mergedTree, parents: parents, message: text,
                                  author: author, env: env)
        let stats = try mergeStats(from: headTree, to: mergedTree)
        return OctopusMergeResult(steps: steps, outcome: .mergeCommit(
            sha: sha, statSummary: stats.summary, addedFiles: stats.added, deletedFiles: stats.deleted))
    }

    // MARK: Commits

    private func headOID() throws -> git_oid? {
        var oid = git_oid()
        let rc = git_reference_name_to_id(&oid, repo, "HEAD")
        if rc == GIT_ENOTFOUND.rawValue || rc == GIT_EUNBORNBRANCH.rawValue { return nil }
        try check(rc)
        return oid
    }

    /// The commit `spec` names, refused as git refuses it.
    private func mergeableCommit(_ spec: String) throws -> git_oid {
        var object: OpaquePointer?
        guard git_revparse_single(&object, repo, spec) == 0 else {
            throw Libgit2Error(code: -1, klass: 0, message: "merge: \(spec) - not something we can merge")
        }
        defer { git_object_free(object) }
        var commit: OpaquePointer?
        guard git_object_peel(&commit, object, GIT_OBJECT_COMMIT) == 0 else {
            throw Libgit2Error(code: -1, klass: 0, message: "merge: \(spec) - not something we can merge")
        }
        defer { git_object_free(commit) }
        return git_object_id(commit).pointee
    }

    private func sameOID(_ a: git_oid, _ b: git_oid) -> Bool {
        var a = a, b = b
        return git_oid_equal(&a, &b) == 1
    }

    /// Whether `commit` has `ancestor` in its history (and isn't it).
    private func isDescendant(_ commit: git_oid, of ancestor: git_oid) -> Bool {
        var commit = commit, ancestor = ancestor
        return git_graph_descendant_of(repo, &commit, &ancestor) == 1
    }

    /// `git merge-base --all <one> <others>…`: the best common ancestors
    /// of `one` and a merge of `others`; empty when there are none.
    private func mergeBases(_ one: git_oid, _ others: [git_oid]) throws -> [git_oid] {
        var input = [one] + others
        var out = git_oidarray()
        let rc = git_merge_bases_many(&out, repo, input.count, &input)
        if rc == GIT_ENOTFOUND.rawValue { return [] }
        try check(rc)
        defer { git_oidarray_dispose(&out) }
        return (0..<out.count).map { out.ids[$0] }
    }

    private func treeOID(ofCommit oid: git_oid) throws -> git_oid {
        var oid = oid
        var commit: OpaquePointer?
        try check(git_commit_lookup(&commit, repo, &oid))
        defer { git_commit_free(commit) }
        return git_commit_tree_id(commit).pointee
    }

    private func withTree<T>(_ oid: git_oid, _ body: (OpaquePointer?) throws -> T) throws -> T {
        var oid = oid
        var tree: OpaquePointer?
        try check(git_tree_lookup(&tree, repo, &oid))
        defer { git_tree_free(tree) }
        return try body(tree)
    }

    // MARK: Trees

    /// One path's change between two trees.
    private struct Change: Equatable {
        /// The object name before, `nil` where there was none.
        let base: String?
        /// The object name after, `nil` where the path is gone.
        let oid: String?
        let mode: UInt32
        /// Whether the path is new.
        var added: Bool { base == nil }

        static func == (lhs: Change, rhs: Change) -> Bool { lhs.oid == rhs.oid && lhs.mode == rhs.mode }
    }

    /// The paths that differ between trees `from` and `to`, renames not
    /// looked for, as `read-tree` sees them.
    private func diffEntries(_ from: git_oid, _ to: git_oid) throws -> [String: Change] {
        try withTree(from) { old in
            try withTree(to) { new in
                var diff: OpaquePointer?
                try check(git_diff_tree_to_tree(&diff, repo, old, new, nil))
                defer { git_diff_free(diff) }
                var changes: [String: Change] = [:]
                for i in 0..<git_diff_num_deltas(diff) {
                    guard let delta = git_diff_get_delta(diff, i)?.pointee else { continue }
                    var oldID = delta.old_file.id, newID = delta.new_file.id
                    let path = String(cString: delta.new_file.path ?? delta.old_file.path)
                    changes[path] = Change(
                        base: delta.status == GIT_DELTA_ADDED ? nil : formatOID(&oldID),
                        oid: delta.status == GIT_DELTA_DELETED ? nil : formatOID(&newID),
                        mode: UInt32(delta.new_file.mode))
                }
                return changes
            }
        }
    }

    private func mergeTrees(base: git_oid, ours: git_oid, theirs: git_oid) throws -> OpaquePointer? {
        var options = git_merge_options()
        try check(git_merge_options_init(&options, UInt32(GIT_MERGE_OPTIONS_VERSION)))
        options.flags = 0 // no rename detection, as read-tree and merge-one-file
        return try withTree(base) { base in
            try withTree(ours) { ours in
                try withTree(theirs) { theirs in
                    var index: OpaquePointer?
                    try check(git_merge_trees(&index, repo, base, ours, theirs, &options))
                    return index
                }
            }
        }
    }

    /// git's index order: byte-wise by path.
    private static func indexOrder(_ a: String, _ b: String) -> Bool {
        Array(a.utf8).lexicographicallyPrecedes(Array(b.utf8))
    }

    private func unmergedPaths(_ index: OpaquePointer?) throws -> [String] {
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

    private func changedPaths(from tree: git_oid, toIndex index: OpaquePointer?) throws -> [String] {
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
    private func workingTreeChanges(index: OpaquePointer?) throws -> [String: Bool] {
        guard git_repository_is_bare(repo) == 0 else { return [:] }
        var options = git_diff_options()
        try check(git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION)))
        options.flags = GIT_DIFF_INCLUDE_UNTRACKED.rawValue | GIT_DIFF_RECURSE_UNTRACKED_DIRS.rawValue
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
    private func overwrites<S: Sequence>(
        _ paths: S, worktree: [String: Bool]
    ) -> OctopusMergeFailure? where S.Element == String {
        for path in paths.sorted(by: Self.indexOrder) {
            guard let untracked = worktree[path] else { continue }
            return untracked ? .untrackedWouldBeOverwritten(path: path) : .notUpToDate(path: path)
        }
        return nil
    }

    private func checkOutConflicts(_ merged: OpaquePointer?, theirLabel: String) throws {
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
    }

    // MARK: Writing

    private func writeOrigHead(_ head: git_oid) throws {
        var head = head
        var ref: OpaquePointer?
        try check(git_reference_create(&ref, repo, "ORIG_HEAD", &head, 1, nil))
        git_reference_free(ref)
    }

    /// `MERGE_HEAD`, `MERGE_MSG` and `MERGE_MODE`, as git leaves them
    /// for the commit that concludes a merge stopped by conflicts.
    private func writeMergeState(oids: [git_oid], message: String, conflicts: [String], noFastForward: Bool) throws {
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
    private func commitMerge(
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

    private func mergeStats(from old: git_oid, to new: git_oid) throws
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

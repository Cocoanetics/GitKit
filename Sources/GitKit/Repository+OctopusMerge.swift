import Foundation
import CGitKit

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
        try refuseWhereGitWontMerge()
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
        let ignoreCase = try ignoresCase()
        let skipWorktree = skipWorktreePaths(index)

        var steps: [OctopusMergeStep] = []
        var mergedCommits = [head]   // git-merge-octopus' MRC
        var mergedTree = headTree    // and MRT
        var nonFastForward = false
        var conflicted: OpaquePointer?
        defer { if conflicted != nil { git_index_free(conflicted) } }
        var conflictedPaths: [String] = []
        // Paths git-merge-one-file leaves with our content, unmerged.
        var keepOurs: [String] = []
        // Content merged cleanly for paths that conflict on modes alone.
        var mergedContent: [String: git_oid] = [:]

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
                if let failure = overwrites(try diffEntries(mergedTree, theirTree), worktree: worktree,
                                            ignoreCase: ignoreCase) {
                    return OctopusMergeResult(steps: steps, outcome: .failed(failure))
                }
                mergedCommits = [oid]
                mergedTree = theirTree
                continue
            }

            nonFastForward = true
            let baseTrees = try bases.map { try treeOID(ofCommit: $0) }
            // The content merge runs against the bases' virtual merge, as
            // git's recursive strategy builds it; which paths the trivial
            // merge leaves unmerged follows read-tree, which takes every
            // base (`unmerged`).
            let merged = try mergeTrees(base: try virtualBase(bases), ours: mergedTree, theirs: theirTree)
            var automatic: [OctopusPathMerge]
            do {
                automatic = try unmerged(bases: baseTrees, ours: mergedTree, theirs: theirTree, merged: merged,
                                         headTree: headTree, mergedContent: &mergedContent)
            } catch {
                git_index_free(merged)
                throw error
            }
            // The step changes every path its index differs from the
            // merge so far at, conflicts included, and read-tree -u has
            // touched every path it left to the automatic merge, even one
            // that merges back to ours.
            var touched = try changes(from: mergedTree, to: merged)
            for path in automatic.map(\.path) where touched[path] == nil {
                touched[path] = Change(oid: "", mode: 0)
            }
            // A path git-merge-one-file itself refuses over an untracked
            // file is its conflict to report, not read-tree's refusal.
            for case .addedOverUntracked(let path) in automatic { touched[path] = nil }
            if let failure = overwrites(touched, worktree: worktree, ignoreCase: ignoreCase) {
                git_index_free(merged)
                steps.append(OctopusMergeStep(head: name, kind: .merge, automatic: nil))
                return OctopusMergeResult(steps: steps, outcome: .failed(failure))
            }
            steps.append(OctopusMergeStep(head: name, kind: .merge, automatic: automatic.isEmpty ? nil : automatic))
            mergedCommits.append(oid)
            if git_index_has_conflicts(merged) != 0 {
                conflicted = merged
                conflictedPaths = try unmergedPaths(merged)
                keepOurs = automatic.compactMap { path in
                    switch path {
                    // git-merge-one-file's merge of an add/add path, with the
                    // empty blob there to read, leaves conflict markers.
                    case .addedInBoth(let path, true), .notHandled(let path, _, _, _), .symlink(let path),
                         .submodule(let path), .addedWithDifferentModes(let path, _, _),
                         .deletedWithModeChange(let path): return path
                    default: return nil
                    }
                }
                continue
            }
            defer { git_index_free(merged) }
            var tree = git_oid()
            try check(git_index_write_tree_to(&tree, merged, repo))
            mergedTree = tree
        }

        try writeOrigHead(head)
        if let conflicted {
            try checkOutConflicts(conflicted, from: headTree, theirLabel: heads.last ?? "", keepingOurs: keepOurs,
                                  mergedContent: mergedContent)
            try keepSkipWorktree(skipWorktree)
            try writeMergeState(oids: oids, message: message, conflicts: conflictedPaths,
                                noFastForward: noFastForward)
            return OctopusMergeResult(steps: steps, outcome: .conflicts(paths: conflictedPaths))
        }

        let outcome = try conclude(head: head, headTree: headTree, mergedTree: mergedTree, oids: oids,
                                   noFastForward: noFastForward, message: message, author: author, env: env)
        try keepSkipWorktree(skipWorktree)
        return OctopusMergeResult(steps: steps, outcome: outcome)
    }

    /// Commit the merged tree on HEAD, or, where another process holds
    /// HEAD's ref, leave the merge staged for `git commit`, as git does.
    func conclude(
        head: git_oid, headTree: git_oid, mergedTree: git_oid, oids: [git_oid], noFastForward: Bool,
        message: String, author: Signature?, env: [String: String]
    ) throws -> OctopusMergeOutcome {
        let headSubsumed = oids.contains { isDescendant($0, of: head) }
        let parents = (headSubsumed && !noFastForward ? [] : [head]) + oids
        // git ends a message with a newline.
        let text = message.hasSuffix("\n") ? message : message + "\n"
        let sha: String
        do {
            sha = try commitMerge(tree: mergedTree, from: headTree, parents: parents, message: text,
                                  author: author, env: env)
        } catch let locked as HeadLocked {
            try writeMergeState(oids: oids, message: message, conflicts: [], noFastForward: noFastForward)
            return .headLocked(lockFile: locked.lockFile)
        }
        let stats = try mergeStats(from: headTree, to: mergedTree)
        return .mergeCommit(sha: sha, statSummary: stats.summary, addedFiles: stats.added, deletedFiles: stats.deleted)
    }

    /// Refuse as git does before merging at all: a bare repository, and
    /// a merge or cherry-pick that waits to be concluded.
    func refuseWhereGitWontMerge() throws {
        // A merge needs a work tree.
        if git_repository_is_bare(repo) != 0 {
            throw Libgit2Error(code: -1, klass: 0, message: "this operation must be run in a work tree")
        }
        // git refuses to start a merge while another operation waits.
        let state = git_repository_state(repo)
        if state == Int32(GIT_REPOSITORY_STATE_MERGE.rawValue) {
            throw Libgit2Error(code: -1, klass: 0, message: "You have not concluded your merge (MERGE_HEAD exists).")
        }
        if state == Int32(GIT_REPOSITORY_STATE_CHERRYPICK.rawValue)
            || state == Int32(GIT_REPOSITORY_STATE_CHERRYPICK_SEQUENCE.rawValue) {
            throw Libgit2Error(code: -1, klass: 0,
                message: "You have not concluded your cherry-pick (CHERRY_PICK_HEAD exists).")
        }
        // Anything else (a bisect, a revert, a rebase) git merges through.
    }

    // MARK: Commits

    func headOID() throws -> git_oid? {
        var oid = git_oid()
        let rc = git_reference_name_to_id(&oid, repo, "HEAD")
        if rc == GIT_ENOTFOUND.rawValue || rc == GIT_EUNBORNBRANCH.rawValue { return nil }
        try check(rc)
        return oid
    }

    /// The commit `spec` names, refused as git refuses it.
    func mergeableCommit(_ spec: String) throws -> git_oid {
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

    func sameOID(_ a: git_oid, _ b: git_oid) -> Bool {
        var a = a, b = b
        return git_oid_equal(&a, &b) == 1
    }

    /// Whether `commit` has `ancestor` in its history (and isn't it).
    func isDescendant(_ commit: git_oid, of ancestor: git_oid) -> Bool {
        var commit = commit, ancestor = ancestor
        return git_graph_descendant_of(repo, &commit, &ancestor) == 1
    }

    /// `git merge-base --all <one> <others>…`: the best common ancestors
    /// of `one` and a merge of `others`; empty when there are none.
    func mergeBases(_ one: git_oid, _ others: [git_oid]) throws -> [git_oid] {
        var input = [one] + others
        var out = git_oidarray()
        let rc = git_merge_bases_many(&out, repo, input.count, &input)
        if rc == GIT_ENOTFOUND.rawValue { return [] }
        try check(rc)
        defer { git_oidarray_dispose(&out) }
        return (0..<out.count).map { out.ids[$0] }
    }

    func treeOID(ofCommit oid: git_oid) throws -> git_oid {
        var oid = oid
        var commit: OpaquePointer?
        try check(git_commit_lookup(&commit, repo, &oid))
        defer { git_commit_free(commit) }
        return git_commit_tree_id(commit).pointee
    }

    func withTree<T>(_ oid: git_oid, _ body: (OpaquePointer?) throws -> T) throws -> T {
        var oid = oid
        var tree: OpaquePointer?
        try check(git_tree_lookup(&tree, repo, &oid))
        defer { git_tree_free(tree) }
        return try body(tree)
    }
}

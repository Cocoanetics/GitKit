import Foundation
import CGitKit

/// One linked worktree known to a repository.
public struct WorktreeInfo: Sendable, Equatable {
    /// The worktree's administrative name, usually the target directory's
    /// last path component.
    public let name: String
    /// Filesystem location of the linked working tree.
    public let path: URL
    /// Full 40-character SHA pointed at by the worktree's HEAD, or nil
    /// for an unborn/missing HEAD.
    public let head: String?
    /// True when the worktree is locked.
    public let isLocked: Bool
    /// True when libgit2 considers the worktree prunable without force
    /// options (typically because its working tree has disappeared).
    public let isPrunable: Bool
}

extension Repository {

    /// Add a linked worktree at `path`, checking out `branch`.
    ///
    /// If `branch` does not exist, it is created at `HEAD` first. If it
    /// already exists, that branch is used as-is. The worktree name follows
    /// real git's default: the target directory's last path component, with
    /// a numeric suffix added when that administrative name is taken.
    public func worktreeAdd(
        path: URL,
        branch: String,
        force: Bool = false
    ) throws {
        let preferredName = path.lastPathComponent
        guard !preferredName.isEmpty, preferredName != "/" else {
            throw Libgit2Error(code: -1, klass: 0,
                message: "worktree path must have a final path component")
        }
        let name = try uniqueWorktreeName(preferred: preferredName)

        var branchRef: OpaquePointer?
        var createdBranch = false
        let branchLookupRC = git_branch_lookup(&branchRef, repo, branch, GIT_BRANCH_LOCAL)
        if branchLookupRC == GIT_ENOTFOUND.rawValue {
            branchRef = try createWorktreeBranch(named: branch)
            createdBranch = true
        } else {
            try check(branchLookupRC)
        }
        defer { git_reference_free(branchRef) }

        var opts = git_worktree_add_options()
        try check(git_worktree_add_options_init(
            &opts, UInt32(GIT_WORKTREE_ADD_OPTIONS_VERSION)))
        opts.ref = branchRef
        opts.checkout_options.checkout_strategy = force
            ? UInt32(GIT_CHECKOUT_FORCE.rawValue)
            : UInt32(GIT_CHECKOUT_SAFE.rawValue)

        var worktree: OpaquePointer?
        do {
            try name.withCString { nameC in
                try path.path.withCString { pathC in
                    _ = try check(git_worktree_add(
                        &worktree, repo, nameC, pathC, &opts))
                }
            }
        } catch {
            if createdBranch {
                _ = git_branch_delete(branchRef)
            }
            throw error
        }
        git_worktree_free(worktree)
    }

    /// List linked worktrees registered for this repository.
    ///
    /// This wraps libgit2's linked-worktree list, so the main worktree is
    /// not included.
    public func worktreeList() throws -> [WorktreeInfo] {
        var names = git_strarray()
        try check(git_worktree_list(&names, repo))
        defer { git_strarray_dispose(&names) }

        var result: [WorktreeInfo] = []
        result.reserveCapacity(names.count)
        for i in 0..<names.count {
            try Task.checkCancellation()
            guard let nameC = names.strings?[i] else { continue }
            let name = String(cString: nameC)

            var worktree: OpaquePointer?
            try check(git_worktree_lookup(&worktree, repo, name))
            defer { git_worktree_free(worktree) }

            result.append(try worktreeInfo(name: name, worktree: worktree))
        }
        return result
    }

    /// Remove a linked worktree by name.
    ///
    /// With `force == false`, the linked worktree must be clean. With
    /// `force == true`, local changes and locked worktrees are removed.
    public func worktreeRemove(name: String, force: Bool = false) throws {
        var worktree: OpaquePointer?
        try check(git_worktree_lookup(&worktree, repo, name))
        defer { git_worktree_free(worktree) }

        if !force {
            try ensureWorktreeUnlocked(worktree, name: name)
            try ensureWorktreeClean(worktree, name: name)
        }

        var opts = git_worktree_prune_options()
        try check(git_worktree_prune_options_init(
            &opts, UInt32(GIT_WORKTREE_PRUNE_OPTIONS_VERSION)))
        opts.flags =
            UInt32(GIT_WORKTREE_PRUNE_VALID.rawValue)
            | UInt32(GIT_WORKTREE_PRUNE_WORKING_TREE.rawValue)
        if force {
            opts.flags |= UInt32(GIT_WORKTREE_PRUNE_LOCKED.rawValue)
        }

        try check(git_worktree_prune(worktree, &opts))
    }

    private func createWorktreeBranch(named branch: String) throws -> OpaquePointer? {
        var headObject: OpaquePointer?
        try check(git_revparse_single(&headObject, repo, "HEAD"))
        defer { git_object_free(headObject) }

        var headOID = git_object_id(headObject)?.pointee ?? git_oid()
        var headCommit: OpaquePointer?
        try check(git_commit_lookup(&headCommit, repo, &headOID))
        defer { git_commit_free(headCommit) }

        var branchRef: OpaquePointer?
        try check(git_branch_create(&branchRef, repo, branch, headCommit, 0))
        return branchRef
    }

    private func uniqueWorktreeName(preferred: String) throws -> String {
        let names = Set(try linkedWorktreeNames())
        guard names.contains(preferred) else { return preferred }

        var suffix = 1
        while names.contains("\(preferred)\(suffix)") {
            suffix += 1
        }
        return "\(preferred)\(suffix)"
    }

    private func linkedWorktreeNames() throws -> [String] {
        var names = git_strarray()
        try check(git_worktree_list(&names, repo))
        defer { git_strarray_dispose(&names) }

        var result: [String] = []
        result.reserveCapacity(names.count)
        for i in 0..<names.count {
            if let nameC = names.strings?[i] {
                result.append(String(cString: nameC))
            }
        }
        return result
    }

    private func worktreeInfo(
        name: String,
        worktree: OpaquePointer?
    ) throws -> WorktreeInfo {
        guard let pathC = git_worktree_path(worktree) else {
            throw Libgit2Error(code: -1, klass: 0,
                message: "worktree '\(name)' has no path")
        }
        let path = URL(fileURLWithPath: String(cString: pathC), isDirectory: true)

        let locked = try worktreeIsLocked(worktree)

        var pruneOpts = git_worktree_prune_options()
        try check(git_worktree_prune_options_init(
            &pruneOpts, UInt32(GIT_WORKTREE_PRUNE_OPTIONS_VERSION)))
        let prunableRC = git_worktree_is_prunable(worktree, &pruneOpts)
        if prunableRC < 0 { try check(prunableRC) }

        return WorktreeInfo(
            name: name,
            path: path,
            head: try worktreeHeadOID(name: name),
            isLocked: locked,
            isPrunable: prunableRC > 0)
    }

    private func worktreeHeadOID(name: String) throws -> String? {
        var head: OpaquePointer?
        let rc = git_repository_head_for_worktree(&head, repo, name)
        if rc == GIT_EUNBORNBRANCH.rawValue || rc == GIT_ENOTFOUND.rawValue {
            return nil
        }
        try check(rc)
        defer { git_reference_free(head) }

        guard let oid = git_reference_target(head) else { return nil }
        return formatOID(oid)
    }

    private func ensureWorktreeUnlocked(
        _ worktree: OpaquePointer?,
        name: String
    ) throws {
        if try worktreeIsLocked(worktree) {
            throw Libgit2Error(code: -1, klass: 0,
                message: "worktree '\(name)' is locked")
        }
    }

    private func worktreeIsLocked(_ worktree: OpaquePointer?) throws -> Bool {
        var reason = git_buf()
        let rc = git_worktree_is_locked(&reason, worktree)
        defer { git_buf_dispose(&reason) }
        if rc < 0 { try check(rc) }
        return rc > 0
    }

    private func ensureWorktreeClean(
        _ worktree: OpaquePointer?,
        name: String
    ) throws {
        guard let pathC = git_worktree_path(worktree) else { return }
        let path = String(cString: pathC)
        guard FileManager.default.fileExists(atPath: path) else { return }

        let linkedRepo = try Repository.open(at: URL(fileURLWithPath: path, isDirectory: true))
        if let submodule = try checkedOutSubmodule(in: linkedRepo) {
            throw Libgit2Error(code: -1, klass: 0,
                message: "worktree '\(name)' contains submodule '\(submodule)'; use force to remove it")
        }
        if try !linkedRepo.status().isClean {
            throw Libgit2Error(code: -1, klass: 0,
                message: "worktree '\(name)' contains local changes; use force to remove it")
        }
    }

    private func checkedOutSubmodule(in repository: Repository) throws -> String? {
        let payload = WorktreeSubmoduleScanPayload()
        let rc = git_submodule_foreach(
            repository.repo,
            { submodule, nameC, rawPayload in
                guard let submodule, let rawPayload else { return -1 }
                guard git_submodule_wd_id(submodule) != nil else { return 0 }

                let payload = Unmanaged<WorktreeSubmoduleScanPayload>
                    .fromOpaque(rawPayload)
                    .takeUnretainedValue()
                payload.name = nameC.map { String(cString: $0) } ?? "<unknown>"
                return 1
            },
            Unmanaged.passUnretained(payload).toOpaque())

        if rc < 0 { try check(rc) }
        return payload.name
    }
}

private final class WorktreeSubmoduleScanPayload {
    var name: String?
}

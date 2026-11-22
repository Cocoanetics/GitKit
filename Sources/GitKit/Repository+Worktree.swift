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

/// One worktree known to a repository.
public struct WorktreeInfo: Sendable, Equatable {
    /// The worktree's name. For linked worktrees, this is the administrative
    /// name; for the primary worktree, this is the directory's last path
    /// component.
    public let name: String
    /// Filesystem location of the working tree.
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
    /// If `branch` does not exist, it is created at `startPoint` (default:
    /// `HEAD`) first, like `git worktree add <path> -b <branch> [<start-point>]`.
    /// As with real git, a `startPoint` that resolves to a remote-tracking
    /// branch (e.g. `"origin/main"`) is set as the new branch's upstream.
    /// If `branch` already exists, that branch is used as-is and `startPoint`
    /// is ignored. The worktree name follows real git's default: the target
    /// directory's last path component, with a numeric suffix added when
    /// that administrative name is taken.
    public func worktreeAdd(
        path: URL,
        branch: String,
        startPoint: String = "HEAD",
        force: Bool = false
    ) throws {
        _ = try worktreeAdd(
            path: path, branch: branch, startPoint: startPoint, force: force, preparing: nil)
    }

    /// Add a linked worktree at `path`, checking out `branch`, and let
    /// `preparation` prepare the worktree's own repository before its first
    /// checkout. Branch and name selection are those of
    /// ``worktreeAdd(path:branch:startPoint:force:)``.
    ///
    /// libgit2 creates the worktree's private git directory, its `.git` file
    /// and `HEAD` without an index or a file in it. The linked worktree is
    /// then opened — its git directory `.git/worktrees/<name>`, its common
    /// directory (objects, refs, config) the primary repository's — and
    /// handed to `preparation`; the worktree's initial checkout runs on that
    /// same repository afterwards, exactly once. It inherits this
    /// repository's include policy.
    ///
    /// - Returns: The linked worktree's repository `preparation` was given.
    /// - Throws: What `preparation` or the checkout threw, as is, after
    ///   pruning the worktree (its git directory and working directory, both
    ///   created by this call) and deleting `branch` if this call created it.
    @discardableResult
    public func worktreeAdd(
        path: URL,
        branch: String,
        startPoint: String = "HEAD",
        force: Bool = false,
        preparation: RepositoryPreparation
    ) throws -> Repository {
        guard let worktree = try worktreeAdd(
            path: path, branch: branch, startPoint: startPoint, force: force,
            preparing: preparation) else {
            throw Libgit2Error(code: -1, klass: 0, message: "worktree add returned no repository")
        }
        return worktree
    }

    /// The worktree's repository when there is a preparation, else nil: the
    /// unprepared add checks out inside libgit2 as it always has.
    private func worktreeAdd(
        path: URL,
        branch: String,
        startPoint: String,
        force: Bool,
        preparing preparation: RepositoryPreparation?
    ) throws -> Repository? {
        let preferredName = path.lastPathComponent
        guard !preferredName.isEmpty, preferredName != "/" else {
            throw Libgit2Error(code: -1, klass: 0,
                message: "worktree path must have a final path component")
        }
        // Adds through GitKit take turns per common directory, from name
        // selection until a failed add is rolled back, so no other add can
        // claim the name or paths in between (`gitkit-worktree-add.lock`,
        // exclusive like git's own locks; `git worktree add` doesn't take
        // part).
        let commonDir = try repositoryCommonDir()
        let adminDir = commonDir.appendingPathComponent("worktrees")
        var lock: OpaquePointer?
        try check(gitkit_lockfile_acquire(&lock, commonDir.appendingPathComponent("gitkit-worktree-add").path))
        var lockHeld = true
        func releaseLock() {
            if lockHeld { gitkit_lockfile_release(lock) }
            lockHeld = false
        }
        defer { releaseLock() }

        let name = try uniqueWorktreeName(preferred: preferredName)

        var branchRef: OpaquePointer?
        var createdBranch = false
        let branchLookupRC = git_branch_lookup(&branchRef, repo, branch, GIT_BRANCH_LOCAL)
        if branchLookupRC == GIT_ENOTFOUND.rawValue {
            branchRef = try createWorktreeBranch(named: branch, startPoint: startPoint)
            createdBranch = true
        } else {
            try check(branchLookupRC)
        }
        defer { git_reference_free(branchRef) }

        var opts = git_worktree_add_options()
        try check(git_worktree_add_options_init(
            &opts, UInt32(GIT_WORKTREE_ADD_OPTIONS_VERSION)))
        opts.ref = branchRef
        let checkoutStrategy = force
            ? UInt32(GIT_CHECKOUT_FORCE.rawValue)
            : UInt32(GIT_CHECKOUT_SAFE.rawValue)
        // Prepared, libgit2 writes neither files nor an index: without an
        // index file the deferred checkout is an initial one, as libgit2's
        // own would have been.
        opts.checkout_options.checkout_strategy = preparation == nil
            ? checkoutStrategy
            : UInt32(GIT_CHECKOUT_NONE.rawValue)
                | UInt32(GIT_CHECKOUT_DONT_UPDATE_INDEX.rawValue)
                | UInt32(GIT_CHECKOUT_DONT_WRITE_INDEX.rawValue)

        // libgit2 rolls nothing back when the add fails part way: note
        // what is there now, to remove only what the add created.
        let created = CreatedWorktreePaths(
            adminDir: Self.exists(adminDir) ? nil : adminDir,
            gitDir: adminDir.appendingPathComponent(name),
            gitDirExisted: Self.exists(adminDir.appendingPathComponent(name)),
            workdir: path,
            workdirExisted: Self.exists(path))

        var worktree: OpaquePointer?
        do {
            // libgit2 opens the new worktree's repository itself, reading
            // the shared config: this repository's include policy covers
            // that open, as `Repository.open(at:includePolicy:)` does.
            let restoreThreadPolicy = includePolicy.map(ConfigIncludePolicyBox.init)?
                .setForCurrentThread()
            defer { restoreThreadPolicy?() }
            try name.withCString { nameC in
                try path.path.withCString { pathC in
                    _ = try check(git_worktree_add(
                        &worktree, repo, nameC, pathC, &opts))
                }
            }
        } catch {
            created.remove()
            if createdBranch {
                _ = git_branch_delete(branchRef)
            }
            throw error
        }
        git_worktree_free(worktree)
        // Registered under its name now: later adds choose another one.
        releaseLock()
        guard let preparation else { return nil }

        do {
            return try checkoutPreparedWorktree(
                at: path, preparation: preparation, strategy: checkoutStrategy)
        } catch {
            pruneCreatedWorktree(named: name)
            created.remove()
            if createdBranch {
                _ = git_branch_delete(branchRef)
            }
            throw error
        }
    }

    /// Opens the linked worktree at `path`, prepares it and checks it out.
    private func checkoutPreparedWorktree(
        at path: URL,
        preparation: RepositoryPreparation,
        strategy: UInt32
    ) throws -> Repository {
        let worktree = try Repository.open(at: path, includePolicy: includePolicy)
        try preparation.prepare(worktree)

        var checkoutOpts = git_checkout_options()
        try check(git_checkout_options_init(
            &checkoutOpts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
        checkoutOpts.checkout_strategy = strategy
        try check(git_checkout_head(worktree.repo, &checkoutOpts))
        return worktree
    }

    /// Removes a worktree this call created: its private git directory and
    /// its working directory, which libgit2 created exclusively. The
    /// operation's own error matters more than a failed cleanup.
    private func pruneCreatedWorktree(named name: String) {
        var worktree: OpaquePointer?
        guard git_worktree_lookup(&worktree, repo, name) == 0 else { return }
        defer { git_worktree_free(worktree) }

        var opts = git_worktree_prune_options()
        guard git_worktree_prune_options_init(
            &opts, UInt32(GIT_WORKTREE_PRUNE_OPTIONS_VERSION)) == 0 else { return }
        opts.flags =
            UInt32(GIT_WORKTREE_PRUNE_VALID.rawValue)
            | UInt32(GIT_WORKTREE_PRUNE_LOCKED.rawValue)
            | UInt32(GIT_WORKTREE_PRUNE_WORKING_TREE.rawValue)
        _ = git_worktree_prune(worktree, &opts)
    }

    /// List worktrees with `git worktree list` semantics.
    ///
    /// The primary worktree is returned first, followed by linked worktrees.
    /// When called from a linked worktree, the primary worktree is still
    /// returned first rather than treating the current linked worktree as
    /// primary.
    public func worktreeList() throws -> [WorktreeInfo] {
        var result = [try primaryWorktreeInfo()]
        result.append(contentsOf: try linkedWorktreeList())
        return result
    }

    /// List linked worktrees registered for this repository.
    ///
    /// This wraps libgit2's linked-worktree list, so the primary worktree is
    /// not included.
    public func linkedWorktreeList() throws -> [WorktreeInfo] {
        let names = try linkedWorktreeNames()
        var result: [WorktreeInfo] = []
        result.reserveCapacity(names.count)
        for name in names {
            try Task.checkCancellation()

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

    /// Prune administrative data for worktrees that no longer have a
    /// working directory, like `git worktree prune`. Locked worktrees and
    /// ones whose working directory is still present are left alone.
    ///
    /// - Returns: the names of the worktrees that were pruned.
    @discardableResult
    public func worktreePrune() throws -> [String] {
        var pruned: [String] = []
        for name in try linkedWorktreeNames() {
            try Task.checkCancellation()

            var worktree: OpaquePointer?
            try check(git_worktree_lookup(&worktree, repo, name))
            defer { git_worktree_free(worktree) }

            var opts = git_worktree_prune_options()
            try check(git_worktree_prune_options_init(
                &opts, UInt32(GIT_WORKTREE_PRUNE_OPTIONS_VERSION)))

            let prunableRC = git_worktree_is_prunable(worktree, &opts)
            if prunableRC < 0 { try check(prunableRC) }
            guard prunableRC > 0 else { continue }

            try check(git_worktree_prune(worktree, &opts))
            pruned.append(name)
        }
        return pruned
    }

    private func createWorktreeBranch(
        named branch: String,
        startPoint: String
    ) throws -> OpaquePointer? {
        var startObject: OpaquePointer?
        try check(git_revparse_single(&startObject, repo, startPoint))
        defer { git_object_free(startObject) }

        var startOID = git_object_id(startObject)?.pointee ?? git_oid()
        var startCommit: OpaquePointer?
        try check(git_commit_lookup(&startCommit, repo, &startOID))
        defer { git_commit_free(startCommit) }

        var branchRef: OpaquePointer?
        try check(git_branch_create(&branchRef, repo, branch, startCommit, 0))

        // Real git enables tracking by default when the start-point is a
        // remote-tracking branch (`branch.autoSetupMerge`'s default of
        // `true`); mirror that so `currentBranchUpstream()`/status/push
        // behave the same as `git worktree add -b <branch> <path> <ref>`.
        if let upstream = remoteTrackingShorthand(ofStartPoint: startPoint) {
            try check(git_branch_set_upstream(branchRef, upstream))
        }

        return branchRef
    }

    /// If `startPoint` resolves (via the same DWIM rules git itself uses:
    /// `refs/<p>`, `refs/tags/<p>`, `refs/heads/<p>`, `refs/remotes/<p>`,
    /// `refs/remotes/<p>/HEAD`, in that order) to a remote-tracking branch,
    /// its shorthand (e.g. `"origin/main"`) for use with
    /// `git_branch_set_upstream`. `nil` for local branches, tags, and
    /// detached commit-ishes.
    private func remoteTrackingShorthand(ofStartPoint startPoint: String) -> String? {
        var startRef: OpaquePointer?
        guard git_reference_dwim(&startRef, repo, startPoint) == 0 else { return nil }
        defer { git_reference_free(startRef) }

        guard let nameC = git_reference_name(startRef) else { return nil }
        let name = String(cString: nameC)
        let prefix = "refs/remotes/"
        guard name.hasPrefix(prefix) else { return nil }
        return String(name.dropFirst(prefix.count))
    }

    /// The first of `preferred`, `preferred1`, … that is neither a listed
    /// worktree nor an administrative directory left over from one that
    /// never completed (libgit2 lists only complete ones).
    private func uniqueWorktreeName(preferred: String) throws -> String {
        let names = Set(try linkedWorktreeNames())
        let adminDir = try repositoryCommonDir().appendingPathComponent("worktrees")
        func taken(_ name: String) -> Bool {
            names.contains(name) || Self.exists(adminDir.appendingPathComponent(name))
        }
        guard taken(preferred) else { return preferred }

        var suffix = 1
        while taken("\(preferred)\(suffix)") {
            suffix += 1
        }
        return "\(preferred)\(suffix)"
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
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

    private func primaryWorktreeInfo() throws -> WorktreeInfo {
        let path = try primaryWorktreeURL()
        return WorktreeInfo(
            name: path.lastPathComponent,
            path: path,
            head: try primaryWorktreeHeadOID(),
            isLocked: false,
            isPrunable: false)
    }

    private func primaryWorktreeURL() throws -> URL {
        if git_repository_is_worktree(repo) != 0 {
            let commonDir = try repositoryCommonDir()
            if commonDir.lastPathComponent == ".git" {
                return commonDir.deletingLastPathComponent()
            }
            return commonDir
        }

        if let workdirC = git_repository_workdir(repo) {
            return URL(fileURLWithPath: String(cString: workdirC), isDirectory: true)
        }

        guard let pathC = git_repository_path(repo) else {
            throw Libgit2Error(code: -1, klass: 0,
                message: "repository has no path")
        }
        return URL(fileURLWithPath: String(cString: pathC), isDirectory: true)
    }

    private func primaryWorktreeHeadOID() throws -> String? {
        guard git_repository_is_worktree(repo) != 0 else {
            return try repositoryHeadOID(in: repo)
        }

        let commonDir = try repositoryCommonDir()
        var primaryRepo: OpaquePointer?
        try check(git_repository_open_bare(&primaryRepo, commonDir.path))
        defer { git_repository_free(primaryRepo) }
        return try repositoryHeadOID(in: primaryRepo)
    }

    private func repositoryCommonDir() throws -> URL {
        guard let commonDirC = git_repository_commondir(repo) else {
            throw Libgit2Error(code: -1, klass: 0,
                message: "repository has no common directory")
        }
        return URL(fileURLWithPath: String(cString: commonDirC), isDirectory: true)
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

    private func repositoryHeadOID(in repository: OpaquePointer?) throws -> String? {
        var head: OpaquePointer?
        let rc = git_repository_head(&head, repository)
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

/// What a failed `git_worktree_add` may have left, removed only where this
/// add provably made it. A directory that wasn't there before goes entirely
/// only when what libgit2 writes into it links it to this add (the git
/// directory's `gitdir` file names the working directory's `.git`, whose
/// `gitdir:` line names the git directory); otherwise only if it is empty,
/// which `rmdir` checks and does in one step.
struct CreatedWorktreePaths {
    let adminDir: URL?
    let gitDir: URL
    let gitDirExisted: Bool
    let workdir: URL
    let workdirExisted: Bool

    func remove() {
        if !gitDirExisted {
            Self.remove(gitDir) { Self.read("gitdir", in: gitDir).map(Self.real) == Self.real(dotGit) }
        }
        if !workdirExisted {
            Self.remove(workdir) {
                guard let line = Self.read(".git", in: workdir), line.hasPrefix("gitdir: ") else { return false }
                return Self.real(String(line.dropFirst("gitdir: ".count))) == Self.real(gitDir.path)
            }
        }
        if let adminDir { _ = Self.removeIfEmpty(adminDir) }
    }

    private var dotGit: String { workdir.appendingPathComponent(".git").path }

    private static func remove(_ dir: URL, ifOwned owned: () -> Bool) {
        guard !removeIfEmpty(dir), owned() else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Removes `dir` only if it is empty, atomically where the platform can.
    private static func removeIfEmpty(_ dir: URL) -> Bool {
        #if os(Windows)
        guard (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == true else {
            return false
        }
        return (try? FileManager.default.removeItem(at: dir)) != nil
        #else
        return rmdir(dir.path) == 0
        #endif
    }

    private static func read(_ name: String, in dir: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: dir.appendingPathComponent(name).path) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func real(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

private final class WorktreeSubmoduleScanPayload {
    var name: String?
}

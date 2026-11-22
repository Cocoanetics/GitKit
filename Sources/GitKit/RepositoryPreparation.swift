import Foundation
import CGitKit

/// What a host does to a repository GitKit has just created, before a single
/// working-tree file is written: the per-operation configuration,
/// credentials or filter setup its own policy calls for. GitKit only decides
/// *when* it runs, never what it does.
///
/// Pass one to ``Repository/clone(fromRemote:to:depth:singleBranch:branch:credentials:progress:preparation:)``
/// or ``Repository/worktreeAdd(path:branch:startPoint:force:preparation:)``.
/// The closure runs once, on the calling thread, with the very `Repository`
/// the operation then checks out with and returns:
///
/// - **Clone**: after the repository is initialised and before `origin` is
///   created, anything is fetched, or the index and files are written, so the
///   prepared configuration governs the whole clone (`url.<base>.insteadOf`,
///   transport settings, `core.autocrlf`, filters, …).
/// - **Worktree**: after the linked worktree's private git directory, `.git`
///   file and `HEAD` exist and before its index and files are written.
///
/// Throwing aborts the operation; the error is rethrown as is, and what the
/// operation created is removed (see each operation for exactly what).
///
/// A configuration the closure installs (`git_repository_set_config`) must
/// keep the repository's own config file as its writable local level: the
/// clone writes `remote.origin.*` and the branch's tracking entries there.
///
/// Keeping the clone's `Repository` beyond the closure is supported only
/// through the clone's result. If the clone fails after the closure returned,
/// libgit2 frees that handle and a kept reference to it is invalid: any
/// further use stops the process rather than touch freed memory.
public struct RepositoryPreparation {
    let prepare: (Repository) throws -> Void

    /// - Parameter prepare: Prepares the newly created repository.
    public init(_ prepare: @escaping (Repository) throws -> Void) {
        self.prepare = prepare
    }
}

// MARK: Clone

/// The `repository_cb` payload of a prepared clone: creates the repository
/// as libgit2's default does, prepares it, and keeps what the clone needs to
/// settle the handle's ownership once `git_clone` returns.
final class ClonePreparationBox {
    let preparation: RepositoryPreparation
    /// The prepared repository; libgit2 owns its handle until the clone
    /// succeeds.
    private(set) var repository: Repository?
    /// What the preparation threw, rethrown by the clone as is.
    private(set) var error: (any Error)?
    /// The include policy the preparation installed, moved to the calling
    /// thread while libgit2 owns the handle (see ``create(_:path:bare:)``).
    private var includePolicy: ConfigIncludePolicy?
    private var restoreThreadPolicy: (() -> Void)?

    init(_ preparation: RepositoryPreparation) {
        self.preparation = preparation
    }

    /// `git_repository_init`, as libgit2's `default_repository_create`, then
    /// the preparation. libgit2 cleans up nothing when this fails, so a
    /// thrown preparation frees the handle and removes the directory here,
    /// as libgit2 does for a clone that fails later.
    func create(_ out: UnsafeMutablePointer<OpaquePointer?>, path: String, bare: Int32) -> Int32 {
        // libgit2 refuses a non-empty directory before calling us, so what
        // is in it from here on is the clone's.
        let existed = FileManager.default.fileExists(atPath: path)
        var raw: OpaquePointer?
        let rc = git_repository_init(&raw, path, UInt32(bitPattern: bare))
        guard rc == 0, let raw else { return rc < 0 ? rc : -1 }

        let repository = Repository(pointer: raw, ownsPointer: false)
        self.repository = repository
        do {
            try preparation.prepare(repository)
        } catch {
            self.error = error
            repository.invalidate()
            git_repository_free(raw)
            Self.removeCreated(at: path, keepingRoot: existed)
            _ = "repository preparation failed: \(error)".withCString {
                git_error_set_str(Int32(GIT_ERROR_CALLBACK.rawValue), $0)
            }
            return GIT_EUSER.rawValue
        }

        // libgit2 frees the handle if the clone fails, leaving a policy
        // registered by its address to whatever is allocated there next.
        // The clone's config reads happen on this thread, so the policy
        // covers them from here, as for `Repository.open(at:includePolicy:)`.
        if let policy = repository.includePolicy {
            repository.dropIncludePolicyRegistration()
            includePolicy = policy
            restoreThreadPolicy = ConfigIncludePolicyBox(policy).setForCurrentThread()
        }
        out.pointee = raw
        return 0
    }

    /// Settles a finished `git_clone`. On success the prepared repository
    /// takes the handle back, with its include policy; on failure libgit2
    /// already freed the handle and removed the directory, so the repository
    /// is invalidated. Restores the calling thread's include policy.
    func finish(cloned out: OpaquePointer?) throws -> Repository? {
        restoreThreadPolicy?()
        restoreThreadPolicy = nil
        guard let repository else { return nil }
        guard let out, out == repository.pointer else {
            repository.invalidate()
            return nil
        }
        repository.adoptPointer()
        if let includePolicy {
            try repository.setIncludePolicy(includePolicy)
        }
        return repository
    }

    /// Removes what the clone created at `path`: the directory, or only its
    /// contents when it was there (empty) before.
    private static func removeCreated(at path: String, keepingRoot: Bool) {
        let manager = FileManager.default
        guard keepingRoot else {
            try? manager.removeItem(atPath: path)
            return
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        for name in (try? manager.contentsOfDirectory(atPath: path)) ?? [] {
            try? manager.removeItem(at: root.appendingPathComponent(name))
        }
    }
}

/// `repository_cb` for a prepared `git_clone`.
let clonePreparationTrampoline: git_repository_create_cb = { out, path, bare, payload in
    guard let out, let path, let payload else { return -1 }
    let box = Unmanaged<ClonePreparationBox>.fromOpaque(payload).takeUnretainedValue()
    return box.create(out, path: String(cString: path), bare: bare)
}

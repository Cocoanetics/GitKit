import Foundation
import CGitKit

extension Repository {

    /// Copy every submodule's configured URL from `.gitmodules` into local
    /// config — the parent's `submodule.<name>.url`, and, for submodules
    /// already checked out in the working tree, their own
    /// `remote.<remote>.url`. Mirrors `git submodule sync`.
    ///
    /// - Parameter recursive: Also sync submodules nested inside each
    ///   checked-out submodule (`git submodule sync --recursive`).
    ///   A submodule that isn't checked out is skipped — same as real
    ///   git, there's nothing underneath it to recurse into.
    public func submoduleSync(recursive: Bool = false) throws {
        final class SyncState {
            let recursive: Bool
            var error: Error?
            init(recursive: Bool) { self.recursive = recursive }
        }
        let state = SyncState(recursive: recursive)
        let raw = Unmanaged.passUnretained(state).toOpaque()

        // `git_submodule_cb` is a C function pointer, so this closure must
        // capture nothing — all state travels through `payload`.
        let cb: git_submodule_cb = { submodule, _, payload in
            guard let submodule, let payload else { return -1 }
            let state = Unmanaged<SyncState>.fromOpaque(payload).takeUnretainedValue()
            do {
                try check(git_submodule_sync(submodule))
                if state.recursive {
                    var subrepoPointer: OpaquePointer?
                    if git_submodule_open(&subrepoPointer, submodule) == 0,
                       let subrepoPointer {
                        // Takes ownership — freed when this falls out of scope.
                        try Repository(pointer: subrepoPointer).submoduleSync(recursive: true)
                    }
                }
                return 0
            } catch {
                state.error = error
                return -1
            }
        }

        let rc = git_submodule_foreach(repo, cb, raw)
        if let error = state.error { throw error }
        try check(rc)
    }
}

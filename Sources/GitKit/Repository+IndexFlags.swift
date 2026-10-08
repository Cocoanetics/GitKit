import Foundation
import CGitKit

extension Repository {

    /// Whether `path` (relative to the repository root) has an entry in
    /// the index — at stage 0, or at any conflict stage during a merge.
    /// The single-file form of `git ls-files --error-unmatch <path>`:
    /// an exact path, not a pathspec, so a directory is never "tracked",
    /// and case must match even where `core.ignorecase` is set.
    public func isTracked(path: String) throws -> Bool {
        var index: OpaquePointer?
        try check(git_repository_index(&index, repo))
        defer { git_index_free(index) }
        try check(git_index_read(index, 0))
        return path.withCString { p in
            (0...3).contains { stage in
                // With core.ignorecase (the macOS default) the lookup is
                // case-insensitive; only an exact match counts.
                guard let found = git_index_get_bypath(index, p, Int32(stage))?.pointee.path else {
                    return false
                }
                return strcmp(found, p) == 0
            }
        }
    }

    /// Set or clear the skip-worktree bit of `path`'s index entry and
    /// write the index. Equivalent to `git update-index
    /// --[no-]skip-worktree <path>`: with the bit set, git (and
    /// libgit2's status, diff and add-all) stop noticing changes to the
    /// working-tree file, so they are never staged.
    ///
    /// Like git, this holds `index.lock` from before it reads the index
    /// until the updated index is committed, so a concurrent git process
    /// can neither be overwritten nor interleave. Throws when `path` has
    /// no stage-0 entry with exactly that name (git: "Unable to mark
    /// file") and when another process holds the lock
    /// (``Libgit2Error/isLocked``); either way the index is unchanged.
    public func setSkipWorktree(_ enabled: Bool, path: String) throws {
        let bit = UInt16(GIT_INDEX_ENTRY_SKIP_WORKTREE.rawValue)
        try updateEntryFlags(path: path,
                             extendedSet: enabled ? bit : 0,
                             extendedClear: enabled ? 0 : bit)
    }

    /// Set or clear the assume-unchanged bit of `path`'s index entry and
    /// write the index. Equivalent to `git update-index
    /// --[no-]assume-unchanged <path>`. Same locking and failure behaviour
    /// as ``setSkipWorktree(_:path:)``.
    public func setAssumeUnchanged(_ enabled: Bool, path: String) throws {
        let bit = UInt16(GIT_INDEX_ENTRY_VALID.rawValue)
        try updateEntryFlags(path: path,
                             flagsSet: enabled ? bit : 0,
                             flagsClear: enabled ? 0 : bit)
    }

    private func updateEntryFlags(
        path: String,
        flagsSet: UInt16 = 0, flagsClear: UInt16 = 0,
        extendedSet: UInt16 = 0, extendedClear: UInt16 = 0
    ) throws {
        try check(path.withCString { p in
            gitkit_index_update_entry_flags(
                repo, p, flagsSet, flagsClear, extendedSet, extendedClear)
        })
    }
}

extension Libgit2Error {
    /// True when the operation failed because a lock file (for the
    /// index: `.git/index.lock`) is held by another process — git's
    /// "Unable to create '…/index.lock': File exists".
    public var isLocked: Bool { code == GIT_ELOCKED.rawValue }
}

import Foundation
import CGitKit

extension Repository {

    /// Whether `path` (relative to the repository root) has an entry in
    /// the index — at stage 0, or at any conflict stage during a merge.
    /// The single-file form of `git ls-files --error-unmatch <path>`:
    /// an exact path, not a pathspec, so a directory is never "tracked".
    public func isTracked(path: String) throws -> Bool {
        var index: OpaquePointer?
        try check(git_repository_index(&index, repo))
        defer { git_index_free(index) }
        try check(git_index_read(index, 0))
        return path.withCString { p in
            (0...3).contains { stage in git_index_get_bypath(index, p, Int32(stage)) != nil }
        }
    }

    /// Set or clear the skip-worktree bit of `path`'s index entry and
    /// write the index. Equivalent to `git update-index
    /// --[no-]skip-worktree <path>`: with the bit set, git (and
    /// libgit2's status, diff and add-all) stop noticing changes to the
    /// working-tree file, so they are never staged.
    ///
    /// Throws when `path` is not in the index (git: "Unable to mark
    /// file") and when another process holds the index lock
    /// (``Libgit2Error/isLocked``) — in that case the index is left
    /// unchanged.
    public func setSkipWorktree(_ enabled: Bool, path: String) throws {
        try updateIndexEntry(path: path) { entry in
            let bit = UInt16(GIT_INDEX_ENTRY_SKIP_WORKTREE.rawValue)
            if enabled {
                entry.flags_extended |= bit
            } else {
                entry.flags_extended &= ~bit
            }
        }
    }

    /// Set or clear the assume-unchanged bit of `path`'s index entry and
    /// write the index. Equivalent to `git update-index
    /// --[no-]assume-unchanged <path>`. Same failure behaviour as
    /// ``setSkipWorktree(_:path:)``.
    public func setAssumeUnchanged(_ enabled: Bool, path: String) throws {
        try updateIndexEntry(path: path) { entry in
            let bit = UInt16(GIT_INDEX_ENTRY_VALID.rawValue)
            if enabled {
                entry.flags |= bit
            } else {
                entry.flags &= ~bit
            }
        }
    }

    /// Re-reads the index, applies `change` to a copy of `path`'s stage-0
    /// entry, re-adds it and writes the index under libgit2's lock.
    private func updateIndexEntry(
        path: String,
        _ change: (inout git_index_entry) -> Void
    ) throws {
        var index: OpaquePointer?
        try check(git_repository_index(&index, repo))
        defer { git_index_free(index) }
        // Pick up changes another git process made since this repository
        // object last looked, so the write does not undo them.
        try check(git_index_read(index, 0))

        try path.withCString { p in
            guard let current = git_index_get_bypath(index, p, 0)?.pointee else {
                throw Libgit2Error(
                    code: GIT_ENOTFOUND.rawValue, klass: 0,
                    message: "Unable to mark file \(path)")
            }
            var entry = current
            change(&entry)
            try check(git_index_add(index, &entry))
        }
        do {
            try check(git_index_write(index))
        } catch {
            // Drop the in-memory change so a later write through the same
            // cached index cannot persist it after all.
            _ = git_index_read(index, 1)
            throw error
        }
    }
}

extension Libgit2Error {
    /// True when the operation failed because a lock file (for the
    /// index: `.git/index.lock`) is held by another process — git's
    /// "Unable to create '…/index.lock': File exists".
    public var isLocked: Bool { code == GIT_ELOCKED.rawValue }
}

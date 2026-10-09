import Foundation
import CGitKit

/// One index entry as `git ls-files -s` would render it: the
/// stage number (0 normally, 1/2/3 during a merge), the mode the
/// file is checked in with, the blob OID, and the relative path.
public struct IndexedEntry: Sendable, Equatable {
    /// Path relative to the repository root, as `git ls-files` prints it.
    public let path: String
    /// POSIX file-mode bits as stored in the index — octal `100644`
    /// for a regular file, `100755` executable, `120000` symlink.
    public let mode: UInt32
    /// Full 40-char SHA of the blob stored for this path.
    public let oid: String
    /// Index conflict stage as `ls-files -s` prints it: 0 = merged
    /// (normal), 1 = common ancestor, 2 = ours, 3 = theirs.
    public let stage: Int
    /// The entry's skip-worktree bit (`git update-index --skip-worktree`):
    /// git stops comparing the working-tree file against the index, so
    /// local changes to it are never reported or staged.
    public let skipWorktree: Bool
    /// The entry's assume-unchanged bit (`git update-index
    /// --assume-unchanged`, the on-disk "valid" flag).
    public let assumeUnchanged: Bool

    /// Creates an entry verbatim — no validation of `mode` or `stage`.
    public init(path: String, mode: UInt32, oid: String, stage: Int,
                skipWorktree: Bool = false, assumeUnchanged: Bool = false) {
        self.path = path
        self.mode = mode
        self.oid = oid
        self.stage = stage
        self.skipWorktree = skipWorktree
        self.assumeUnchanged = assumeUnchanged
    }

    /// The status tag `git ls-files -v` prints before the path: `H` for
    /// a cached entry, `S` for skip-worktree, `M` for an unmerged
    /// (conflict-stage) entry — lowercased when the entry is marked
    /// assume-unchanged.
    public var lsFilesTag: Character {
        let tag: Character = stage != 0 ? "M" : (skipWorktree ? "S" : "H")
        return assumeUnchanged ? Character(tag.lowercased()) : tag
    }
}

extension Repository {

    /// Resolve `spec` (a ref, sha, abbrev, `<ref>~N`, etc.) to a full
    /// 40-char SHA. Throws when the spec can't be resolved.
    public func resolveOID(_ spec: String) throws -> String {
        var obj: OpaquePointer?
        try check(git_revparse_single(&obj, repo, spec))
        defer { git_object_free(obj) }
        var oid = git_object_id(obj)?.pointee ?? git_oid()
        return formatOID(&oid)
    }

    /// Path to the repo's `.git` directory (or the bare-repo root for
    /// bare repos). Equivalent of `git rev-parse --git-dir`.
    public func gitDir() throws -> String? {
        git_repository_path(repo).map { String(cString: $0) }
    }

    /// Working-tree root, the value `git rev-parse --show-toplevel`
    /// prints. Nil for bare repositories.
    public func toplevel() throws -> String? {
        git_repository_workdir(repo).map { String(cString: $0) }
    }

    /// Tracked file paths (everything currently in the index).
    /// Equivalent of `git ls-files` with no flags.
    public func indexedPaths() throws -> [String] {
        try indexedEntries().map(\.path)
    }

    /// Full index entries — mode, OID, stage, path. Backs
    /// `git ls-files -s` / `--stage`. Returns entries in the order
    /// libgit2 walks them (sorted by path with merge stages
    /// interleaved per real git output).
    public func indexedEntries() throws -> [IndexedEntry] {
        var index: OpaquePointer?
        try check(git_repository_index(&index, repo))
        defer { git_index_free(index) }
        // The repository caches its index; pick up what other git processes
        // (staging, `update-index` flags) committed since it was loaded.
        try check(git_index_read(index, 0))
        let count = Int(git_index_entrycount(index))
        var entries: [IndexedEntry] = []
        entries.reserveCapacity(count)
        for i in 0..<count {
            guard let raw = git_index_get_byindex(index, i)?.pointee,
                  let p = raw.path
            else { continue }
            var oid = raw.id
            let oidString = String(unsafeUninitializedCapacity: 40) { buf in
                git_oid_fmt(buf.baseAddress, &oid)
                return 40
            }
            // The high 4 bits of `flags` encode the merge stage
            // (`GIT_INDEX_ENTRY_STAGE`). Real ls-files prints
            // that number as the third column.
            let stage = Int((raw.flags >> 12) & 0x3)
            entries.append(IndexedEntry(
                path: String(cString: p),
                mode: raw.mode,
                oid: oidString,
                stage: stage,
                skipWorktree: raw.flags_extended & UInt16(GIT_INDEX_ENTRY_SKIP_WORKTREE.rawValue) != 0,
                assumeUnchanged: raw.flags & UInt16(GIT_INDEX_ENTRY_VALID.rawValue) != 0))
        }
        return entries
    }

    /// True when the repository has a working tree — i.e. it is not
    /// bare. Backs `git rev-parse --is-inside-work-tree`.
    public func isInsideWorkTree() throws -> Bool {
        git_repository_workdir(repo) != nil
    }
}

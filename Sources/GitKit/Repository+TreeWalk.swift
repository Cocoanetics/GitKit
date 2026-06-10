import Foundation
import CGitKit

/// One blob produced by ``Repository/treeBlobs(of:prefix:)`` — a file (or
/// symlink) inside a git tree, with its content loaded.
public struct TreeBlob: Sendable {
    /// Path of the blob relative to the tree root, with any
    /// ``Repository/treeBlobs(of:prefix:)`` `prefix` prepended.
    public let path: String
    /// The raw git filemode (POSIX bits): `0o100644` regular,
    /// `0o100755` executable, `0o120000` symlink.
    public let mode: UInt32
    /// `true` for `0o100755` entries.
    public let isExecutable: Bool
    /// `true` for `0o120000` entries; ``bytes`` then holds the link target
    /// path rather than file content.
    public let isSymlink: Bool
    /// The blob's content (or the symlink target for symlink entries).
    public let bytes: Data
}

extension Repository {

    /// Walk `treeish`'s tree recursively and return one ``TreeBlob`` per
    /// blob, in `git ls-tree -r` order (alphabetical within each subtree),
    /// with content loaded. Submodule entries (gitlinks) are skipped, the
    /// way `git archive` skips them.
    ///
    /// This is the bulk-traversal primitive behind
    /// ``Repository/archive(treeish:format:to:prefix:)`` — a single pass
    /// with direct object lookups, as opposed to composing
    /// ``lsTree(_:recursive:)`` with per-blob ``catFileBlob(_:)`` calls.
    ///
    /// - Parameters:
    ///   - treeish: Anything that peels to a tree — `"HEAD"`, a branch,
    ///     a tag, a commit SHA, or a raw tree SHA.
    ///   - prefix: Prepended verbatim to every returned path (no separator
    ///     is added — pass a trailing `/` if you want one).
    public func treeBlobs(of treeish: String, prefix: String = "") throws -> [TreeBlob] {
        var obj: OpaquePointer?
        try check(treeish.withCString { name in
            git_revparse_single(&obj, repo, name)
        })
        defer { git_object_free(obj) }

        var tree: OpaquePointer?
        try check(git_object_peel(&tree, obj, GIT_OBJECT_TREE))
        defer { git_object_free(tree) }

        var collected: [TreeBlob] = []
        try walkBlobs(tree: tree, prefix: prefix, into: &collected)
        return collected
    }

    /// The commit timestamp `treeish` resolves to, or `nil` when it doesn't
    /// peel to a commit (e.g. a raw tree SHA, which carries no time).
    ///
    /// `git archive` stamps every entry with this so the same SHA produces
    /// a byte-identical archive across runs.
    public func commitTime(of treeish: String) throws -> Date? {
        var obj: OpaquePointer?
        try check(treeish.withCString { name in
            git_revparse_single(&obj, repo, name)
        })
        defer { git_object_free(obj) }

        var commit: OpaquePointer?
        guard git_object_peel(&commit, obj, GIT_OBJECT_COMMIT) == 0 else { return nil }
        defer { git_object_free(commit) }
        let unix = git_commit_time(commit)
        return Date(timeIntervalSince1970: TimeInterval(unix))
    }

    /// Recursive tree walk emitting one ``TreeBlob`` per blob. Matches
    /// `git ls-tree -r` order (alphabetical within each subtree).
    private func walkBlobs(
        tree: OpaquePointer?,
        prefix: String,
        into collected: inout [TreeBlob]
    ) throws {
        let count = git_tree_entrycount(tree)
        for i in 0..<count {
            try Task.checkCancellation()
            guard let entry = git_tree_entry_byindex(tree, i) else { continue }
            let name = String(cString: git_tree_entry_name(entry))
            let kind = git_tree_entry_type(entry)
            let mode = git_tree_entry_filemode(entry)
            switch kind {
            case GIT_OBJECT_TREE:
                var sub: OpaquePointer?
                if git_tree_lookup(&sub, repo, git_tree_entry_id(entry)) == 0 {
                    defer { git_object_free(sub) }
                    try walkBlobs(
                        tree: sub,
                        prefix: prefix + name + "/",
                        into: &collected)
                }
            case GIT_OBJECT_BLOB:
                var blob: OpaquePointer?
                try check(git_blob_lookup(
                    &blob, repo, git_tree_entry_id(entry)))
                defer { git_object_free(blob) }
                let size = Int(git_blob_rawsize(blob))
                let bytes: Data
                if size > 0, let raw = git_blob_rawcontent(blob) {
                    bytes = Data(bytes: raw, count: size)
                } else {
                    bytes = Data()
                }
                let modeRaw = mode.rawValue
                // libgit2 file modes follow POSIX mode bits:
                //   100644 = regular, 100755 = executable, 120000 = symlink.
                let isExec = (modeRaw == 0o100755)
                let isLink = (modeRaw == 0o120000)
                collected.append(TreeBlob(
                    path: prefix + name,
                    mode: UInt32(modeRaw),
                    isExecutable: isExec,
                    isSymlink: isLink,
                    bytes: bytes))
            case GIT_OBJECT_COMMIT:
                // Submodule entries (gitlinks) — `git archive` skips
                // them by default; do the same.
                continue
            default:
                continue
            }
        }
    }
}

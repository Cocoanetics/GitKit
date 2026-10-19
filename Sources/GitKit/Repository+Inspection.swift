import Foundation
import CGitKit

/// Rich result returned by ``Repository/commitDetailed(message:author:allowEmpty:env:)``
/// and ``Repository/amendDetailed(message:author:resetAuthor:allowEmpty:allowEmptyMessage:cleanup:env:)``.
/// The CLI uses this to format `git commit`'s `[branch sha] message` line,
/// the ` Author:` / ` Date:` lines, the
/// `<n> file(s) changed, <i> insertion(s)(+), <d> deletion(s)(-)`
/// summary and the per-file `create mode` / `delete mode` / `rename`
/// lines.
public struct Libgit2CommitDetails: Sendable {
    /// Full 40-hex SHA of the newly created commit.
    public let sha: String
    /// First 7 hex chars of `sha` — what git prints in `[branch sha]`.
    public let shortSHA: String
    /// Branch the commit landed on, nil when HEAD was detached.
    public let branchName: String?
    /// True when the commit has no parent (first commit on an unborn
    /// branch). Real git prints `[branch (root-commit) sha]` then.
    public let isRoot: Bool
    /// Number of files touched, for the `<n> file(s) changed` summary.
    public let filesChanged: Int
    /// Total lines added across all files — the `(+)` count.
    public let insertions: Int
    /// Total lines removed across all files — the `(-)` count.
    public let deletions: Int
    /// Files this commit adds, for the `create mode` lines.
    public let addedFiles: [FileChange]
    /// Files this commit deletes, for the `delete mode` lines.
    public let deletedFiles: [FileChange]
    /// Files this commit renames, found as git's summary finds them
    /// (always, whatever `diff.renames` says), for the `rename` lines; a
    /// rename is in neither ``addedFiles`` nor ``deletedFiles``. Git
    /// orders the summary's lines by the new path.
    public let renamedFiles: [Rename]
    /// The author recorded — name, email and author date. Real git prints
    /// ` Author: <name> <email>` when name or email differ from
    /// ``committer``'s.
    public let author: ResolvedSignature
    /// The committer recorded — name, email and commit date.
    public let committer: ResolvedSignature
    /// Whether real git prints ` Date: <author date>` (format with
    /// ``ResolvedSignature/formattedDate``): true for an amend that keeps
    /// the old authorship, even when both dates are equal; false for a
    /// plain commit and `--reset-author`, even when `GIT_AUTHOR_DATE`
    /// differs from the commit date.
    public let showsAuthorDate: Bool

    /// A file added or deleted by the commit, with the mode real git
    /// shows in its `create mode` / `delete mode` summary lines.
    public struct FileChange: Sendable {
        /// Repo-relative path of the file.
        public let path: String
        /// POSIX file-mode bits (octal `100644` regular, `100755`
        /// executable, `120000` symlink); format with `%06o`.
        public let mode: UInt32
    }

    /// A file renamed by the commit. Git's summary prints
    /// ` rename <name> (<similarity>%)`, then
    /// ` mode change <oldMode> => <newMode>` (each `%06o`) when the mode
    /// changed too.
    public struct Rename: Sendable {
        /// Repo-relative path before the rename.
        public let oldPath: String
        /// Repo-relative path after the rename.
        public let newPath: String
        /// How alike the two contents are, 0–100.
        public let similarity: Int
        /// POSIX file-mode bits before the rename.
        public let oldMode: UInt32
        /// POSIX file-mode bits after the rename.
        public let newMode: UInt32

        /// `old => new` as git's summary writes it (`pprint_rename`):
        /// `dir/{a => b}` around what both paths share, the paths quoted
        /// as with `core.quotePath` when they need it.
        public func name(quotePath: Bool = true) -> String {
            Repository.renameText(Array(oldPath.utf8), Array(newPath.utf8), quotePath: quotePath)
        }
    }
}

extension Repository {
    /// Whether `path` (relative to the repo workdir) is currently
    /// matched by a `.gitignore` rule. Throws on libgit2 failure;
    /// `false` if the path doesn't exist or isn't ignored.
    public func isIgnored(_ path: String) throws -> Bool {
        var ignored: Int32 = 0
        try check(git_ignore_path_is_ignored(&ignored, repo, path))
        return ignored != 0
    }

    /// Local branch names in the repo. Order matches libgit2's iterator
    /// (typically refdb order — alphabetical for refs/heads/*).
    public func localBranches() throws -> [String] {
        var iter: OpaquePointer?
        try check(git_branch_iterator_new(&iter, repo, GIT_BRANCH_LOCAL))
        defer { git_branch_iterator_free(iter) }

        var names: [String] = []
        while true {
            try Task.checkCancellation()
            var ref: OpaquePointer?
            var branchType = GIT_BRANCH_LOCAL
            let rc = git_branch_next(&ref, &branchType, iter)
            if rc == GIT_ITEROVER.rawValue { break }
            try check(rc)
            defer { git_reference_free(ref) }
            if let cstr = git_branch_name_cstr(ref) {
                names.append(String(cString: cstr))
            }
        }
        return names
    }
}

/// Helper: libgit2's `git_branch_name` writes into a buffer, but the
/// shorthand is simpler. We use `git_reference_shorthand` since for
/// `refs/heads/X` it returns `X`.
private func git_branch_name_cstr(_ ref: OpaquePointer?) -> UnsafePointer<CChar>? {
    git_reference_shorthand(ref)
}

extension Repository {
    /// List configured remote names. Sorted alphabetically to match
    /// `git remote`'s default order.
    public func remoteList() throws -> [String] {
        var arr = git_strarray()
        try check(git_remote_list(&arr, repo))
        defer { git_strarray_dispose(&arr) }
        var names: [String] = []
        for i in 0..<arr.count {
            if let cstr = arr.strings?[i] {
                names.append(String(cString: cstr))
            }
        }
        return names.sorted()
    }

    /// Delete a remote and the associated `branch.<x>.remote` config
    /// entries (libgit2 does the cleanup).
    public func remoteDelete(name: String) throws {
        try check(name.withCString { n in
            git_remote_delete(repo, n)
        })
    }

    /// Rename `oldName` → `newName`. Returns the list of unfixable
    /// branch refspec problems libgit2 surfaces (typically empty).
    @discardableResult
    public func remoteRename(from oldName: String, to newName: String) throws -> [String] {
        var problems = git_strarray()
        try check(git_remote_rename(&problems, repo, oldName, newName))
        defer { git_strarray_dispose(&problems) }
        var names: [String] = []
        for i in 0..<problems.count {
            if let cstr = problems.strings?[i] {
                names.append(String(cString: cstr))
            }
        }
        return names
    }

    /// Update an existing remote's URL. With the remote as typed, prefer
    /// ``remoteSetURL(name:remote:)``: a `URL` can't always hold a
    /// scp-style remote exactly (see ``URL/gitRemote``).
    public func remoteSetURL(name: String, url: URL) throws {
        try remoteSetURL(name: name, remote: url.gitRemote)
    }

    /// Point an existing remote at `remote` — a URL, a scp-style
    /// `[user@]host:path` or a path, stored exactly as given.
    public func remoteSetURL(name: String, remote: String) throws {
        try check(name.withCString { n in
            remote.withCString { u in
                git_remote_set_url(repo, n, u)
            }
        })
    }

    /// True when a remote with `name` is already configured. Mirrors
    /// `git config remote.<name>.url` existence; used by `git remote add`
    /// to fail fast with the same error wording git uses.
    public func remoteExists(named name: String) throws -> Bool {
        var remote: OpaquePointer?
        let rc = git_remote_lookup(&remote, repo, name)
        if rc == 0 {
            git_remote_free(remote)
            return true
        }
        if rc == GIT_ENOTFOUND.rawValue { return false }
        try check(rc)
        return false
    }

    /// Delete a local branch. Equivalent to `git branch -d <name>`
    /// (or `-D` with `force`).
    public func branchDelete(name: String, force: Bool = false) throws {
        var ref: OpaquePointer?
        let lookupRC = git_branch_lookup(&ref, repo, name, GIT_BRANCH_LOCAL)
        if lookupRC == GIT_ENOTFOUND.rawValue {
            throw Libgit2Error(code: -1, klass: 0,
                message: "branch '\(name)' not found.")
        }
        try check(lookupRC)
        defer { git_reference_free(ref) }

        // Real git's `-d` (without `-D`) errors when the branch
        // hasn't been merged into HEAD; libgit2 doesn't enforce
        // that, so we run the check ourselves via descendant_of.
        if !force, try unmergedAgainstHead(repo: repo, ref: ref) {
            throw Libgit2Error(code: -1, klass: 0,
                message: "the branch '\(name)' is not fully merged.")
        }
        try check(git_branch_delete(ref))
    }

    /// Rename `oldName` (or the current branch when nil) to `newName`.
    /// `force == true` overwrites an existing branch with the new name.
    public func branchRename(
        from oldName: String? = nil, to newName: String, force: Bool = false
    ) throws {
        // Resolve the current branch when no explicit old name was
        // given, then rename in one go.
        let resolvedOld: String
        if let oldName {
            resolvedOld = oldName
        } else {
            guard let current = try currentBranch() else {
                throw Libgit2Error(code: -1, klass: 0,
                    message: "no current branch to rename")
            }
            resolvedOld = current
        }
        var ref: OpaquePointer?
        try check(git_branch_lookup(&ref, repo, resolvedOld, GIT_BRANCH_LOCAL))
        defer { git_reference_free(ref) }
        var newRef: OpaquePointer?
        try check(git_branch_move(&newRef, ref, newName, force ? 1 : 0))
        git_reference_free(newRef)
    }

    /// Helper: true when `ref`'s commit is NOT reachable from HEAD.
    /// Used by `branchDelete` to mimic real git's `-d` safety check.
    private func unmergedAgainstHead(repo: OpaquePointer?, ref: OpaquePointer?) throws -> Bool {
        guard let target = git_reference_target(ref) else { return false }
        var head: OpaquePointer?
        let headRC = git_repository_head(&head, repo)
        if headRC != 0 { return false }
        defer { git_reference_free(head) }
        guard let headTarget = git_reference_target(head) else { return false }

        var refOID = target.pointee
        var headOID = headTarget.pointee
        // Same-commit case: branches pointing at HEAD are considered
        // merged (real git allows `-d` here without complaint).
        if withUnsafePointer(to: &refOID, { ref in
            withUnsafePointer(to: &headOID, { head in
                git_oid_cmp(ref, head) == 0
            })
        }) {
            return false
        }
        let rc = git_graph_descendant_of(repo, &headOID, &refOID)
        if rc < 0 { return false }
        return rc == 0  // 1 = HEAD descends from ref → merged; 0 = unmerged
    }
}

import Foundation
import CGitKit

/// One remote-tracking branch returned by ``Repository/remoteBranches(remote:)``.
public struct RemoteBranch: Sendable, Equatable {
    /// Remote-qualified name, e.g. `origin/main` or `origin/HEAD`.
    public let name: String
    /// Full SHA of the target, resolving symbolic refs such as `origin/HEAD`.
    public let targetSHA: String
}

/// One named reference returned by ``Repository/references(matching:)``.
public struct ReferenceEntry: Sendable, Equatable {
    /// Full reference name, e.g. `refs/remotes/origin/main` or `refs/tags/v1`.
    public let name: String
    /// Full SHA after resolving symbolic refs. Annotated tags point at the
    /// tag object, not the peeled commit, as in `git for-each-ref`'s `objectname`.
    public let targetSHA: String
    /// Full target reference name for a symbolic ref; nil for a direct ref.
    public let symbolicTarget: String?
}

extension Repository {

    /// List remote-tracking branches, sorted by remote-qualified name, as
    /// `git branch -r` does (including symbolic refs such as `origin/HEAD`).
    /// Pass a remote name to restrict the listing to `refs/remotes/<remote>/`;
    /// an unknown remote returns an empty list. Reads local refs only.
    /// Dangling symbolic refs are omitted, as they are by git.
    public func remoteBranches(remote: String? = nil) throws -> [RemoteBranch] {
        var iter: OpaquePointer?
        try check(git_branch_iterator_new(&iter, repo, GIT_BRANCH_REMOTE))
        defer { git_branch_iterator_free(iter) }

        var branches: [RemoteBranch] = []
        while true {
            try Task.checkCancellation()
            var ref: OpaquePointer?
            var branchType = GIT_BRANCH_REMOTE
            let rc = git_branch_next(&ref, &branchType, iter)
            if rc == GIT_ITEROVER.rawValue { break }
            try check(rc)
            defer { git_reference_free(ref) }
            guard let cstr = git_reference_name(ref) else { continue }
            let fullName = String(cString: cstr)
            if let remote, !fullName.hasPrefix("refs/remotes/\(remote)/") { continue }
            if let entry = try referenceEntry(from: ref) {
                branches.append(RemoteBranch(
                    name: String(fullName.dropFirst("refs/remotes/".count)),
                    targetSHA: entry.targetSHA))
            }
        }
        return branches.sorted { $0.name < $1.name }
    }

    /// List references matching a libgit2 fnmatch glob against full ref names
    /// (e.g. `refs/remotes/*` or `refs/tags/v*`). `*` also matches `/`.
    /// Pass nil to list all refs under `refs/`, excluding pseudorefs like HEAD.
    /// Includes loose and packed refs, sorted by full name, and resolves
    /// symbolic targets. Dangling symbolic refs are omitted, as in git.
    public func references(matching pattern: String? = nil) throws -> [ReferenceEntry] {
        var iter: UnsafeMutablePointer<git_reference_iterator>?
        if let pattern {
            try check(git_reference_iterator_glob_new(&iter, repo, pattern))
        } else {
            try check(git_reference_iterator_new(&iter, repo))
        }
        defer { git_reference_iterator_free(iter) }

        var entries: [ReferenceEntry] = []
        while true {
            try Task.checkCancellation()
            var ref: OpaquePointer?
            let rc = git_reference_next(&ref, iter)
            if rc == GIT_ITEROVER.rawValue { break }
            try check(rc)
            defer { git_reference_free(ref) }
            if let entry = try referenceEntry(from: ref) {
                entries.append(entry)
            }
        }
        return entries.sorted { $0.name < $1.name }
    }

    private func referenceEntry(from ref: OpaquePointer?) throws -> ReferenceEntry? {
        guard let cstr = git_reference_name(ref) else { return nil }
        let symbolicTarget = git_reference_symbolic_target(ref).map { String(cString: $0) }
        var resolved: OpaquePointer?
        let rc = git_reference_resolve(&resolved, ref)
        if rc == GIT_ENOTFOUND.rawValue { return nil }
        try check(rc)
        defer { git_reference_free(resolved) }
        guard var oid = git_reference_target(resolved)?.pointee else { return nil }
        return ReferenceEntry(
            name: String(cString: cstr), targetSHA: formatOID(&oid),
            symbolicTarget: symbolicTarget)
    }
}

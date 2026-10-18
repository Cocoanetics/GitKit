import Foundation
import CGitKit

extension Repository {

    /// `remote` read the way git reads a `<repository>` argument: the
    /// name of a configured remote, or else a URL or path, which is
    /// fetched from or pushed to through an anonymous remote — nothing
    /// is added to the repository's configuration.
    ///
    /// - Returns: the remote handle (the caller frees it with
    ///   `git_remote_free`) and whether it's a configured remote.
    func lookupRemote(_ remote: String) throws -> (handle: OpaquePointer?, isConfigured: Bool) {
        var handle: OpaquePointer?
        let rc = git_remote_lookup(&handle, repo, remote)
        if rc == 0 { return (handle, true) }
        // A URL or path isn't a valid remote name, and a name that isn't
        // configured may be a relative path: either way, git tries it as
        // a repository location.
        guard rc == GIT_ENOTFOUND.rawValue || rc == GIT_EINVALIDSPEC.rawValue else {
            try check(rc)
            return (handle, true)
        }
        git_error_clear()
        try check(git_remote_create_anonymous(&handle, repo, remote))
        return (handle, false)
    }
}

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

    /// Point `handle` at `location` for `direction`, in place of where
    /// its configuration or the remote as given would take it. libgit2
    /// connects to exactly this string: no `insteadOf` rewriting, and a
    /// relative path is read against the process's directory, so a
    /// caller that resolved and authorized `location` connects there
    /// and nowhere else. A push connects to the push URL when there is
    /// one (`git_remote__urlfordirection`), but libgit2's local transport
    /// opens the URL to push to a path, so a push replaces both.
    ///
    /// - Returns: `location`, or `nil` when there's none to connect to.
    @discardableResult
    func connect(_ handle: OpaquePointer?, to location: String?, for direction: git_direction) throws -> String? {
        guard let location else { return nil }
        try check(git_remote_set_instance_url(handle, location))
        if direction == GIT_DIRECTION_PUSH, git_remote_pushurl(handle) != nil {
            try check(git_remote_set_instance_pushurl(handle, location))
        }
        return location
    }

    /// FETCH_HEAD with each entry naming `url` for the repository it
    /// came from, instead of the URL libgit2 connected to; nothing else
    /// on the line changes.
    func relabelFetchHead(as url: String) throws {
        guard let gitDir = git_repository_path(repo) else { return }
        let path = String(cString: gitDir) + "FETCH_HEAD"
        guard let data = FileManager.default.contents(atPath: path) else { return }

        // The URL each line ends with, in order, as libgit2 reads it back.
        final class URLs { var list: [[UInt8]] = [] }
        let urls = URLs()
        let payload = Unmanaged.passUnretained(urls).toOpaque()
        _ = git_repository_fetchhead_foreach(repo, { _, url, _, _, payload in
            guard let payload else { return 0 }
            Unmanaged<URLs>.fromOpaque(payload).takeUnretainedValue()
                .list.append(url.map { Array(String(cString: $0).utf8) } ?? [])
            return 0
        }, payload)

        var lines = Array(data).split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        let shown = Array(url.utf8)
        var changed = false
        for (index, written) in zip(lines.indices, urls.list)
        where !written.isEmpty && lines[index].count >= written.count
            && lines[index].suffix(written.count).elementsEqual(written) {
            lines[index] = ArraySlice(lines[index].dropLast(written.count) + shown)
            changed = true
        }
        guard changed else { return }
        let relabelled = lines.joined(separator: [UInt8(ascii: "\n")])
        try Data(relabelled).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

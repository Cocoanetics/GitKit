import Foundation

extension URL {
    /// The remote spelled the way git spells it, for handing to libgit2.
    ///
    /// Foundation parses a scp-style remote (`git@github.com:o/r.git`)
    /// as a URL without a scheme and percent-encodes what it doesn't
    /// allow there, so `git@[::1]:r.git` comes back from
    /// `absoluteString` as `git@%5B%3A%3A1%5D%3Ar.git`, which libgit2
    /// can't read. Such a remote is decoded again; a real URL
    /// (`scheme://…`) passes through unchanged. A literal `%XX` in a
    /// scp-style path would be decoded too; git paths don't carry them
    /// in practice.
    var gitRemote: String {
        let string = absoluteString
        guard !string.contains("://") else { return string }
        return string.removingPercentEncoding ?? string
    }
}

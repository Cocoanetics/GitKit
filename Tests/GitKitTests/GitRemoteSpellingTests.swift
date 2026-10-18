import Foundation
import Testing
@testable import GitKit

/// How a remote reaches libgit2 and the SSH bridge. Foundation
/// percent-encodes scp-style remotes it parses without a scheme, which
/// turned `git@[::1]:r.git` into a remote libgit2 couldn't read.
@Suite("Remote spelling")
struct GitRemoteSpellingTests {

    @Test("scp-style remotes are decoded back to git's spelling")
    func scpStyleRemotesAreDecoded() {
        let remotes = [
            "git@github.com:owner/repo.git",
            "git@[::1]:repo.git",
            "[fe80::1%en0]:repo.git",
            "host:path/with space.git",
            "host:café.git",
            "git@host:~/repo.git",
            "../relative/repo"
        ]
        for remote in remotes {
            #expect(URL(string: remote)?.gitRemote == remote)
        }
    }

    @Test("escapes that were valid in the remote stay as written")
    func validEscapesStay() {
        #expect(URL(string: "git@host:repos%2Fteam.git")?.gitRemote == "git@host:repos%2Fteam.git")
        #expect(URL(string: "host:100%done.git")?.gitRemote == "host:100%done.git")
    }

    @Test("URLs with a scheme pass through unchanged")
    func urlsPassThrough() {
        let urls = [
            "ssh://git@[::1]:2222/repo.git",
            "https://example.com/a%20b.git",
            "file:///tmp/repo"
        ]
        for url in urls {
            #expect(URL(string: url)?.gitRemote == url)
        }
    }

    @Test("the SSH bridge parses bracketed IPv6 scp remotes")
    func bridgeParsesBracketedHosts() throws {
        let ipv6 = try #require(GitSSHURL.parse("git@[::1]:repo.git"))
        #expect(ipv6.user == "git")
        #expect(ipv6.host == "::1")
        #expect(ipv6.path == "repo.git")

        let zoned = try #require(GitSSHURL.parse("[fe80::1%en0]:/srv/r.git"))
        #expect(zoned.user == nil)
        #expect(zoned.host == "fe80::1%en0")
        #expect(zoned.path == "/srv/r.git")

        let plain = try #require(GitSSHURL.parse("deploy@host:pa@th"))
        #expect(plain.user == "deploy")
        #expect(plain.host == "host")
        #expect(plain.path == "pa@th")

        #expect(GitSSHURL.parse("git@[::1]repo.git") == nil)
        #expect(GitSSHURL.parse("@host:path") == nil)
    }
}

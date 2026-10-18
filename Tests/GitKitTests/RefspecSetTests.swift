// Integration tests for fetching and pushing several refspecs at once.
// Fixtures are built with the system `git` CLI (gated to non-Windows for
// the same reasons as the other integration suites); everything under
// test goes through `Repository`.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

/// Collects progress text; the sink is `@Sendable`.
private final class OutputLog: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    func append(_ text: String) { lock.lock(); buffer += text; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return buffer }
}

/// `fetch(remote:refspecs:)` and `push(remote:refspecs:)` apply their
/// refspecs together, as git does, and push takes git's pattern,
/// matching and negative refspecs.
@Suite("Refspec sets")
struct RefspecSetTests {

    // MARK: Fixtures

    private func tmp(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RefspecSetTests-\(label)-\(UUID().uuidString)")
    }

    /// A repository on `main` with one commit and the branches `names`
    /// at that commit.
    private func makeRepo(branches names: [String] = []) throws -> URL {
        let dir = tmp("work")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-q", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "test@example.com"], in: dir)
        try runGit(["config", "user.name", "Test"], in: dir)
        try runGit(["commit", "-q", "--allow-empty", "-m", "one"], in: dir)
        for name in names { try runGit(["branch", name], in: dir) }
        return dir
    }

    private func makeBare() throws -> URL {
        let dir = tmp("bare").appendingPathExtension("git")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-q", "--bare", "-b", "main"], in: dir)
        return dir
    }

    @discardableResult
    private func runGit(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = dir
        let out = Pipe(); let err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        p.waitUntilExit()
        let outStr = String(decoding: (try? out.fileHandleForReading.readToEnd()) ?? Data(),
                            as: UTF8.self)
        if p.terminationStatus != 0 {
            let errStr = String(decoding: (try? err.fileHandleForReading.readToEnd()) ?? Data(),
                                as: UTF8.self)
            throw Failure("git \(args.joined(separator: " ")) failed: \(errStr)")
        }
        return outStr
    }

    private struct Failure: Error, CustomStringConvertible {
        let message: String
        init(_ m: String) { self.message = m }
        var description: String { message }
    }

    private func refs(_ prefix: String, in dir: URL) throws -> [String] {
        try runGit(["for-each-ref", "--format=%(refname)", prefix], in: dir)
            .split(separator: "\n").map(String.init)
    }

    /// The summary lines of a push: what follows the `To <url>` header.
    private func summary(_ output: String) -> [String] {
        output.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("To ") }
    }

    private func removing(_ dirs: URL...) -> () -> Void {
        { for dir in dirs { try? FileManager.default.removeItem(at: dir) } }
    }

    // MARK: Fetch

    @Test("a remote's negative fetch refspec excludes what its wildcard matches")
    func negativeFetchRefspec() throws {
        let source = try makeRepo(branches: ["dev", "private"])
        let dest = try makeRepo()
        defer { removing(source, dest)() }
        try runGit(["remote", "add", "origin", source.path], in: dest)
        try runGit(["config", "--add", "remote.origin.fetch", "^refs/heads/private"], in: dest)

        let repo = try Repository.open(at: dest)
        try repo.fetch(remote: "origin", refspecs: [], progress: { _ in })
        #expect(try refs("refs/remotes", in: dest)
                == ["refs/remotes/origin/dev", "refs/remotes/origin/main"])
        // FETCH_HEAD lists everything fetched, not just a last refspec's refs.
        let fetchHead = try String(contentsOf: dest.appendingPathComponent(".git/FETCH_HEAD"),
                                   encoding: .utf8)
        #expect(fetchHead.split(separator: "\n").count == 2)

        // Refspecs given to the fetch replace the configured ones, their
        // negative refspec included, as in git.
        try runGit(["update-ref", "-d", "refs/remotes/origin/dev"], in: dest)
        try runGit(["update-ref", "-d", "refs/remotes/origin/main"], in: dest)
        try repo.fetch(remote: "origin",
                       refspecs: ["+refs/heads/*:refs/remotes/origin/*", "^refs/heads/main"],
                       progress: { _ in })
        #expect(try refs("refs/remotes", in: dest)
                == ["refs/remotes/origin/dev", "refs/remotes/origin/private"])
    }

    @Test("a negative refspec doesn't stop a tag from being followed, as in git")
    func negativeRefspecAndFollowedTags() throws {
        let source = try makeRepo()
        let dest = try makeRepo()
        defer { removing(source, dest)() }
        try runGit(["remote", "add", "origin", source.path], in: dest)
        try runGit(["config", "--add", "remote.origin.fetch", "^refs/tags/t"], in: dest)
        try runGit(["commit", "-q", "--allow-empty", "-m", "two"], in: source)
        try runGit(["tag", "t"], in: source)

        try Repository.open(at: dest).fetch(remote: "origin", refspecs: [], progress: { _ in })
        #expect(try refs("refs/tags", in: dest) == ["refs/tags/t"])
    }

    @Test("a remote without a fetch refspec fetches only HEAD, into FETCH_HEAD")
    func fetchWithoutMapping() throws {
        let source = try makeRepo(branches: ["dev"])
        let dest = try makeRepo()
        defer { removing(source, dest)() }
        try runGit(["remote", "add", "nomap", source.path], in: dest)
        try runGit(["config", "--unset-all", "remote.nomap.fetch"], in: dest)

        try Repository.open(at: dest).fetch(remote: "nomap", refspecs: [], progress: { _ in })
        #expect(try refs("refs/remotes", in: dest).isEmpty)
        let head = try runGit(["rev-parse", "HEAD"], in: source)
        #expect(try runGit(["rev-parse", "FETCH_HEAD"], in: dest) == head)
    }

    // MARK: Push

    @Test("several refspecs go out in one push, with one summary")
    func severalRefspecsInOnePush() throws {
        let work = try makeRepo(branches: ["dev"])
        let bare = try makeBare()
        defer { removing(work, bare)() }
        try runGit(["remote", "add", "origin", bare.path], in: work)

        let log = OutputLog()
        try Repository.open(at: work).push(
            remote: "origin", refspecs: ["main", "HEAD:refs/heads/review", "dev"],
            setUpstream: true, progress: { log.append($0) })
        #expect(log.text.components(separatedBy: "To ").count == 2)
        #expect(Set(summary(log.text)) == [
            " * [new branch]      main -> main",
            " * [new branch]      HEAD -> review",
            " * [new branch]      dev -> dev"
        ])
        #expect(try runGit(["config", "branch.dev.merge"], in: work) == "refs/heads/dev\n")
    }

    @Test("the matching refspec pushes the branches both sides have")
    func matchingRefspec() throws {
        let work = try makeRepo(branches: ["dev", "local-only"])
        let bare = try makeBare()
        defer { removing(work, bare)() }
        try runGit(["remote", "add", "origin", bare.path], in: work)
        try runGit(["push", "-q", "origin", "main", "dev"], in: work)
        try runGit(["commit", "-q", "--allow-empty", "-m", "two"], in: work)
        try runGit(["branch", "-f", "dev", "HEAD"], in: work)
        try runGit(["branch", "-f", "local-only", "HEAD"], in: work)

        let repo = try Repository.open(at: work)
        let log = OutputLog()
        let pushed = try repo.push(remote: "origin", refspecs: [":"], setUpstream: false,
                                   progress: { log.append($0) })
        #expect(pushed == ["refs/heads/dev:refs/heads/dev", "refs/heads/main:refs/heads/main"])
        let lines = summary(log.text)
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.hasSuffix(" dev -> dev") || $0.hasSuffix(" main -> main") })
        #expect(try refs("refs/heads", in: bare) == ["refs/heads/dev", "refs/heads/main"])

        let again = OutputLog()
        try repo.push(remote: "origin", refspec: ":", setUpstream: false,
                      progress: { again.append($0) })
        #expect(again.text == "Everything up-to-date\n")
    }

    @Test("matching against a remote without refs refuses, as git does")
    func matchingAgainstAnEmptyRemote() throws {
        let work = try makeRepo()
        let bare = try makeBare()
        defer { removing(work, bare)() }

        let log = OutputLog()
        #expect(throws: Libgit2Error.self) {
            try Repository.open(at: work).push(
                remote: bare.path, refspecs: [":"], setUpstream: false,
                progress: { log.append($0) })
        }
        #expect(log.text == """
            No refs in common and none specified; doing nothing.
            Perhaps you should specify a branch.

            """)
    }

    @Test("negatives that leave none of the remote's refs refuse, as in git")
    func negativesExcludingEverything() throws {
        let work = try makeRepo(branches: ["dev"])
        let bare = try makeBare()
        defer { removing(work, bare)() }
        try runGit(["push", "-q", bare.path, "main"], in: work)
        let repo = try Repository.open(at: work)

        let log = OutputLog()
        #expect(throws: Libgit2Error.self) {
            try repo.push(remote: bare.path,
                          refspecs: ["refs/heads/*:refs/heads/*", "^refs/heads/*"],
                          setUpstream: false, progress: { log.append($0) })
        }
        #expect(log.text.hasPrefix("No refs in common and none specified; doing nothing.\n"))

        // A remote whose only ref, an annotated tag, is excluded too.
        let tagged = try makeBare()
        defer { removing(tagged)() }
        try runGit(["tag", "-a", "-m", "t", "t"], in: work)
        try runGit(["push", "-q", tagged.path, "t"], in: work)
        #expect(throws: Libgit2Error.self) {
            try repo.push(remote: tagged.path,
                          refspecs: ["refs/heads/*:refs/heads/*", "^refs/heads/*", "^refs/tags/t"],
                          setUpstream: false, progress: { _ in })
        }

        // With some of the remote's refs left, there is just nothing to do.
        let quiet = OutputLog()
        try repo.push(remote: bare.path, refspecs: ["dev", "^refs/heads/dev"],
                      setUpstream: false, progress: { quiet.append($0) })
        #expect(quiet.text == "Everything up-to-date\n")
    }

    @Test("patterns push each local ref they match; negatives drop destinations")
    func patternsAndNegatives() throws {
        let work = try makeRepo(branches: ["dev", "wip/a", "private"])
        let mirror = try makeBare()
        let mapped = try makeBare()
        defer { removing(work, mirror, mapped)() }

        let repo = try Repository.open(at: work)
        try repo.push(remote: mirror.path,
                      refspecs: ["refs/heads/*:refs/heads/*", "^refs/heads/wip/*",
                                 "^refs/heads/private"],
                      setUpstream: false, progress: { _ in })
        #expect(try refs("refs/heads", in: mirror) == ["refs/heads/dev", "refs/heads/main"])

        // A negative refspec names the remote ref, as in git.
        try repo.push(remote: mapped.path,
                      refspecs: ["+refs/heads/*:refs/heads/x/*", "^refs/heads/x/wip/*", "dev"],
                      setUpstream: false, progress: { _ in })
        #expect(try refs("refs/heads", in: mapped) == [
            "refs/heads/dev", "refs/heads/x/dev", "refs/heads/x/main", "refs/heads/x/private"
        ])

        // Malformed patterns and negatives are refused before anything
        // goes out, as in git.
        let malformed = [
            ["refs/heads/*:refs/heads/x"], ["refs/heads/**:refs/heads/**"],
            ["refs/heads/*", "^refs/heads/**"], ["refs/heads/*", "^"],
            ["refs/heads/*", "^refs/heads//private"], ["refs/heads//*:refs/heads/*"],
            ["refs/heads/*", "^refs/heads/wip:refs/heads/wip"],
            ["refs/heads/*", "^" + String(repeating: "a", count: 40)]
        ]
        let untouched = try makeBare()
        defer { removing(untouched)() }
        for refspecs in malformed {
            #expect(throws: Libgit2Error.self, "\(refspecs)") {
                try repo.push(remote: untouched.path, refspecs: refspecs,
                              setUpstream: false, progress: { _ in })
            }
        }
        #expect(try refs("refs/heads", in: untouched).isEmpty)

        // A `*` inside a component, as git allows.
        let archive = try makeBare()
        defer { removing(archive)() }
        try runGit(["branch", "release-1"], in: work)
        try runGit(["branch", "release-2"], in: work)
        try repo.push(remote: archive.path,
                      refspecs: ["refs/heads/release-*:refs/heads/archive-*", "^refs/heads/archive-*2"],
                      setUpstream: false, progress: { _ in })
        #expect(try refs("refs/heads", in: archive) == ["refs/heads/archive-1"])

        // Any revision as the source, with a full destination.
        try repo.push(remote: archive.path, refspecs: ["HEAD^{commit}:refs/heads/rev"],
                      setUpstream: false, progress: { _ in })
        #expect(try runGit(["rev-parse", "rev"], in: archive) == runGit(["rev-parse", "HEAD"], in: work))
        #expect(throws: Libgit2Error.self) {
            try repo.push(remote: archive.path, refspecs: ["HEAD^{commit}:rev2"],
                          setUpstream: false, progress: { _ in })
        }

        // A pattern leaves alone a destination an explicit refspec claims,
        // while explicit refspecs all go out, as in git.
        try runGit(["commit", "-q", "--allow-empty", "-m", "two"], in: work)
        let claimed = try makeBare()
        defer { removing(claimed)() }
        #expect(throws: PushRejectedError.self) {
            try repo.push(remote: claimed.path,
                          refspecs: ["main:refs/heads/x", "dev:refs/heads/x"],
                          setUpstream: false, progress: { _ in })
        }
        let pushed = try repo.push(remote: claimed.path,
                                   refspecs: ["refs/heads/dev:refs/heads/main",
                                              "refs/heads/*:refs/heads/*"],
                                   setUpstream: false, progress: { _ in })
        #expect(pushed.filter { $0.hasSuffix(":refs/heads/main") }
                == ["refs/heads/dev:refs/heads/main"])
        #expect(try runGit(["rev-parse", "main"], in: claimed)
                == runGit(["rev-parse", "dev"], in: work))
        #expect(throws: Libgit2Error.self) {
            try repo.push(remote: mapped.path, refspec: "refs/heads/*", setUpstream: false,
                          forceWithLease: .tracking, progress: { _ in })
        }
    }

    @Test("no refspecs push what the remote is configured to push")
    func configuredPushRefspecs() throws {
        let work = try makeRepo(branches: ["dev"])
        let bare = try makeBare()
        defer { removing(work, bare)() }
        try runGit(["remote", "add", "origin", bare.path], in: work)
        try runGit(["config", "remote.origin.push", "refs/heads/dev:refs/heads/from-config"],
                   in: work)

        let log = OutputLog()
        try Repository.open(at: work).push(
            remote: "origin", refspecs: [], setUpstream: false, progress: { log.append($0) })
        #expect(summary(log.text) == [" * [new branch]      dev -> from-config"])
        #expect(try refs("refs/heads", in: bare) == ["refs/heads/from-config"])
    }
}
#endif

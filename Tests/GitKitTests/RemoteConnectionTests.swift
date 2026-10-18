// Integration tests for fetching from and pushing to a location the
// caller resolved (`connectingTo:`). Fixtures are built with the system
// `git` CLI (gated to non-Windows for the same reasons as the other
// integration suites); everything under test goes through `Repository`.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

/// Collects progress text; the sink is `@Sendable`.
private final class ConnectionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    func append(_ text: String) { lock.lock(); buffer += text; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return buffer }
}

/// git opens a relative remote from the top of the work tree, which
/// libgit2 can't know: it reads one against the process's directory. A
/// caller that resolves the remote itself connects where it resolved it
/// to, while the output names the remote as configured or as given.
@Suite("Remote connection location")
struct RemoteConnectionTests {

    @discardableResult
    private func runGit(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-c", "user.name=Test", "-c", "user.email=test@example.com"] + args
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
        return outStr.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Failure: Error, CustomStringConvertible {
        let message: String
        init(_ m: String) { self.message = m }
        var description: String { message }
    }

    /// A directory holding `bare`, a bare repository with one commit on
    /// `main`, and `work`, a repository with that commit and no remotes.
    /// Neither is anywhere near the process's directory, so a relative
    /// remote libgit2 read against it would miss.
    private func makeFixture() throws -> (root: URL, bare: URL, work: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteConnectionTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let bare = root.appendingPathComponent("bare"), work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try runGit(["init", "-q", "-b", "main", work.path], in: root)
        try runGit(["commit", "-q", "--allow-empty", "-m", "one"], in: work)
        try runGit(["clone", "-q", "--bare", work.path, bare.path], in: root)
        return (root, bare, work)
    }

    private func fetchHead(of work: URL) throws -> String {
        try String(contentsOf: work.appendingPathComponent(".git/FETCH_HEAD"), encoding: .utf8)
    }

    @Test("a configured relative remote fetches from the given location, shown as configured")
    func configuredRelativeRemoteFetches() throws {
        let (root, bare, work) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try runGit(["remote", "add", "local", "../bare"], in: work)
        let head = try runGit(["rev-parse", "HEAD"], in: work)

        let log = ConnectionLog()
        try Repository.open(at: work).fetch(
            remote: "local", refspecs: [], connectingTo: bare.path, progress: { log.append($0) })

        #expect(log.text == "From ../bare\n * [new branch]      main       -> local/main\n")
        #expect(try runGit(["rev-parse", "refs/remotes/local/main"], in: work) == head)
        #expect(try fetchHead(of: work) == "\(head)\tnot-for-merge\tbranch 'main' of ../bare\n")
    }

    @Test("a typed path fetches from the given location, shown as typed")
    func typedPathFetches() throws {
        let (root, bare, work) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let head = try runGit(["rev-parse", "HEAD"], in: work)

        let log = ConnectionLog()
        try Repository.open(at: work).fetch(
            remote: "../bare/", refspecs: ["main"], connectingTo: bare.path + "/",
            progress: { log.append($0) })

        // As git shows it: without the trailing slash.
        #expect(log.text == "From ../bare\n * branch            main       -> FETCH_HEAD\n")
        #expect(try fetchHead(of: work) == "\(head)\t\tbranch 'main' of ../bare\n")
    }

    @Test("the connection goes to the given location, not the configured URL")
    func connectsOnlyToTheLocation() throws {
        let (root, bare, work) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        // Configured somewhere that doesn't exist: the location wins…
        try runGit(["remote", "add", "local", "../nowhere"], in: work)
        try Repository.open(at: work).fetch(
            remote: "local", refspecs: [], connectingTo: bare.path, progress: { _ in })
        // …and a location that doesn't exist fails, configured URL or not.
        try runGit(["remote", "set-url", "local", bare.path], in: work)
        #expect(throws: (any Error).self) {
            try Repository.open(at: work).fetch(
                remote: "local", refspecs: [],
                connectingTo: root.appendingPathComponent("nowhere").path, progress: { _ in })
        }
        #expect(throws: (any Error).self) {
            try Repository.open(at: work).push(
                remote: "local", refspecs: ["main"], setUpstream: false,
                connectingTo: root.appendingPathComponent("nowhere").path, progress: { _ in })
        }
    }

    @Test("a typed path pushes to the given location, shown as typed, and records it as typed")
    func typedPathPushes() throws {
        let (root, bare, work) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try runGit(["rev-parse", "--short", "HEAD"], in: work)
        try runGit(["commit", "-q", "--allow-empty", "-m", "two"], in: work)
        let new = try runGit(["rev-parse", "--short", "HEAD"], in: work)

        let log = ConnectionLog()
        try Repository.open(at: work).push(
            remote: "../bare", refspecs: ["main"], setUpstream: true,
            connectingTo: bare.path, progress: { log.append($0) })

        #expect(log.text == "To ../bare\n   \(old)..\(new)  main -> main\n")
        #expect(try runGit(["rev-parse", "--short", "main"], in: bare) == new)
        #expect(try runGit(["config", "branch.main.remote"], in: work) == "../bare")
    }

    @Test("a configured push URL is replaced by the location, and shown as configured")
    func configuredPushURLIsReplaced() throws {
        let (root, bare, work) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try runGit(["remote", "add", "local", "../nowhere"], in: work)
        try runGit(["remote", "set-url", "--push", "local", "../bare"], in: work)
        try runGit(["commit", "-q", "--allow-empty", "-m", "two"], in: work)
        let new = try runGit(["rev-parse", "HEAD"], in: work)

        let log = ConnectionLog()
        try Repository.open(at: work).push(
            remote: "local", refspecs: ["main"], setUpstream: true,
            connectingTo: bare.path, progress: { log.append($0) })

        #expect(log.text.hasPrefix("To ../bare\n"))
        #expect(try runGit(["rev-parse", "main"], in: bare) == new)
        // The remote keeps its name for tracking refs and the upstream.
        #expect(try runGit(["rev-parse", "refs/remotes/local/main"], in: work) == new)
        #expect(try runGit(["config", "branch.main.remote"], in: work) == "local")
    }

    @Test("refused and rejected pushes name the remote as typed")
    func errorsNameTheRemoteAsTyped() throws {
        let (root, bare, work) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect {
            try Repository.open(at: work).push(
                remote: "../bare", refspecs: ["nothing"], setUpstream: false,
                connectingTo: bare.path, progress: { _ in })
        } throws: { error in
            (error as? PushRefusedError)?.url == "../bare"
        }

        // Work the remote has and this repository doesn't: fetch first.
        let other = root.appendingPathComponent("other")
        try runGit(["clone", "-q", bare.path, other.path], in: root)
        try runGit(["commit", "-q", "--allow-empty", "-m", "theirs"], in: other)
        try runGit(["push", "-q", "origin", "main"], in: other)
        try runGit(["commit", "-q", "--allow-empty", "-m", "mine"], in: work)
        #expect {
            try Repository.open(at: work).push(
                remote: "../bare", refspecs: ["main"], setUpstream: false,
                connectingTo: bare.path, progress: { _ in })
        } throws: { error in
            guard let rejected = error as? PushRejectedError else { return false }
            return rejected.url == "../bare"
                && rejected.localizedDescription.hasSuffix("failed to push some refs to '../bare'")
                && rejected.summary.hasPrefix("To ../bare\n")
        }
    }
}
#endif

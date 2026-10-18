// Integration tests for `git push --force-with-lease` semantics and for
// how forced updates are reported. Fixtures are built with the system
// `git` CLI (gated to non-Windows like the other integration suites);
// everything under test goes through `Repository`. Expected lines are
// git 2.54's for the same pushes.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

/// Collects progress text; the sink is `@Sendable`.
private final class LeaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    func append(_ text: String) { lock.lock(); buffer += text; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return buffer }
}

@Suite("Push leases")
struct PushLeaseTests {

    private func tmp(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PushLeaseTests-\(label)-\(UUID().uuidString)")
    }

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

    /// A bare remote with `main` and `dev` at one commit and tag `v1`,
    /// `main` one commit further; `mine` clones it with `dev` checked out
    /// too, and `theirs` pushes behind its back.
    private func makeRemoteAndClones() throws -> (remote: URL, mine: URL, theirs: URL) {
        let theirs = tmp("theirs")
        let remote = tmp("remote").appendingPathExtension("git")
        let mine = tmp("mine")
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        try runGit(["init", "-q", "-b", "main"], in: theirs)
        try runGit(["commit", "-q", "--allow-empty", "-m", "one"], in: theirs)
        try runGit(["tag", "v1"], in: theirs)
        try runGit(["branch", "dev"], in: theirs)
        try runGit(["commit", "-q", "--allow-empty", "-m", "two"], in: theirs)
        try runGit(["clone", "-q", "--bare", theirs.path, remote.path], in: theirs)
        try runGit(["remote", "add", "origin", remote.path], in: theirs)
        try runGit(["fetch", "-q", "origin"], in: theirs)
        try runGit(["clone", "-q", remote.path, mine.path], in: theirs)
        try runGit(["branch", "-q", "dev", "origin/dev"], in: mine)
        return (remote, mine, theirs)
    }

    /// `theirs` moves `main` and `dev` on; `mine` rewrites `main`.
    private func diverge(mine: URL, theirs: URL) throws {
        try runGit(["commit", "-q", "--allow-empty", "-m", "three"], in: theirs)
        try runGit(["push", "-q", "origin", "main", "HEAD:dev"], in: theirs)
        try runGit(["reset", "-q", "--hard", "HEAD~1"], in: mine)
        try runGit(["commit", "-q", "--allow-empty", "-m", "mine"], in: mine)
    }

    private func push(
        _ repo: URL, _ refspecs: [String], leases: PushLeases
    ) throws -> (output: String, error: PushRejectedError?) {
        let log = LeaseLog()
        do {
            try Repository.open(at: repo).push(
                remote: "origin", refspecs: refspecs, setUpstream: false, leases: leases,
                progress: { log.append($0) })
            return (log.text, nil)
        } catch let error as PushRejectedError {
            return (log.text, error)
        }
    }

    private func short(_ rev: String, in repo: URL) throws -> String {
        try runGit(["rev-parse", "--short", rev], in: repo)
    }

    @Test("a lease the remote still matches forces the update")
    func leaseHolds() throws {
        let (remote, mine, theirs) = try makeRemoteAndClones()
        defer { [remote, mine, theirs].forEach { try? FileManager.default.removeItem(at: $0) } }
        try runGit(["reset", "-q", "--hard", "HEAD~1"], in: mine)
        try runGit(["commit", "-q", "--allow-empty", "-m", "mine"], in: mine)
        let old = try short("origin/main", in: mine), new = try short("main", in: mine)

        let (output, error) = try push(mine, ["main"], leases: PushLeases(trackingForRest: true))
        #expect(error == nil)
        #expect(output.hasSuffix(" + \(old)...\(new) main -> main (forced update)\n"))
        #expect(try runGit(["rev-parse", "main"], in: remote) == runGit(["rev-parse", "main"], in: mine))
    }

    @Test("a lease the remote no longer matches is refused as stale info")
    func staleLease() throws {
        let (remote, mine, theirs) = try makeRemoteAndClones()
        defer { [remote, mine, theirs].forEach { try? FileManager.default.removeItem(at: $0) } }
        try diverge(mine: mine, theirs: theirs)
        let before = try runGit(["rev-parse", "main"], in: remote)

        for leases in [PushLeases(trackingForRest: true),
                       PushLeases([.init(ref: "main", expectation: .tracking)]),
                       PushLeases([.init(ref: "main",
                                         expectation: .object(try runGit(["rev-parse", "HEAD"], in: mine)))]),
                       PushLeases([.init(ref: "main", expectation: .absent)])] {
            let (output, error) = try push(mine, ["main"], leases: leases)
            #expect(output == "To \(remote.path)\n ! [rejected]        main -> main (stale info)\n")
            #expect(error?.rejections == [.init(remoteRef: "refs/heads/main", reason: .stale)])
        }
        #expect(try runGit(["rev-parse", "main"], in: remote) == before)
    }

    @Test("--force overrides a lease, and a ref no lease covers isn't forced")
    func forceAndUncovered() throws {
        let (remote, mine, theirs) = try makeRemoteAndClones()
        defer { [remote, mine, theirs].forEach { try? FileManager.default.removeItem(at: $0) } }
        try diverge(mine: mine, theirs: theirs)

        let uncovered = try push(mine, ["main"], leases: PushLeases([.init(ref: "dev", expectation: .tracking)]))
        #expect(uncovered.error?.rejections == [.init(remoteRef: "refs/heads/main", reason: .fetchFirst)])

        let old = try short("main", in: theirs), new = try short("main", in: mine)
        let forced = try push(mine, ["+main"], leases: PushLeases(trackingForRest: true))
        #expect(forced.error == nil)
        #expect(forced.output.hasSuffix(" + \(old)...\(new) main -> main (forced update)\n"))
    }

    @Test("each ref of a push settles by its own lease")
    func mixedLeases() throws {
        let (remote, mine, theirs) = try makeRemoteAndClones()
        defer { [remote, mine, theirs].forEach { try? FileManager.default.removeItem(at: $0) } }
        try diverge(mine: mine, theirs: theirs)
        try runGit(["branch", "-f", "dev", "main"], in: mine)
        let theirDev = try runGit(["rev-parse", "dev"], in: remote)
        let old = try short("dev", in: remote), new = try short("dev", in: mine)

        let (output, error) = try push(
            mine, ["main", "dev"],
            leases: PushLeases([.init(ref: "main", expectation: .tracking),
                                .init(ref: "dev", expectation: .object(theirDev))]))
        #expect(output == """
            To \(remote.path)
             + \(old)...\(new) dev -> dev (forced update)
             ! [rejected]        main -> main (stale info)

            """)
        #expect(error?.rejections == [.init(remoteRef: "refs/heads/main", reason: .stale)])
        #expect(error?.pushed == ["+refs/heads/dev:refs/heads/dev"])
    }

    @Test("a stale deletion is shown as git shows it")
    func staleDeletion() throws {
        let (remote, mine, theirs) = try makeRemoteAndClones()
        defer { [remote, mine, theirs].forEach { try? FileManager.default.removeItem(at: $0) } }
        try diverge(mine: mine, theirs: theirs)
        let (output, error) = try push(mine, [":dev"], leases: PushLeases(trackingForRest: true))
        #expect(output == "To \(remote.path)\n ! [rejected]        (delete) -> dev (stale info)\n")
        #expect(error?.rejections == [.init(remoteRef: "refs/heads/dev", reason: .stale)])
    }

    @Test("a tag has no remote-tracking ref: its lease expects it absent")
    func tagLease() throws {
        let (remote, mine, theirs) = try makeRemoteAndClones()
        defer { [remote, mine, theirs].forEach { try? FileManager.default.removeItem(at: $0) } }
        try runGit(["tag", "-f", "v1", "main"], in: mine)
        let stale = try push(mine, ["v1"], leases: PushLeases(trackingForRest: true))
        #expect(stale.error?.rejections == [.init(remoteRef: "refs/tags/v1", reason: .stale)])

        let old = try short("v1", in: theirs), new = try short("v1", in: mine)
        let expected = try push(
            mine, ["v1"],
            leases: PushLeases([.init(ref: "v1", expectation: .object(try runGit(["rev-parse", "v1"], in: theirs)))]))
        #expect(expected.error == nil)
        #expect(expected.output.hasSuffix(" + \(old)...\(new) v1 -> v1 (forced update)\n"))
    }

    @Test("a forced push lists its updates in the remote's ref order")
    func forcedOrder() throws {
        let (remote, mine, theirs) = try makeRemoteAndClones()
        defer { [remote, mine, theirs].forEach { try? FileManager.default.removeItem(at: $0) } }
        try runGit(["reset", "-q", "--hard", "HEAD~1"], in: mine)
        try runGit(["commit", "-q", "--allow-empty", "-m", "mine"], in: mine)
        let main = try short("origin/main", in: mine), dev = try short("origin/dev", in: mine)
        let new = try short("main", in: mine)
        let log = LeaseLog()
        try Repository.open(at: mine).push(
            remote: "origin", refspecs: ["+main:main", "main:dev"], setUpstream: false,
            progress: { log.append($0) })
        #expect(log.text == """
            To \(remote.path)
               \(dev)..\(new)  main -> dev
             + \(main)...\(new) main -> main (forced update)

            """)
    }

    @Test("a forced tag that moves forward is still a forced update")
    func forcedTagMove() throws {
        let (remote, mine, theirs) = try makeRemoteAndClones()
        defer { [remote, mine, theirs].forEach { try? FileManager.default.removeItem(at: $0) } }
        try runGit(["tag", "-f", "v1", "main"], in: mine)
        let old = try short("v1", in: theirs), new = try short("v1", in: mine)
        let log = LeaseLog()
        try Repository.open(at: mine).push(
            remote: "origin", refspecs: ["+v1"], setUpstream: false, progress: { log.append($0) })
        #expect(log.text.hasSuffix(" + \(old)...\(new) v1 -> v1 (forced update)\n"))
    }

    @Test("lease matching follows git's spelling of refs")
    func leaseRefMatching() {
        let leases = PushLeases([.init(ref: "main", expectation: .absent)])
        #expect(leases.expectation(for: "refs/heads/main") == .absent)
        #expect(leases.expectation(for: "refs/tags/main") == .absent)
        #expect(leases.expectation(for: "refs/heads/mainline") == nil)
        #expect(PushLeases(trackingForRest: true).expectation(for: "refs/heads/x") == .tracking)
    }
}
#endif

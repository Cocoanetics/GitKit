// Integration tests for `push(…, beforeSending:)`, the updates git
// hands its pre-push hook. Fixtures are built with the system `git` CLI
// (gated to non-Windows for the same reasons as the other integration
// suites); everything under test goes through `Repository`.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

/// Collects what the callback saw; `push` calls it synchronously.
private final class UpdateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[PushUpdate]] = []
    private var lines: [String] = []
    func append(_ updates: [PushUpdate]) { lock.lock(); calls.append(updates); lock.unlock() }
    func write(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [[PushUpdate]] { lock.lock(); defer { lock.unlock() }; return calls }
    var output: String { lock.lock(); defer { lock.unlock() }; return lines.joined() }
}

@Suite("Push updates before sending")
struct PushUpdateTests {

    private let fixtures = TemporaryRepositories()

    private func tmp(_ label: String) -> URL {
        fixtures.url("PushUpdateTests-\(label)-\(UUID().uuidString)")
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
        #expect(p.terminationStatus == 0, "git \(args.joined(separator: " ")) failed")
        return outStr.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Refused: Error {}

    /// A bare remote with `main` and `old`, both at one commit, and a
    /// clone of it.
    private func makeRemoteAndClone() throws -> (remote: URL, work: URL) {
        let seed = tmp("seed")
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        try runGit(["init", "-q", "-b", "main"], in: seed)
        try runGit(["commit", "-q", "--allow-empty", "-m", "one"], in: seed)
        try runGit(["branch", "old"], in: seed)
        try runGit(["branch", "same"], in: seed)
        let remote = tmp("remote").appendingPathExtension("git")
        try runGit(["clone", "-q", "--bare", seed.path, remote.path], in: seed)
        let work = tmp("work")
        try runGit(["clone", "-q", remote.path, work.path], in: seed)
        try? FileManager.default.removeItem(at: seed)
        return (remote, work)
    }

    @Test("updates, a new ref and a deletion, as git's pre-push hook gets them")
    func updates() throws {
        defer { fixtures.removeAll() }
        let (remote, work) = try makeRemoteAndClone()
        let before = try runGit(["rev-parse", "main"], in: remote)
        try runGit(["commit", "-q", "--allow-empty", "-m", "two"], in: work)
        let after = try runGit(["rev-parse", "HEAD"], in: work)
        let log = UpdateLog()
        try Repository.open(at: work).push(
            remote: "origin",
            refspecs: ["main", "main:refs/heads/new", ":refs/heads/old", "\(before):refs/heads/same"],
            setUpstream: false, progress: { _ in }, beforeSending: { log.append($0) })
        let null = PushUpdate.nullOID
        // The remote's refs as it advertised them, then the new one; the
        // ref already where it is pushed to is left out.
        #expect(log.all == [[
            PushUpdate(localRef: "refs/heads/main", localOID: after,
                       remoteRef: "refs/heads/main", remoteOID: before),
            PushUpdate(localRef: "(delete)", localOID: null,
                       remoteRef: "refs/heads/old", remoteOID: before),
            PushUpdate(localRef: "refs/heads/main", localOID: after,
                       remoteRef: "refs/heads/new", remoteOID: null)
        ]])
        #expect(try runGit(["rev-parse", "main"], in: remote) == after)
    }

    @Test("a refused update is not among them")
    func rejected() throws {
        defer { fixtures.removeAll() }
        let (remote, work) = try makeRemoteAndClone()
        let before = try runGit(["rev-parse", "main"], in: remote)
        try runGit(["commit", "-q", "--allow-empty", "-m", "two"], in: work)
        try runGit(["checkout", "-q", "-b", "side", "main~1"], in: work)
        try runGit(["commit", "-q", "--allow-empty", "-m", "side"], in: work)
        let side = try runGit(["rev-parse", "HEAD"], in: work)
        // The remote's `main` moves on to `two`, which `side` would drop;
        // `old` is still where `side` starts.
        try runGit(["push", "-q", "origin", "main"], in: work)
        let log = UpdateLog()
        #expect(throws: PushRejectedError.self) {
            try Repository.open(at: work).push(
                remote: "origin", refspecs: ["side:refs/heads/main", "side:refs/heads/old"],
                setUpstream: false, progress: { _ in }, beforeSending: { log.append($0) })
        }
        #expect(log.all == [[
            PushUpdate(localRef: "refs/heads/side", localOID: side,
                       remoteRef: "refs/heads/old", remoteOID: before)
        ]])
    }

    @Test("a callback that throws keeps the push from sending anything")
    func refused() throws {
        defer { fixtures.removeAll() }
        let (remote, work) = try makeRemoteAndClone()
        let before = try runGit(["rev-parse", "main"], in: remote)
        try runGit(["commit", "-q", "--allow-empty", "-m", "two"], in: work)
        #expect(throws: Refused.self) {
            try Repository.open(at: work).push(
                remote: "origin", refspecs: ["main"], setUpstream: false,
                progress: { _ in }, beforeSending: { _ in throw Refused() })
        }
        #expect(try runGit(["rev-parse", "main"], in: remote) == before)
    }

    @Test("everything up to date: no updates")
    func nothingToSend() throws {
        defer { fixtures.removeAll() }
        let (_, work) = try makeRemoteAndClone()
        let log = UpdateLog()
        try Repository.open(at: work).push(
            remote: "origin", refspecs: ["main"], setUpstream: false,
            progress: { _ in }, beforeSending: { log.append($0) })
        // git runs its pre-push hook here too, with nothing on stdin.
        #expect(log.all == [[]])
    }

    @Test("source changes during the callback do not change the send",
          arguments: [false, true], [(false, false), (false, true), (true, false), (true, true)])
    func frozenSources(useLeases: Bool, sourceChange: (Bool, Bool)) throws {
        defer { fixtures.removeAll() }
        let (upToDate, deleteSource) = sourceChange
        let (remote, work) = try makeRemoteAndClone()
        let before = try runGit(["rev-parse", "main"], in: remote)
        try runGit(["commit", "-q", "--allow-empty", "-m", "two"], in: work)
        let announced = upToDate ? before : try runGit(["rev-parse", "main"], in: work)
        try runGit(["commit", "-q", "--allow-empty", "-m", "three"], in: work)
        let later = try runGit(["rev-parse", "main"], in: work)
        try runGit(["update-ref", "refs/heads/main", announced], in: work)
        let log = UpdateLog()
        let callback: ([PushUpdate]) throws -> Void = { updates in
            log.append(updates)
            if deleteSource {
                try runGit(["update-ref", "-d", "refs/heads/main"], in: work)
            } else {
                try runGit(["update-ref", "refs/heads/main", later], in: work)
            }
        }
        let repository = try Repository.open(at: work)
        let pushed: [String]
        // Pattern expansion also has to keep ref names in the summary
        // even though libgit2 receives object IDs as its sources.
        let refspecs = ["refs/heads/*:refs/heads/*"]
        if useLeases {
            pushed = try repository.push(
                remote: "origin", refspecs: refspecs, setUpstream: false,
                leases: PushLeases(trackingForRest: true),
                progress: { log.write($0) }, beforeSending: callback)
        } else {
            pushed = try repository.push(
                remote: "origin", refspecs: refspecs, setUpstream: false,
                progress: { log.write($0) }, beforeSending: callback)
        }
        #expect(log.all == [upToDate ? [] : [
            PushUpdate(localRef: "refs/heads/main", localOID: announced,
                       remoteRef: "refs/heads/main", remoteOID: before)
        ]])
        #expect(try runGit(["rev-parse", "main"], in: remote) == announced)
        #expect(pushed.map { String($0.drop(while: { $0 == "+" })) }
                == ["refs/heads/main:refs/heads/main"])
        #expect(log.output.contains(upToDate ? "Everything up-to-date" : "main -> main"))
    }

    @Test("the leases overload reports the updates the lease lets through")
    func leased() throws {
        defer { fixtures.removeAll() }
        let (remote, work) = try makeRemoteAndClone()
        let before = try runGit(["rev-parse", "main"], in: remote)
        try runGit(["commit", "-q", "--amend", "--allow-empty", "-m", "rewritten"], in: work)
        let after = try runGit(["rev-parse", "HEAD"], in: work)
        let log = UpdateLog()
        try Repository.open(at: work).push(
            remote: "origin", refspecs: ["main"], setUpstream: false,
            leases: PushLeases(trackingForRest: true),
            progress: { _ in }, beforeSending: { log.append($0) })
        #expect(log.all == [[
            PushUpdate(localRef: "refs/heads/main", localOID: after,
                       remoteRef: "refs/heads/main", remoteOID: before)
        ]])
    }
}
#endif

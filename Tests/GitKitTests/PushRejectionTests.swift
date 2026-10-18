// Integration tests for pushes git refuses in part. Fixtures are built
// with the system `git` CLI (gated to non-Windows for the same reasons
// as the other integration suites); everything under test goes through
// `Repository`.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

/// Collects progress text; the sink is `@Sendable`.
private final class PushLog: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    func append(_ text: String) { lock.lock(); buffer += text; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return buffer }
}

/// A push git would refuse for some refs pushes the others, prints a
/// ` ! [rejected]` line for each refused one and throws
/// ``PushRejectedError``, where libgit2 alone fails the whole push.
@Suite("Push rejections")
struct PushRejectionTests {

    private func tmp(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PushRejectionTests-\(label)-\(UUID().uuidString)")
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

    /// A bare remote with one commit on `main`, and two clones of it.
    private func makeRemoteAndClones() throws -> (remote: URL, mine: URL, theirs: URL) {
        let seed = tmp("seed")
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        try runGit(["init", "-q", "-b", "main"], in: seed)
        try runGit(["commit", "-q", "--allow-empty", "-m", "one"], in: seed)
        let remote = tmp("remote").appendingPathExtension("git")
        try runGit(["clone", "-q", "--bare", seed.path, remote.path], in: seed)
        let mine = tmp("mine"), theirs = tmp("theirs")
        try runGit(["clone", "-q", remote.path, mine.path], in: seed)
        try runGit(["clone", "-q", remote.path, theirs.path], in: seed)
        try? FileManager.default.removeItem(at: seed)
        return (remote, mine, theirs)
    }

    private func push(
        _ repo: URL, _ refspecs: [String], setUpstream: Bool = false
    ) throws -> (output: String, error: PushRejectedError?) {
        let log = PushLog()
        do {
            try Repository.open(at: repo).push(
                remote: "origin", refspecs: refspecs, setUpstream: setUpstream,
                progress: { log.append($0) })
            return (log.text, nil)
        } catch let error as PushRejectedError {
            return (log.text, error)
        }
    }

    @Test("work the remote has and this repository doesn't: fetch first")
    func fetchFirst() throws {
        let (remote, mine, theirs) = try makeRemoteAndClones()
        defer { [remote, mine, theirs].forEach { try? FileManager.default.removeItem(at: $0) } }
        try runGit(["commit", "-q", "--allow-empty", "-m", "theirs"], in: theirs)
        try runGit(["push", "-q", "origin", "main"], in: theirs)
        try runGit(["commit", "-q", "--allow-empty", "-m", "mine"], in: mine)

        let (output, error) = try push(mine, ["main"])
        let url = try runGit(["config", "remote.origin.url"], in: mine)
        #expect(output == "To \(url)\n ! [rejected]        main -> main (fetch first)\n")
        #expect(error == PushRejectedError(
            url: url,
            rejections: [.init(remoteRef: "refs/heads/main", reason: .fetchFirst)],
            pushed: [], summary: output))
        #expect(error?.localizedDescription.hasPrefix("failed to push some refs to '") == true)
        #expect(try runGit(["rev-parse", "main"], in: remote)
                == runGit(["rev-parse", "main"], in: theirs))
    }

    @Test("a known remote tip the push would drop: non-fast-forward")
    func nonFastForward() throws {
        let (remote, mine, theirs) = try makeRemoteAndClones()
        defer { [remote, mine, theirs].forEach { try? FileManager.default.removeItem(at: $0) } }
        try runGit(["commit", "-q", "--allow-empty", "-m", "theirs"], in: theirs)
        try runGit(["push", "-q", "origin", "main"], in: theirs)
        try runGit(["fetch", "-q"], in: mine)
        try runGit(["commit", "-q", "--allow-empty", "-m", "mine"], in: mine)

        let (output, error) = try push(mine, ["main"])
        #expect(output.hasSuffix(" ! [rejected]        main -> main (non-fast-forward)\n"))
        #expect(error?.rejections == [.init(remoteRef: "refs/heads/main", reason: .nonFastForward)])

        // Forced, it goes.
        let forced = try push(mine, ["+main"])
        #expect(forced.error == nil)
        #expect(try runGit(["rev-parse", "main"], in: remote)
                == runGit(["rev-parse", "main"], in: mine))
    }

    @Test("a tag the remote has: already exists")
    func tagAlreadyExists() throws {
        let (remote, mine, theirs) = try makeRemoteAndClones()
        defer { [remote, mine, theirs].forEach { try? FileManager.default.removeItem(at: $0) } }
        try runGit(["tag", "v1"], in: theirs)
        try runGit(["push", "-q", "origin", "v1"], in: theirs)
        try runGit(["commit", "-q", "--allow-empty", "-m", "mine"], in: mine)
        try runGit(["fetch", "-q", "origin", "refs/heads/main"], in: mine)
        try runGit(["tag", "v1"], in: mine)

        let (output, error) = try push(mine, ["v1"])
        #expect(output.hasSuffix(" ! [rejected]        v1 -> v1 (already exists)\n"))
        #expect(error?.rejections == [.init(remoteRef: "refs/tags/v1", reason: .alreadyExists)])
    }

    @Test("the refs git accepts still go, and get their upstream")
    func partialPush() throws {
        let (remote, mine, theirs) = try makeRemoteAndClones()
        defer { [remote, mine, theirs].forEach { try? FileManager.default.removeItem(at: $0) } }
        try runGit(["commit", "-q", "--allow-empty", "-m", "theirs"], in: theirs)
        try runGit(["push", "-q", "origin", "main"], in: theirs)
        try runGit(["commit", "-q", "--allow-empty", "-m", "mine"], in: mine)
        try runGit(["branch", "topic"], in: mine)

        let (output, error) = try push(mine, ["main", "topic"], setUpstream: true)
        #expect(output.contains(" * [new branch]      topic -> topic\n"))
        #expect(output.hasSuffix(" ! [rejected]        main -> main (fetch first)\n"))
        #expect(error?.pushed == ["refs/heads/topic:refs/heads/topic"])
        #expect(try runGit(["rev-parse", "topic"], in: remote)
                == runGit(["rev-parse", "topic"], in: mine))
        #expect(try runGit(["config", "branch.topic.merge"], in: mine) == "refs/heads/topic")
    }
}
#endif

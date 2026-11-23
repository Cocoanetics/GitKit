// Regression for a configured remote whose `pushurl` is a local path:
// `git push origin` goes to the push URL, but libgit2's local transport
// opens the remote's URL unless GitKit points it elsewhere.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

@Suite("Push to a configured push URL")
struct PushURLTests {
    private let fixtures = TemporaryRepositories()

    private func tmp(_ label: String) -> URL {
        fixtures.url("PushURLTests-\(label)-\(UUID().uuidString)")
    }

    @discardableResult
    private func runGit(_ args: [String], in dir: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-c", "user.name=Test", "-c", "user.email=test@example.com"] + args
        process.currentDirectoryURL = dir
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: (try? out.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
        if process.terminationStatus != 0 {
            let error = String(decoding: (try? err.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
            throw Failure("git \(args.joined(separator: " ")) failed: \(error)")
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Failure: Error, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { message }
    }

    /// A clone of bare `origin` whose `remote.origin.pushurl` is bare
    /// `mirror`, with tag `v9` on its only commit.
    private func makeCloneWithPushURL() throws -> (clone: URL, origin: URL, mirror: URL) {
        let seed = tmp("seed")
        let origin = tmp("origin").appendingPathExtension("git")
        let mirror = tmp("mirror").appendingPathExtension("git")
        let clone = tmp("clone")
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        try runGit(["init", "-q", "-b", "main"], in: seed)
        try runGit(["commit", "-q", "--allow-empty", "-m", "one"], in: seed)
        try runGit(["clone", "-q", "--bare", seed.path, origin.path], in: seed)
        try runGit(["clone", "-q", "--bare", seed.path, mirror.path], in: seed)
        try runGit(["clone", "-q", origin.path, clone.path], in: seed)
        try runGit(["config", "remote.origin.pushurl", mirror.path], in: clone)
        try runGit(["tag", "v9"], in: clone)
        return (clone, origin, mirror)
    }

    private func refs(_ repo: URL) throws -> String {
        try runGit(["for-each-ref", "--format=%(refname)"], in: repo)
    }

    @Test("push sends to the configured local push URL, not the URL")
    func pushGoesToLocalPushURL() throws {
        defer { fixtures.removeAll() }
        let (clone, origin, mirror) = try makeCloneWithPushURL()

        try Repository.open(at: clone).push(
            remote: "origin", refspec: "refs/tags/v9", setUpstream: false,
            progress: { _ in })

        #expect(try refs(mirror).contains("refs/tags/v9"))
        #expect(try !refs(origin).contains("refs/tags/v9"))
    }

    @Test("a leased push sends to the configured local push URL, not the URL")
    func leasedPushGoesToLocalPushURL() throws {
        defer { fixtures.removeAll() }
        let (clone, origin, mirror) = try makeCloneWithPushURL()
        try runGit(["branch", "feature"], in: clone)

        try Repository.open(at: clone).push(
            remote: "origin", refspec: "feature", setUpstream: false,
            forceWithLease: .tracking, progress: { _ in })

        #expect(try refs(mirror).contains("refs/heads/feature"))
        #expect(try !refs(origin).contains("refs/heads/feature"))
    }
}
#endif

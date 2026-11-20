// Regression for a checkout whose `remote.origin.fetch` lists single
// branches. `git push -u` still records the upstream; `git_branch_set_upstream`
// does not.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

@Suite("Push upstream without a matching fetch refspec")
struct PushUpstreamRefspecTests {
    private let fixtures = TemporaryRepositories()

    private func makeFixtureRepo() throws -> URL {
        let dir = try fixtures.directory("PushUpstream-\(UUID().uuidString)")
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "test@example.com"], in: dir)
        try runGit(["config", "user.name", "Test"], in: dir)
        try Data("hi\n".utf8).write(to: dir.appendingPathComponent("README.md"))
        try runGit(["add", "README.md"], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)
        return dir
    }

    private func makeBareOrigin() throws -> URL {
        let dir = try fixtures.directory("PushUpstream-origin-\(UUID().uuidString).git")
        try runGit(["init", "--bare"], in: dir)
        return dir
    }

    @discardableResult
    private func runGit(_ args: [String], in dir: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
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
        return output
    }

    private struct Failure: Error, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { message }
    }

    /// The remote-tracking ref exists, but no fetch refspec maps it, so
    /// `git_branch_set_upstream` fails with "could not determine remote".
    @Test("push setUpstream records the upstream without a matching fetch refspec")
    func pushSetUpstreamWithoutMatchingFetchRefspec() throws {
        try assertPushSetUpstream(trackingRefExists: true)
    }

    /// No tracking ref exists yet. libgit2 then says "cannot set upstream".
    @Test("push setUpstream records the upstream when no tracking ref exists")
    func pushSetUpstreamWhenNoTrackingRefExists() throws {
        try assertPushSetUpstream(trackingRefExists: false)
    }

    /// Under `core.precomposeunicode` an NFD refspec finds the NFC branch;
    /// the config keys must use the stored NFC name `@{upstream}` reads.
    @Test("push setUpstream keys config by the stored branch name")
    func pushSetUpstreamUsesStoredBranchName() throws {
        defer { fixtures.removeAll() }
        let dir = try makeFixtureRepo()
        let origin = try makeBareOrigin()
        let nfc = "\u{00E9}"
        let nfd = "e\u{0301}"

        try runGit(["config", "core.precomposeunicode", "true"], in: dir)
        try runGit(["checkout", "-b", nfc], in: dir)
        let repo = try Repository.open(at: dir)
        try repo.addRemote(name: "origin", url: origin)

        try repo.push(remote: "origin", refspec: nfd, setUpstream: true, progress: { _ in })

        let configured = try runGit(["config", "--get-regexp", "^branch\\."], in: dir)
        #expect(configured.utf8.elementsEqual(
            "branch.\(nfc).remote origin\nbranch.\(nfc).merge refs/heads/\(nfc)\n".utf8))
        #expect(try repo.upstreamBranch(of: nfc) != nil)
    }

    private func assertPushSetUpstream(trackingRefExists: Bool) throws {
        defer { fixtures.removeAll() }
        let dir = try makeFixtureRepo()
        let origin = try makeBareOrigin()
        let branch = "release/version-1.3.7"

        try runGit(["checkout", "-b", branch], in: dir)
        let repo = try Repository.open(at: dir)
        try repo.addRemote(name: "origin", url: origin)
        try runGit(["config", "--unset-all", "remote.origin.fetch"], in: dir)
        try runGit(
            ["config", "--add", "remote.origin.fetch", "+refs/heads/main:refs/remotes/origin/main"],
            in: dir)
        try runGit(
            ["config", "--add", "remote.origin.fetch",
             "+refs/heads/agent/issue-49:refs/remotes/origin/agent/issue-49"],
            in: dir)
        if trackingRefExists {
            try runGit(["update-ref", "refs/remotes/origin/\(branch)", "HEAD"], in: dir)
        }

        try repo.push(remote: "origin", refspec: branch, setUpstream: true, progress: { _ in })

        let head = try runGit(["rev-parse", "HEAD"], in: dir)
        #expect(try runGit(["rev-parse", "refs/heads/\(branch)"], in: origin) == head)
        let remote = try runGit(["config", "branch.\(branch).remote"], in: dir)
        let merge = try runGit(["config", "branch.\(branch).merge"], in: dir)
        #expect(remote.trimmingCharacters(in: .whitespacesAndNewlines) == "origin")
        #expect(merge.trimmingCharacters(in: .whitespacesAndNewlines) == "refs/heads/\(branch)")
        let specs = try runGit(["config", "--get-all", "remote.origin.fetch"], in: dir)
        #expect(specs == "+refs/heads/main:refs/remotes/origin/main\n"
            + "+refs/heads/agent/issue-49:refs/remotes/origin/agent/issue-49\n")
    }
}
#endif

// Integration tests that fork the system `git` via `Process` for parity
// checks. Windows has no `/usr/bin/env`, and the swift-android-action's
// MSVC clang doesn't see a stable `git.exe` path either, so gate the
// whole suite to non-Windows. Apple/Linux still cover the integration
// surface.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

@Suite("Repository")
struct RepositoryTests {

    // Local-only round-trip — no network. We init a repo with the
    // command-line `git` binary (so we don't depend on libgit2's init
    // path in the test), then exercise the libgit2-backed reads.
    private func makeFixtureRepo(withCommit: Bool = true) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepositoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "test@example.com"], in: dir)
        try runGit(["config", "user.name", "Test"], in: dir)

        if withCommit {
            let readme = dir.appendingPathComponent("README.md")
            try Data("hi\n".utf8).write(to: readme)
            try runGit(["add", "README.md"], in: dir)
            try runGit(["commit", "-m", "init"], in: dir)
        }
        return dir
    }

    private func makeBareOrigin() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepositoryTests-origin-\(UUID().uuidString).git")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "--bare"], in: dir)
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

    @Test("currentBranch reports the HEAD shorthand")
    func currentBranch() throws {
        let dir = try makeFixtureRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        let repo = try Repository.open(at: dir)
        let branch = try repo.currentBranch()
        #expect(branch == "main")
    }

    @Test("currentBranch returns nil when HEAD is unborn")
    func currentBranchUnborn() throws {
        let dir = try makeFixtureRepo(withCommit: false)
        defer { try? FileManager.default.removeItem(at: dir) }

        let repo = try Repository.open(at: dir)
        let branch = try repo.currentBranch()
        #expect(branch == nil)
    }

    @Test("addRemote then remoteURL round-trips a URL")
    func addAndReadRemote() throws {
        let dir = try makeFixtureRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        let repo = try Repository.open(at: dir)
        let url = URL(string: "https://github.com/example/repo.git")!
        try repo.addRemote(name: "origin", url: url)

        let read = try repo.remoteURL(named: "origin")
        #expect(read?.absoluteString == url.absoluteString)
    }

    @Test("push accepts a short main branch refspec")
    func pushShortMainBranch() throws {
        let dir = try makeFixtureRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let origin = try makeBareOrigin()
        defer { try? FileManager.default.removeItem(at: origin) }

        let repo = try Repository.open(at: dir)
        try repo.addRemote(name: "origin", url: origin)
        try repo.push(remote: "origin", refspec: "main", setUpstream: false, progress: { _ in })

        let localSHA = try runGit(["rev-parse", "refs/heads/main"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteSHA = try runGit(["rev-parse", "refs/heads/main"], in: origin)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(remoteSHA == localSHA)
    }

    @Test("push accepts a short nested branch refspec")
    func pushShortNestedBranch() throws {
        let dir = try makeFixtureRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let origin = try makeBareOrigin()
        defer { try? FileManager.default.removeItem(at: origin) }

        try runGit(["checkout", "-b", "agent/issue-1"], in: dir)
        let repo = try Repository.open(at: dir)
        try repo.addRemote(name: "origin", url: origin)
        try repo.push(
            remote: "origin", refspec: "agent/issue-1",
            setUpstream: false, progress: { _ in })

        let localSHA = try runGit(["rev-parse", "refs/heads/agent/issue-1"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteSHA = try runGit(["rev-parse", "refs/heads/agent/issue-1"], in: origin)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(remoteSHA == localSHA)
    }

    @Test("push accepts a short nested branch refspec from a linked worktree")
    func pushShortNestedBranchFromWorktree() throws {
        let dir = try makeFixtureRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let origin = try makeBareOrigin()
        defer { try? FileManager.default.removeItem(at: origin) }
        let worktree = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepositoryTests-worktree-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: worktree) }

        let repo = try Repository.open(at: dir)
        try repo.addRemote(name: "origin", url: origin)
        try repo.worktreeAdd(path: worktree, branch: "agent/issue-2")

        let linkedRepo = try Repository.open(at: worktree)
        try linkedRepo.push(
            remote: "origin", refspec: "agent/issue-2",
            setUpstream: false, progress: { _ in })

        let localSHA = try runGit(["rev-parse", "refs/heads/agent/issue-2"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteSHA = try runGit(["rev-parse", "refs/heads/agent/issue-2"], in: origin)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(remoteSHA == localSHA)
    }

    @Test("remoteURL returns nil for a missing remote")
    func remoteURLMissing() throws {
        let dir = try makeFixtureRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        let repo = try Repository.open(at: dir)
        let read = try repo.remoteURL(named: "origin")
        #expect(read == nil)
    }

    @Test("upstreamBranch returns the abbreviated upstream ref")
    func upstreamBranch() throws {
        let dir = try makeFixtureRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Configure a fake upstream — no fetch / push, just config writes.
        // `git_branch_upstream_name` needs the remote to exist so it can
        // resolve the upstream against the fetch refspec.
        try runGit(["remote", "add", "origin", "https://example.invalid/repo.git"], in: dir)
        try runGit(["config", "branch.main.remote", "origin"], in: dir)
        try runGit(["config", "branch.main.merge", "refs/heads/main"], in: dir)
        try runGit(["update-ref", "refs/remotes/origin/main", "HEAD"], in: dir)

        let repo = try Repository.open(at: dir)
        let upstream = try repo.upstreamBranch(of: "main")
        #expect(upstream == "origin/main")
    }

    @Test("upstreamBranch returns nil when no upstream is set")
    func upstreamBranchNone() throws {
        let dir = try makeFixtureRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        let repo = try Repository.open(at: dir)
        let upstream = try repo.upstreamBranch(of: "main")
        #expect(upstream == nil)
    }
}
#endif

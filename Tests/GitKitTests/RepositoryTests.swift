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

    @Test("push accepts detached HEAD and retains fast-forward protection")
    func pushDetachedHEAD() throws {
        let dir = try makeFixtureRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let origin = try makeBareOrigin()
        defer { try? FileManager.default.removeItem(at: origin) }

        let headSHA = try runGit(["rev-parse", "HEAD"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let repo = try Repository.open(at: dir)
        try repo.addRemote(name: "origin", url: origin)
        try repo.checkout(ref: headSHA)
        #expect(try repo.currentBranch() == nil)
        try repo.push(
            remote: "origin", refspec: "HEAD:refs/heads/review-fixes",
            setUpstream: false, progress: { _ in })

        let pushedSHA = try runGit(["rev-parse", "refs/heads/review-fixes"], in: origin)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(pushedSHA == headSHA)

        try Data("advanced\n".utf8).write(to: dir.appendingPathComponent("README.md"))
        try runGit(["commit", "-am", "advance remote"], in: dir)
        try runGit(["push", "origin", "HEAD:refs/heads/review-fixes"], in: dir)
        let advancedSHA = try runGit(["rev-parse", "HEAD"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try repo.checkout(ref: headSHA)

        #expect(throws: Libgit2Error.self) {
            try repo.push(
                remote: "origin", refspec: "HEAD:refs/heads/review-fixes",
                setUpstream: false, progress: { _ in })
        }
        let protectedSHA = try runGit(["rev-parse", "refs/heads/review-fixes"], in: origin)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(protectedSHA == advancedSHA)
    }

    @Test("push accepts a short tag refspec")
    func pushShortTag() throws {
        let dir = try makeFixtureRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let origin = try makeBareOrigin()
        defer { try? FileManager.default.removeItem(at: origin) }

        try runGit(["tag", "release"], in: dir)
        let repo = try Repository.open(at: dir)
        try repo.addRemote(name: "origin", url: origin)
        try repo.push(remote: "origin", refspec: "release", setUpstream: false, progress: { _ in })

        let localSHA = try runGit(["rev-parse", "refs/tags/release"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteSHA = try runGit(["rev-parse", "refs/tags/release"], in: origin)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(remoteSHA == localSHA)
    }

    @Test("push rejects ambiguous branch and tag shorthand")
    func pushRejectsAmbiguousBranchAndTag() throws {
        let dir = try makeFixtureRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let origin = try makeBareOrigin()
        defer { try? FileManager.default.removeItem(at: origin) }

        try runGit(["branch", "release"], in: dir)
        try runGit(["tag", "release"], in: dir)
        let repo = try Repository.open(at: dir)
        try repo.addRemote(name: "origin", url: origin)

        do {
            try repo.push(remote: "origin", refspec: "release", setUpstream: false, progress: { _ in })
            Issue.record("expected ambiguous refspec error")
        } catch let error as Libgit2Error {
            #expect(error.message == "src refspec release matches more than one")
        } catch {
            Issue.record("expected Libgit2Error, got \(error)")
        }
    }

    @Test("push setUpstream tracks destination branch for renamed refspec")
    func pushSetUpstreamTracksDestinationBranch() throws {
        let dir = try makeFixtureRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let origin = try makeBareOrigin()
        defer { try? FileManager.default.removeItem(at: origin) }

        try runGit(["checkout", "-b", "local"], in: dir)
        let repo = try Repository.open(at: dir)
        try repo.addRemote(name: "origin", url: origin)
        try repo.push(
            remote: "origin", refspec: "local:remote",
            setUpstream: true, progress: { _ in })

        let upstreamRemote = try runGit(["config", "branch.local.remote"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let upstreamMerge = try runGit(["config", "branch.local.merge"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(upstreamRemote == "origin")
        #expect(upstreamMerge == "refs/heads/remote")
    }

    @Test("push forceWithLease rejects stale leases and accepts matching leases")
    func pushForceWithLease() throws {
        let dir = try makeFixtureRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let origin = try makeBareOrigin()
        defer { try? FileManager.default.removeItem(at: origin) }
        let other = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepositoryTests-other-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: other) }

        let repo = try Repository.open(at: dir)
        try repo.addRemote(name: "origin", url: origin)
        try repo.push(remote: "origin", refspec: "main", setUpstream: false, progress: { _ in })
        try runGit(["fetch", "origin", "main"], in: dir)

        let leaseSHA = try runGit(["rev-parse", "refs/remotes/origin/main"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        try Data("local\n".utf8).write(to: dir.appendingPathComponent("README.md"))
        try runGit(["commit", "-am", "local"], in: dir)
        let localSHA = try runGit(["rev-parse", "refs/heads/main"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        try runGit(["clone", "-b", "main", origin.path, other.path],
                   in: FileManager.default.temporaryDirectory)
        try runGit(["config", "user.email", "test@example.com"], in: other)
        try runGit(["config", "user.name", "Test"], in: other)
        try Data("remote\n".utf8).write(to: other.appendingPathComponent("README.md"))
        try runGit(["commit", "-am", "remote"], in: other)
        try runGit(["push", "origin", "main"], in: other)
        let advancedSHA = try runGit(["rev-parse", "refs/heads/main"], in: origin)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(advancedSHA != leaseSHA)

        let staleRepo = try Repository.open(at: dir)
        do {
            try staleRepo.push(
                remote: "origin", refspec: "main", setUpstream: false,
                forceWithLease: .tracking, progress: { _ in })
            Issue.record("expected stale force-with-lease push to fail")
        } catch let error as Libgit2Error {
            #expect(error.code == GIT_EMODIFIED.rawValue)
            #expect(error.message.contains("force-with-lease rejected refs/heads/main"))
        } catch {
            Issue.record("expected Libgit2Error, got \(error)")
        }

        let stillAdvancedSHA = try runGit(["rev-parse", "refs/heads/main"], in: origin)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(stillAdvancedSHA == advancedSHA)

        try staleRepo.push(
            remote: "origin", refspec: "main", setUpstream: false,
            forceWithLease: .expecting(advancedSHA), progress: { _ in })

        let finalRemoteSHA = try runGit(["rev-parse", "refs/heads/main"], in: origin)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(finalRemoteSHA == localSHA)

        try staleRepo.push(
            remote: "origin", refspec: "main", setUpstream: false,
            forceWithLease: .expecting(advancedSHA), progress: { _ in })
        try staleRepo.push(
            remote: "origin", refspec: "main", setUpstream: false,
            forceWithLease: .tracking, progress: { _ in })

        let noOpRemoteSHA = try runGit(["rev-parse", "refs/heads/main"], in: origin)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(noOpRemoteSHA == localSHA)
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

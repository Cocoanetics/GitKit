// Integration tests that fork the system `git` via `Process` for parity
// checks. Windows has no `/usr/bin/env`, and the swift-android-action's
// MSVC clang doesn't see a stable `git.exe` path either, so gate the
// whole suite to non-Windows. Apple/Linux still cover the integration
// surface.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

/// Collects progress text from a push; the sink is `@Sendable`.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    func append(_ text: String) { lock.lock(); buffer += text; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return buffer }
}

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

    @Test("push prints git's summary for each kind of ref update")
    func pushSummaryLines() throws {
        let dir = try makeFixtureRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let origin = try makeBareOrigin()
        defer { try? FileManager.default.removeItem(at: origin) }

        let repo = try Repository.open(at: dir)
        try repo.addRemote(name: "origin", url: origin)
        func head() throws -> String {
            try runGit(["rev-parse", "HEAD"], in: dir)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func push(_ refspec: String = "main", lease: PushLease? = nil) throws -> String {
            let log = ProgressLog()
            if let lease {
                try repo.push(remote: "origin", refspec: refspec, setUpstream: false,
                              forceWithLease: lease, progress: { log.append($0) })
            } else {
                try repo.push(remote: "origin", refspec: refspec, setUpstream: false,
                              progress: { log.append($0) })
            }
            return log.text
        }

        #expect(try push().hasSuffix(" * [new branch]      main -> main\n"))

        let first = try head()
        try Data("more\n".utf8).write(to: dir.appendingPathComponent("more.txt"))
        try runGit(["add", "more.txt"], in: dir)
        try runGit(["commit", "-m", "more"], in: dir)
        let second = try head()
        #expect(try push().hasSuffix("   \(first.prefix(7))..\(second.prefix(7))  main -> main\n"))

        #expect(try push() == "Everything up-to-date\n")

        try runGit(["commit", "--amend", "-m", "amended"], in: dir)
        let amended = try head()
        #expect(try push(lease: .expecting(second)).hasSuffix(
            " + \(second.prefix(7))...\(amended.prefix(7)) main -> main (forced update)\n"))

        // Forced, but a fast-forward: git prints a plain update.
        try Data("next\n".utf8).write(to: dir.appendingPathComponent("next.txt"))
        try runGit(["add", "next.txt"], in: dir)
        try runGit(["commit", "-m", "next"], in: dir)
        let next = try head()
        #expect(try push(lease: .expecting(amended)).hasSuffix(
            "   \(amended.prefix(7))..\(next.prefix(7))  main -> main\n"))

        try runGit(["branch", "dev"], in: dir)
        _ = try push("dev")
        #expect(try push(":refs/heads/dev").hasSuffix(" - [deleted]         dev\n"))

        try runGit(["tag", "v1"], in: dir)
        #expect(try push("v1").hasSuffix(" * [new tag]         v1 -> v1\n"))
        #expect(try push("refs/tags/v1:refs/heads/fromtag").hasSuffix(
            " * [new branch]      v1 -> fromtag\n"))
        try runGit(["update-ref", "refs/remotes/upstream/topic", "HEAD"], in: dir)
        #expect(try push("refs/remotes/upstream/topic:refs/heads/topic").hasSuffix(
            " * [new branch]      upstream/topic -> topic\n"))
        #expect(try push("main:refs/custom/foo").hasSuffix(
            " * [new reference]   main -> refs/custom/foo\n"))
        try runGit(["update-ref", "refs/custom/local", "HEAD"], in: dir)
        #expect(try push("refs/custom/local:refs/custom/remote").hasSuffix(
            " * [new reference]   refs/custom/local -> refs/custom/remote\n"))

        try runGit(["switch", "-c", "local"], in: dir)
        #expect(try push("local:remote").hasSuffix(" * [new branch]      local -> remote\n"))
        #expect(try push("HEAD:refs/heads/review").hasSuffix(
            " * [new branch]      HEAD -> review\n"))

        // core.abbrev widens the IDs and the column.
        try runGit(["switch", "-q", "main"], in: dir)
        try runGit(["config", "core.abbrev", "12"], in: dir)
        let before = try head()
        try runGit(["commit", "--allow-empty", "-m", "abbrev"], in: dir)
        let after = try head()
        #expect(try push().hasSuffix(
            "   \(before.prefix(12))..\(after.prefix(12))  main -> main\n"))
    }

    @Test("fetch and push take a path, like git's <repository>")
    func fetchAndPushAPath() throws {
        let source = try makeFixtureRepo()
        defer { try? FileManager.default.removeItem(at: source) }
        let origin = try makeBareOrigin()
        defer { try? FileManager.default.removeItem(at: origin) }

        // push <path> main, with -u: no remote is configured.
        let repo = try Repository.open(at: source)
        try repo.push(remote: origin.path, refspec: "main", setUpstream: true, progress: { _ in })
        let head = try runGit(["rev-parse", "HEAD"], in: source)
        #expect(try runGit(["rev-parse", "main"], in: origin) == head)
        #expect(try runGit(["remote"], in: source).isEmpty)
        #expect(try runGit(["config", "branch.main.remote"], in: source)
                == origin.path + "\n")
        #expect(try runGit(["config", "branch.main.merge"], in: source) == "refs/heads/main\n")

        // fetch <path> <refspec>, and fetch <path> main into FETCH_HEAD.
        let dest = try makeFixtureRepo(withCommit: false)
        defer { try? FileManager.default.removeItem(at: dest) }
        let fetcher = try Repository.open(at: dest)
        try fetcher.fetch(remote: origin.path, refspec: "refs/heads/main:refs/heads/fetched",
                          progress: { _ in })
        #expect(try runGit(["rev-parse", "fetched"], in: dest) == head)
        try fetcher.fetch(remote: origin.path, refspec: "main", progress: { _ in })
        #expect(try runGit(["rev-parse", "FETCH_HEAD"], in: dest) == head)
        #expect(try runGit(["remote"], in: dest).isEmpty)
    }

    @Test("a tracking lease on a URL or path expects the branch absent")
    func trackingLeaseOnAPath() throws {
        let source = try makeFixtureRepo()
        defer { try? FileManager.default.removeItem(at: source) }
        let origin = try makeBareOrigin()
        defer { try? FileManager.default.removeItem(at: origin) }

        let repo = try Repository.open(at: source)
        // Absent on the remote: the leased push goes through.
        try repo.push(remote: origin.path, refspec: "main", setUpstream: false,
                      forceWithLease: .tracking, progress: { _ in })
        #expect(try runGit(["rev-parse", "main"], in: origin)
                == runGit(["rev-parse", "HEAD"], in: source))
        // Present now, with no tracking ref to vouch for it: refused.
        try runGit(["commit", "--allow-empty", "-m", "two"], in: source)
        #expect(throws: Libgit2Error.self) {
            try repo.push(remote: origin.path, refspec: "main", setUpstream: false,
                          forceWithLease: .tracking, progress: { _ in })
        }
    }

    @Test("a remote that is neither configured nor a repository fails")
    func unknownRemoteFails() throws {
        let dir = try makeFixtureRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try Repository.open(at: dir)
        #expect(throws: Libgit2Error.self) {
            try repo.fetch(remote: "orign", refspec: "main", progress: { _ in })
        }
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
        // A detached HEAD isn't a branch to guess a destination from.
        #expect {
            try repo.push(
                remote: "origin", refspec: "HEAD:review-fixes",
                setUpstream: false, progress: { _ in })
        } throws: { error in
            (error as? PushRefusedError)?.refusals.first?.hint.last == "'HEAD:refs/heads/review-fixes'?"
        }
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

        let error = #expect(throws: PushRejectedError.self) {
            try repo.push(
                remote: "origin", refspec: "HEAD:refs/heads/review-fixes",
                setUpstream: false, progress: { _ in })
        }
        #expect(error?.rejections == [.init(remoteRef: "refs/heads/review-fixes",
                                            reason: .nonFastForward)])
        let protectedSHA = try runGit(["rev-parse", "refs/heads/review-fixes"], in: origin)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(protectedSHA == advancedSHA)
    }

    @Test("push HEAD sets upstream for the attached branch")
    func pushAttachedHEADSetUpstream() throws {
        let dir = try makeFixtureRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let origin = try makeBareOrigin()
        defer { try? FileManager.default.removeItem(at: origin) }

        let repo = try Repository.open(at: dir)
        try repo.addRemote(name: "origin", url: origin)
        try repo.push(
            remote: "origin", refspec: "HEAD:refs/heads/review-fixes",
            setUpstream: true, progress: { _ in })

        let upstreamRemote = try runGit(["config", "branch.main.remote"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let upstreamMerge = try runGit(["config", "branch.main.merge"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(upstreamRemote == "origin")
        #expect(upstreamMerge == "refs/heads/review-fixes")
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
        } catch let error as PushRefusedError {
            #expect(error.refusals.map(\.message) == ["src refspec release matches more than one"])
        } catch {
            Issue.record("expected PushRefusedError, got \(error)")
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

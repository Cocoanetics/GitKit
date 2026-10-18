// Integration tests for the per-ref lines a fetch prints. Each case runs
// the same fetch with the system `git` and with GitKit, in two clones of
// one remote, and compares what they print (gated to non-Windows for the
// same reasons as the other integration suites).
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

/// Collects progress text; the sink is `@Sendable`.
private final class FetchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    func append(_ text: String) { lock.lock(); buffer += text; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return buffer }
}

/// A fetch prints git's summary: `[new branch]`, `[new tag]`, `old..new`,
/// `old...new (forced update)`, `[deleted]` for a pruned ref, and
/// ` * branch  main -> FETCH_HEAD` for what goes to FETCH_HEAD alone, in a
/// ref column as wide as the longest remote ref.
@Suite("Fetch summary")
struct FetchSummaryTests {

    private func tmp(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FetchSummaryTests-\(label)-\(UUID().uuidString)")
    }

    /// Runs the system `git`; returns stdout and stderr together.
    @discardableResult
    private func runGit(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-c", "user.name=Test", "-c", "user.email=test@example.com",
                       "-c", "fetch.showForcedUpdates=true"] + args
        p.currentDirectoryURL = dir
        let out = Pipe()
        p.standardOutput = out; p.standardError = out
        try p.run()
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw Failure("git \(args.joined(separator: " ")) failed: \(text)")
        }
        return text
    }

    /// The system `git` without this suite's `-c` options, so a
    /// repository's own config decides.
    private func runGitIgnoringOptions(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = dir
        let out = Pipe()
        p.standardOutput = out; p.standardError = out
        try p.run()
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private struct Failure: Error, CustomStringConvertible {
        let message: String
        init(_ m: String) { self.message = m }
        var description: String { message }
    }

    /// A remote with `main`, `dev` and `gone`, a working copy that moves
    /// it on, and two identical clones of it.
    private struct Fixture {
        let remote: URL, work: URL, git: URL, kit: URL
        func remove() { [remote, work, git, kit].forEach { try? FileManager.default.removeItem(at: $0) } }
    }

    private func makeFixture() throws -> Fixture {
        let work = tmp("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try runGit(["init", "-q", "-b", "main"], in: work)
        try runGit(["commit", "-q", "--allow-empty", "-m", "one"], in: work)
        try runGit(["branch", "dev"], in: work)
        try runGit(["branch", "gone"], in: work)
        let remote = tmp("remote").appendingPathExtension("git")
        try runGit(["clone", "-q", "--bare", work.path, remote.path], in: work)
        try runGit(["remote", "add", "origin", remote.path], in: work)
        let git = tmp("git"), kit = tmp("kit")
        try runGit(["clone", "-q", remote.path, git.path], in: work)
        try runGit(["clone", "-q", remote.path, kit.path], in: work)
        return Fixture(remote: remote, work: work, git: git, kit: kit)
    }

    private func gitKitFetch(
        _ repo: URL, refspecs: [String] = [], remote: String = "origin", prune: Bool = false
    ) throws -> String {
        let log = FetchLog()
        try Repository.open(at: repo).fetch(
            remote: remote, refspecs: refspecs, prune: prune, progress: { log.append($0) })
        return log.text
    }

    @Test("headers show remotes as git does: without credentials, and fetch without .git")
    func displayURLs() {
        let cases: [(url: String, shown: String, from: String)] = [
            ("https://user:token@github.com/o/r.git", "https://github.com/o/r.git", "https://github.com/o/r"),
            ("git@github.com:o/r.git", "github.com:o/r.git", "github.com:o/r"),
            ("ssh://git@host:2222/r.git/", "ssh://host:2222/r.git/", "ssh://host:2222/r"),
            ("https://host/path@x", "https://host/path@x", "https://host/path@x"),
            ("/srv/with@at/r.git", "/srv/with@at/r.git", "/srv/with@at/r"),
            ("file:///tmp/r.git/", "file:///tmp/r.git/", "file:///tmp/r")
        ]
        for (url, shown, from) in cases {
            #expect(ProgressReporter.anonymizedURL(url) == shown, "\(url)")
            #expect(ProgressReporter.fetchDisplayURL(url) == from, "\(url)")
        }
    }

    @Test("new branches and tags, fast-forwards, forced updates and pruned refs")
    func updates() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let (remote, work, git, kit) = (fixture.remote, fixture.work, fixture.git, fixture.kit)
        try runGit(["commit", "-q", "--allow-empty", "-m", "two"], in: work)
        try runGit(["branch", "a-much-longer-branch-name"], in: work)
        try runGit(["tag", "v1"], in: work)
        try runGit(["switch", "-q", "--orphan", "fresh"], in: work)
        try runGit(["commit", "-q", "--allow-empty", "-m", "unrelated"], in: work)
        try runGit(["branch", "-f", "dev", "fresh"], in: work)
        try runGit(["push", "-q", "--force", "origin", "main", "dev", "a-much-longer-branch-name",
                    "v1", ":gone"], in: work)

        // Both clones keep a copy to fetch into once more, with forced
        // updates not told apart (fetch.showForcedUpdates=false).
        let gitCopy = tmp("git-copy"), kitCopy = tmp("kit-copy")
        defer { [gitCopy, kitCopy].forEach { try? FileManager.default.removeItem(at: $0) } }
        try FileManager.default.copyItem(at: git, to: gitCopy)
        try FileManager.default.copyItem(at: kit, to: kitCopy)

        let expected = try runGit(["fetch", "--prune", "origin"], in: git)
        let output = try gitKitFetch(kit, prune: true)
        #expect(output == expected)

        for clone in [gitCopy, kitCopy] {
            try runGit(["config", "fetch.showForcedUpdates", "false"], in: clone)
        }
        // git versions print the warning in different places: compare
        // the rest, and require the warning.
        let warning = """
            warning: fetch normally indicates which branches had a forced update,
            but that check has been disabled; to re-enable, use '--show-forced-updates'
            flag or run 'git config fetch.showForcedUpdates true'

            """
        let unforced = try runGitIgnoringOptions(["fetch", "origin"], in: gitCopy)
        let unforcedOutput = try gitKitFetch(kitCopy)
        #expect(unforcedOutput.contains(warning))
        #expect(unforcedOutput.replacingOccurrences(of: warning, with: "")
                == unforced.replacingOccurrences(of: warning, with: ""))
    }

    @Test("a ref fetched to FETCH_HEAD alone, with its tracking ref updated")
    func fetchHeadOnly() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let (remote, work, git, kit) = (fixture.remote, fixture.work, fixture.git, fixture.kit)
        try runGit(["commit", "-q", "--allow-empty", "-m", "two"], in: work)
        try runGit(["tag", "v1"], in: work)
        try runGit(["branch", "-f", "dev", "main"], in: work)
        try runGit(["push", "-q", "origin", "main", "dev", "v1"], in: work)

        let expected = try runGit(["fetch", "origin", "main"], in: git)
        let output = try gitKitFetch(kit, refspecs: ["main"])
        #expect(output == expected)
        // Nothing stored, so no tags followed (the remote has `v1`).
        #expect(throws: Failure.self) { try runGit(["rev-parse", "--verify", "v1"], in: kit) }

        // A remote set to fetch all tags still does.
        try runGit(["config", "remote.origin.tagOpt", "--tags"], in: kit)
        _ = try gitKitFetch(kit, refspecs: ["main"])
        #expect(try runGit(["rev-parse", "--verify", "v1"], in: kit).isEmpty == false)
        try runGit(["config", "--unset", "remote.origin.tagOpt"], in: kit)
        try runGit(["tag", "-d", "v1"], in: kit)

        // With a destination, the tag comes along, before the
        // opportunistic update of origin/dev.
        let stored = try runGit(["fetch", "origin", "dev:refs/heads/copy"], in: git)
        let storedOutput = try gitKitFetch(kit, refspecs: ["dev:refs/heads/copy"])
        #expect(storedOutput == stored)

        // A remote without a fetch refspec: its HEAD.
        for clone in [git, kit] {
            try runGit(["remote", "add", "nomap", remote.path], in: clone)
            try runGit(["config", "--unset-all", "remote.nomap.fetch"], in: clone)
        }
        let head = try runGit(["fetch", "nomap"], in: git)
        let headOutput = try gitKitFetch(kit, remote: "nomap")
        #expect(headOutput == head)
    }
}
#endif

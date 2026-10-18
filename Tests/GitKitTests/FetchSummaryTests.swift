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

    @Test("refspecs given together list in their order, a branch can go into a tag")
    func severalRefspecs() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let (work, git, kit) = (fixture.work, fixture.git, fixture.kit)
        try runGit(["commit", "-q", "--allow-empty", "-m", "two"], in: work)
        try runGit(["tag", "v1"], in: work)
        try runGit(["branch", "-f", "dev", "main"], in: work)
        try runGit(["push", "-q", "origin", "main", "dev", "v1"], in: work)

        // A branch into a local tag, a ref both source-only and stored:
        // git names the branch, and shows both lines.
        let refspecs = ["main:refs/tags/x", "main", "dev:refs/heads/copy"]
        let expected = try runGit(["fetch", "origin"] + refspecs, in: git)
        let output = try gitKitFetch(kit, refspecs: refspecs)
        #expect(output == expected)
    }

    @Test("the ref column is sized in terminal columns but padded in bytes, as git does")
    func wideRefNames() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let (work, git, kit) = (fixture.work, fixture.git, fixture.kit)
        // Two columns and three bytes: seven spaces in a 10-wide column.
        try runGit(["branch", "中"], in: work)
        try runGit(["push", "-q", "origin", "中"], in: work)
        let narrow = try runGit(["fetch", "origin"], in: git)
        #expect(narrow.contains(" 中        -> origin/中\n"))
        #expect(try gitKitFetch(kit) == narrow)

        // Fourteen columns widen the column to 14, not to its 7 characters.
        try runGit(["branch", "中中中中中中中"], in: work)
        try runGit(["branch", "dev-two"], in: work)
        try runGit(["push", "-q", "origin", "中中中中中中中", "dev-two"], in: work)
        let wide = try runGit(["fetch", "origin"], in: git)
        #expect(wide.contains(" dev-two        -> origin/dev-two\n"))
        #expect(try gitKitFetch(kit) == wide)
    }

    @Test("the ref to merge is told from a canonically equal one by its bytes")
    func mergeRefComparedAsBytes() throws {
        // Two branches only canonically equal can't both live in one
        // directory on APFS, so FETCH_HEAD is written by hand.
        let repo = tmp("bytes")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        try runGit(["init", "-q", "-b", "main"], in: repo)
        let composed = "caf\u{E9}", decomposed = "cafe\u{301}"
        let oid = String(repeating: "1", count: 40)
        try Data("""
            \(oid)\t\tbranch '\(composed)' of /srv/remote
            \(oid)\tnot-for-merge\tbranch '\(decomposed)' of /srv/remote

            """.utf8).write(to: repo.appendingPathComponent(".git/FETCH_HEAD"))
        func line(_ name: String) -> FetchSummaryLine {
            FetchSummaryLine(kind: .update, flag: " ", summary: "1111111..2222222",
                             remoteRef: "refs/heads/\(name)", remote: name,
                             localRef: "refs/remotes/origin/\(name)", local: "origin/\(name)")
        }
        let ordered = try Repository.open(at: repo).orderedFetchLines(
            [line(decomposed), line(composed)], refspecs: ["+refs/heads/*:refs/remotes/origin/*"])
        // The ref to merge comes first, though the other sorts first by bytes.
        #expect(ordered.map { Array($0.remote.utf8) } == [Array(composed.utf8), Array(decomposed.utf8)])
    }

    @Test("fetch.showForcedUpdates takes every boolean spelling git takes")
    func showForcedUpdatesSpellings() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let kit = fixture.kit
        // Nothing to fetch: what's printed is the warning, or nothing.
        let warning = "warning: fetch normally indicates which branches had a forced update,"
        for (value, warns) in [("00", true), ("-0", true), ("0x0", true), ("", true), ("1k", false)] {
            try runGit(["config", "fetch.showForcedUpdates", value], in: kit)
            #expect(try gitKitFetch(kit).hasPrefix(warning) == warns, "\(value)")
        }
        // A key without a value is true.
        try runGit(["config", "--unset", "fetch.showForcedUpdates"], in: kit)
        let config = kit.appendingPathComponent(".git/config")
        try (String(decoding: Data(contentsOf: config), as: UTF8.self) + "[fetch]\n\tshowForcedUpdates\n")
            .write(to: config, atomically: true, encoding: .utf8)
        #expect(try gitKitFetch(kit) == "")

        try runGit(["config", "--unset", "fetch.showForcedUpdates"], in: kit)
        try runGit(["config", "fetch.showForcedUpdates", "bogus"], in: kit)
        #expect {
            try gitKitFetch(kit)
        } throws: { error in
            (error as? Libgit2Error)?.message
                == "bad boolean config value 'bogus' for 'fetch.showforcedupdates'"
        }
    }

    @Test("pruned refs list by their full names, across namespaces")
    func prunedAcrossNamespaces() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let (work, git, kit) = (fixture.work, fixture.git, fixture.kit)
        // `refs/heads/x/gone` sorts before `refs/remotes/origin/gone`,
        // though `origin/gone` sorts before `x/gone`.
        for clone in [git, kit] {
            try runGit(["config", "--add", "remote.origin.fetch", "+refs/heads/*:refs/heads/x/*"], in: clone)
            try runGit(["fetch", "-q", "origin"], in: clone)
        }
        try runGit(["push", "-q", "origin", ":gone"], in: work)
        let expected = try runGit(["fetch", "--prune", "origin"], in: git)
        #expect(expected.contains(" - [deleted]         (none)     -> x/gone\n - [deleted]"))
        #expect(try gitKitFetch(kit, prune: true) == expected)
    }

    @Test("core.abbrev is read as git reads it, and refused as git refuses it")
    func coreAbbrev() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let (work, git, kit) = (fixture.work, fixture.git, fixture.kit)
        try runGit(["commit", "-q", "--allow-empty", "-m", "two"], in: work)
        try runGit(["push", "-q", "origin", "main"], in: work)
        for value in ["3", "bogus", "true"] {
            try runGit(["config", "core.abbrev", value], in: kit)
            #expect(throws: Libgit2Error.self, "\(value)") { try gitKitFetch(kit) }
        }
        // Refused before anything was fetched.
        try runGit(["config", "--unset", "core.abbrev"], in: kit)
        #expect(try runGit(["rev-parse", "origin/main"], in: kit) != runGit(["rev-parse", "main"], in: work))

        // `no` is the full ID; a number takes git's units, at most 40.
        for value in ["no", "7k"] {
            for clone in [git, kit] { try runGit(["config", "core.abbrev", value], in: clone) }
            try runGit(["commit", "-q", "--allow-empty", "-m", value], in: work)
            try runGit(["push", "-q", "origin", "main"], in: work)
            let expected = try runGit(["fetch", "origin"], in: git)
            #expect(expected.contains(try runGit(["rev-parse", "main"], in: work)
                .trimmingCharacters(in: .whitespacesAndNewlines)))
            #expect(try gitKitFetch(kit) == expected)
        }
    }

    @Test("display widths count as git's utf8_strwidth does")
    func displayWidths() {
        #expect(DisplayWidth.of("main") == 4)
        #expect(DisplayWidth.of("中文") == 4)
        // Per code point: a combining accent adds nothing, a zero-width
        // joiner nothing, each emoji two; a control character nothing.
        #expect(DisplayWidth.of("e\u{301}") == 1)
        #expect(DisplayWidth.of("👩\u{200D}💻") == 4)
        #expect(DisplayWidth.of("a\u{7}b") == 2)
        #expect(DisplayWidth.of("\u{AD}") == 1)
    }

    @Test("an annotated tag moved forward is a fast-forward, peeled to its commit")
    func annotatedTagFastForward() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let (work, git, kit) = (fixture.work, fixture.git, fixture.kit)
        try runGit(["tag", "-a", "-m", "one", "v1"], in: work)
        try runGit(["push", "-q", "origin", "v1"], in: work)
        for clone in [git, kit] {
            try runGit(["fetch", "-q", "origin", "refs/tags/v1:refs/custom/x"], in: clone)
        }
        try runGit(["commit", "-q", "--allow-empty", "-m", "two"], in: work)
        try runGit(["tag", "-f", "-a", "-m", "two", "v1"], in: work)
        try runGit(["push", "-q", "-f", "origin", "v1"], in: work)

        let expected = try runGit(["fetch", "origin", "+refs/tags/v1:refs/custom/x"], in: git)
        let output = try gitKitFetch(kit, refspecs: ["+refs/tags/v1:refs/custom/x"])
        #expect(output == expected)
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
        // git versions word the warning differently and print it in
        // different places: GitKit follows git 2.54, and the summary
        // itself has to match.
        let warning = """
            warning: fetch normally indicates which branches had a forced update,
            but that check has been disabled; to re-enable, use '--show-forced-updates'
            flag or run 'git config fetch.showForcedUpdates true'

            """
        func withoutWarning(_ output: String) -> String {
            var lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            if let start = lines.firstIndex(where: { $0.hasPrefix("warning: ") }) {
                lines.removeSubrange(start..<min(start + 3, lines.count))
            }
            return lines.joined(separator: "\n")
        }
        let unforced = try runGitIgnoringOptions(["fetch", "origin"], in: gitCopy)
        let unforcedOutput = try gitKitFetch(kitCopy)
        #expect(unforcedOutput.hasPrefix(warning))
        #expect(withoutWarning(unforcedOutput) == withoutWarning(unforced))
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

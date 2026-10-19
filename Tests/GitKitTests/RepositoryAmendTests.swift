// Integration tests that fork the system `git` via `Process` for parity
// checks — gated to macOS/Linux like the other `git`-driven suites.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

/// Twin fixtures: the same history built twice by the `git` CLI with fixed
/// dates, so its commits are identical; one twin is amended by real git,
/// the other by GitKit, and the results must match to the byte.
private enum AmendFixture {
    /// Thu Jan 1 10:00:00 2026 +0100 — every fixture commit's dates.
    static let authorDate = "1767258000 +0100"
    /// Mon Feb 2 11:00:00 2026 +0100 — the amend's committer date.
    static let commitDate = "1770026400 +0100"

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func makeRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepositoryAmendTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: dir)
        try git(["config", "user.email", "t@e.com"], in: dir)
        try git(["config", "user.name", "T"], in: dir)
        return dir
    }

    /// Run `git` with no ambient `GIT_*` variables or global config, plus
    /// `env`. Returns stdout, stderr and the exit status.
    @discardableResult
    static func run(
        _ args: [String], in dir: URL, env: [String: String] = [:]
    ) throws -> (out: String, err: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = dir
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment.merge(env) { $1 }
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: outData, as: UTF8.self),
                String(decoding: errData, as: UTF8.self), process.terminationStatus)
    }

    /// Run `git` with every date pinned to ``authorDate``; throws on failure.
    @discardableResult
    static func git(_ args: [String], in dir: URL) throws -> String {
        let result = try run(args, in: dir, env: [
            "GIT_AUTHOR_DATE": authorDate, "GIT_COMMITTER_DATE": authorDate
        ])
        guard result.status == 0 else {
            throw Failure(description: "git \(args.joined(separator: " ")) failed: \(result.err)")
        }
        return result.out
    }

    static func write(_ text: String, to name: String, in dir: URL) throws {
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }

    /// Two commits: `f` ("first"), then `g` ("second").
    static func twoCommits(_ dir: URL) throws {
        try write("hi\n", to: "f", in: dir)
        try git(["add", "f"], in: dir)
        try git(["commit", "-q", "-m", "first"], in: dir)
        try write("two\n", to: "g", in: dir)
        try git(["add", "g"], in: dir)
        try git(["commit", "-q", "-m", "second"], in: dir)
    }

    static func lastLine(of path: String, in dir: URL) throws -> String {
        let text = String(decoding: try Data(contentsOf: dir.appendingPathComponent(path)), as: UTF8.self)
        return text.split(separator: "\n").last.map(String.init) ?? ""
    }

    /// Render `details` as `git commit` prints its summary — what a CLI
    /// built on GitKit prints.
    static func summary(_ details: Libgit2CommitDetails, subject: String) -> String {
        let root = details.isRoot ? " (root-commit)" : ""
        var out = "[\(details.branchName ?? "detached HEAD")\(root) \(details.shortSHA)] \(subject)\n"
        let author = details.author
        let committer = details.committer
        if author.name != committer.name || author.email != committer.email {
            out += " Author: \(author.name) <\(author.email)>\n"
        }
        if details.showsAuthorDate { out += " Date: \(author.formattedDate)\n" }
        if details.filesChanged > 0 {
            out += " \(details.filesChanged) file\(details.filesChanged == 1 ? "" : "s") changed"
            if details.insertions > 0 || details.deletions == 0 {
                out += ", \(details.insertions) insertion\(details.insertions == 1 ? "" : "s")(+)"
            }
            if details.deletions > 0 || details.insertions == 0 {
                out += ", \(details.deletions) deletion\(details.deletions == 1 ? "" : "s")(-)"
            }
            out += "\n"
        }
        let modes = details.addedFiles.map { ("create", $0) } + details.deletedFiles.map { ("delete", $0) }
        for (kind, file) in modes.sorted(by: { $0.1.path < $1.1.path }) {
            out += " \(kind) mode \(String(format: "%06o", file.mode)) \(file.path)\n"
        }
        return out
    }

    /// Build the fixture twice, amend one twin with `git commit --amend
    /// <gitArgs>` and the other with `amend`, and expect the same commit,
    /// the same reflog entries and the same summary.
    @discardableResult
    static func expectParity(
        setup: (URL) throws -> Void,
        gitArgs: [String],
        subject: String,
        env: [String: String] = [:],
        after: (_ viaGit: URL, _ viaKit: URL) throws -> Void = { _, _ in },
        amend: (Repository, [String: String]) throws -> Libgit2CommitDetails
    ) throws -> Libgit2CommitDetails {
        let viaGit = try makeRepo()
        let viaKit = try makeRepo()
        defer {
            try? FileManager.default.removeItem(at: viaGit)
            try? FileManager.default.removeItem(at: viaKit)
        }
        try setup(viaGit)
        try setup(viaKit)
        let amendEnv = env.merging(["GIT_COMMITTER_DATE": commitDate]) { $1 }
        let expected = try run(["commit", "--amend"] + gitArgs, in: viaGit, env: amendEnv)
        #expect(expected.status == 0, "git failed: \(expected.err)")

        let details = try amend(try Repository.open(at: viaKit), amendEnv)

        let gitHead = try git(["rev-parse", "HEAD"], in: viaGit)
        let kitHead = try git(["rev-parse", "HEAD"], in: viaKit)
        #expect(kitHead == gitHead)
        #expect(details.sha + "\n" == kitHead)
        #expect(try git(["cat-file", "-p", "HEAD"], in: viaKit) == git(["cat-file", "-p", "HEAD"], in: viaGit))
        var logs = ["logs/HEAD"]
        if let branch = details.branchName { logs.append("logs/refs/heads/\(branch)") }
        for log in logs {
            let line = try lastLine(of: ".git/\(log)", in: viaKit)
            #expect(line == (try lastLine(of: ".git/\(log)", in: viaGit)))
            #expect(line.hasSuffix("\tcommit (amend): \(subject)"))
        }
        #expect(summary(details, subject: subject) == expected.out)
        try after(viaGit, viaKit)
        return details
    }

    /// Build the fixture twice, amend one twin quietly with `git commit
    /// --amend <gitArgs>` and the other with `amend`, and expect the same
    /// commit and the same reflogs byte for byte — or both without them.
    static func expectSameRepos(
        setup: (URL) throws -> Void,
        gitArgs: [String],
        after: (_ viaGit: URL, _ viaKit: URL) throws -> Void = { _, _ in },
        amend: (Repository, [String: String]) throws -> Void
    ) throws {
        let viaGit = try makeRepo()
        let viaKit = try makeRepo()
        defer {
            try? FileManager.default.removeItem(at: viaGit)
            try? FileManager.default.removeItem(at: viaKit)
        }
        try setup(viaGit)
        try setup(viaKit)
        let env = ["GIT_COMMITTER_DATE": commitDate]
        let amended = try run(["commit", "-q", "--amend"] + gitArgs, in: viaGit, env: env)
        #expect(amended.status == 0, "git failed: \(amended.err)")
        try amend(try Repository.open(at: viaKit), env)
        #expect(try git(["rev-parse", "HEAD"], in: viaKit) == git(["rev-parse", "HEAD"], in: viaGit))
        for log in [".git/logs/HEAD", ".git/logs/refs/heads/main"] {
            let kitLog = FileManager.default.contents(atPath: viaKit.appendingPathComponent(log).path)
            let gitLog = FileManager.default.contents(atPath: viaGit.appendingPathComponent(log).path)
            #expect(kitLog == gitLog, "\(log) differs")
        }
        try after(viaGit, viaKit)
    }
}

@Suite("Repository.amendDetailed")
struct RepositoryAmendTests {

    @Test("a new message keeps the parents, tree and author date")
    func messageChange() throws {
        let details = try AmendFixture.expectParity(
            setup: AmendFixture.twoCommits, gitArgs: ["-m", "second reworded"],
            subject: "second reworded") { repo, env in
                try repo.amendDetailed(message: "second reworded\n", env: env)
            }
        #expect(details.showsAuthorDate)
        #expect(details.author.formattedDate == "Thu Jan 1 10:00:00 2026 +0100")
        #expect(details.committer.formattedDate == "Mon Feb 2 11:00:00 2026 +0100")
        #expect(details.filesChanged == 1)
        #expect(details.addedFiles.map(\.path) == ["g"])
    }

    @Test("--no-edit keeps the old message")
    func noEdit() throws {
        try AmendFixture.expectParity(
            setup: AmendFixture.twoCommits, gitArgs: ["--no-edit"], subject: "second") { repo, env in
                try repo.amendDetailed(env: env)
            }
    }

    @Test("staged files join the amended commit, its diffstat against the parent")
    func addedFile() throws {
        let details = try AmendFixture.expectParity(
            setup: { dir in
                try AmendFixture.twoCommits(dir)
                try AmendFixture.write("three\n", to: "h", in: dir)
                try AmendFixture.git(["add", "h"], in: dir)
                try AmendFixture.git(["rm", "-q", "f"], in: dir)
            },
            gitArgs: ["--no-edit"], subject: "second", amend: { repo, env in
                try repo.amendDetailed(env: env)
            })
        #expect(details.filesChanged == 3)
        #expect(details.deletedFiles.map(\.path) == ["f"])
    }

    @Test("-a: tracked changes staged first, untracked files left alone")
    func stageTracked() throws {
        try AmendFixture.expectParity(
            setup: { dir in
                try AmendFixture.twoCommits(dir)
                try AmendFixture.write("changed\n", to: "f", in: dir)
                try AmendFixture.write("untracked\n", to: "u", in: dir)
            },
            gitArgs: ["-a", "--no-edit"], subject: "second", amend: { repo, env in
                try repo.stageTrackedChanges()
                return try repo.amendDetailed(env: env)
            })
    }

    @Test("a root commit is amended without (root-commit), diffed against the empty tree")
    func rootCommit() throws {
        let details = try AmendFixture.expectParity(
            setup: { dir in
                try AmendFixture.write("hi\n", to: "f", in: dir)
                try AmendFixture.git(["add", "f"], in: dir)
                try AmendFixture.git(["commit", "-q", "-m", "first"], in: dir)
            },
            gitArgs: ["-m", "root reworded"], subject: "root reworded", amend: { repo, env in
                try repo.amendDetailed(message: "root reworded\n", env: env)
            })
        #expect(!details.isRoot)
        #expect(details.addedFiles.map(\.path) == ["f"])
    }

    @Test("--author replaces name and email but keeps the author date")
    func authorOverride() throws {
        let details = try AmendFixture.expectParity(
            setup: AmendFixture.twoCommits,
            gitArgs: ["--author=Other <o@x.com>", "-m", "authored"], subject: "authored") { repo, env in
                try repo.amendDetailed(
                    message: "authored\n", author: Signature(name: "Other", email: "o@x.com"), env: env)
            }
        #expect(details.author.name == "Other")
        #expect(details.author.time == 1_767_258_000)
    }

    @Test("--reset-author takes a new commit's author, and no Date line")
    func resetAuthor() throws {
        let details = try AmendFixture.expectParity(
            setup: AmendFixture.twoCommits, gitArgs: ["--reset-author", "-m", "reset"],
            subject: "reset", env: ["GIT_AUTHOR_DATE": AmendFixture.commitDate]) { repo, env in
                try repo.amendDetailed(message: "reset\n", resetAuthor: true, env: env)
            }
        #expect(!details.showsAuthorDate)
    }

    @Test("a detached HEAD is amended in place")
    func detachedHead() throws {
        let details = try AmendFixture.expectParity(
            setup: { dir in
                try AmendFixture.twoCommits(dir)
                try AmendFixture.git(["checkout", "-q", "--detach"], in: dir)
            },
            gitArgs: ["-m", "detached"], subject: "detached", amend: { repo, env in
                try repo.amendDetailed(message: "detached\n", env: env)
            })
        #expect(details.branchName == nil)
    }

    @Test("--no-edit re-encodes an old non-UTF-8 message as git does")
    func oldEncoding() throws {
        try AmendFixture.expectParity(
            setup: { dir in
                try AmendFixture.twoCommits(dir)
                try AmendFixture.git(["config", "i18n.commitEncoding", "ISO-8859-1"], in: dir)
                let message = dir.appendingPathComponent("msg")
                try Data([0x63, 0x61, 0x66, 0xE9, 0x0A]).write(to: message) // "café" in Latin-1
                try AmendFixture.git(["commit", "-q", "--amend", "-F", "msg"], in: dir)
                try FileManager.default.removeItem(at: message)
                try AmendFixture.git(["config", "--unset", "i18n.commitEncoding"], in: dir)
            },
            gitArgs: ["--no-edit"], subject: "café", amend: { repo, env in
                try repo.amendDetailed(env: env)
            })
    }

    @Test("the reflog records commit (amend): <subject> on HEAD and the branch")
    func reflogEntry() throws {
        let dir = try AmendFixture.makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try AmendFixture.twoCommits(dir)
        let repo = try Repository.open(at: dir)
        let old = try AmendFixture.git(["rev-parse", "HEAD"], in: dir)
        let details = try repo.amendDetailed(message: "reworded\n\nbody\n")
        for name in ["HEAD", "refs/heads/main"] {
            let entry = try #require(try repo.reflog(refName: name).first)
            #expect(entry.message == "commit (amend): reworded")
            #expect(entry.newSHA == details.sha)
            #expect(entry.oldSHA + "\n" == old)
        }
    }

    @Test("the reflog subject is the first line, whitespace collapsed as git logs it")
    func reflogSubjectWhitespace() throws {
        for message in ["  spaced   out\t subject\nmore\n", "\nafter a blank line\n"] {
            try AmendFixture.expectSameRepos(
                setup: AmendFixture.twoCommits, gitArgs: ["--cleanup=verbatim", "-m", message]) { repo, env in
                    try repo.amendDetailed(message: message, env: env)
                }
        }
    }

    /// `twoCommits`, the second reworded to `bytes` under
    /// `i18n.commitEncoding=encoding`.
    static func encodedMessage(_ bytes: [UInt8], encoding: String) -> (URL) throws -> Void {
        { dir in
            try AmendFixture.twoCommits(dir)
            try AmendFixture.git(["config", "i18n.commitEncoding", encoding], in: dir)
            let message = dir.appendingPathComponent("msg")
            try Data(bytes).write(to: message)
            try AmendFixture.git(["commit", "-q", "--amend", "-F", "msg"], in: dir)
            try FileManager.default.removeItem(at: message)
        }
    }

    @Test("--no-edit re-encodes to i18n.commitEncoding, not i18n.logOutputEncoding")
    func logOutputEncodingIgnored() throws {
        // git writes the message as UTF-8 (the commit encoding), whatever
        // it displays it in.
        let latin1 = Self.encodedMessage([0x63, 0x61, 0x66, 0xE9, 0x0A], encoding: "ISO-8859-1") // "café"
        try AmendFixture.expectSameRepos(
            setup: { dir in
                try latin1(dir)
                try AmendFixture.git(["config", "--unset", "i18n.commitEncoding"], in: dir)
                try AmendFixture.git(["config", "i18n.logOutputEncoding", "CP1252"], in: dir)
            },
            gitArgs: ["--no-edit"], amend: { repo, env in try repo.amendDetailed(env: env) })
    }

    @Test("--no-edit converts any charset iconv knows, as git does")
    func iconvCharset() throws {
        // ISO-8859-15's 0xA4 is the euro sign, which Foundation has no name for.
        let latin9 = Self.encodedMessage(Array("euro ".utf8) + [0xA4, 0x0A], encoding: "ISO-8859-15")
        try AmendFixture.expectSameRepos(
            setup: { dir in
                try latin9(dir)
                try AmendFixture.git(["config", "--unset", "i18n.commitEncoding"], in: dir)
            },
            gitArgs: ["--no-edit"], amend: { repo, env in try repo.amendDetailed(env: env) })
    }

    @Test("a non-UTF-8 subject is logged in the reflog with its bytes unconverted")
    func nonUTF8ReflogSubject() throws {
        try AmendFixture.expectSameRepos(
            setup: Self.encodedMessage(Array("caf".utf8) + [0xE9, 0x20, 0x20, 0x78, 0x0A], encoding: "ISO-8859-1"),
            gitArgs: ["--no-edit"], amend: { repo, env in try repo.amendDetailed(env: env) })
    }

    @Test("with core.logAllRefUpdates=false the amend succeeds and writes no reflog")
    func reflogsDisabled() throws {
        try AmendFixture.expectSameRepos(
            setup: { dir in
                try AmendFixture.git(["config", "core.logAllRefUpdates", "false"], in: dir)
                try AmendFixture.twoCommits(dir)
                try AmendFixture.write("m\n", to: "MERGE_MSG", in: dir.appendingPathComponent(".git"))
            },
            gitArgs: ["-m", "no log"],
            after: { viaGit, viaKit in
                // The commit state is still cleared after HEAD moved.
                for dir in [viaGit, viaKit] {
                    #expect(!FileManager.default.fileExists(atPath: dir.path + "/.git/MERGE_MSG"))
                    #expect(!FileManager.default.fileExists(atPath: dir.path + "/.git/logs"))
                }
            },
            amend: { repo, env in try repo.amendDetailed(message: "no log\n", env: env) })
    }

    @Test("an amend concluding a revert clears its state, sequencer included")
    func revertStateCleared() throws {
        let state = ["REVERT_HEAD", "MERGE_MSG", "AUTO_MERGE", "sequencer"]
        try AmendFixture.expectParity(
            setup: { dir in
                try AmendFixture.write("one\n", to: "f", in: dir)
                try AmendFixture.git(["add", "f"], in: dir)
                try AmendFixture.git(["commit", "-q", "-m", "c1"], in: dir)
                try AmendFixture.write("two\n", to: "f", in: dir)
                try AmendFixture.git(["commit", "-q", "-am", "c2"], in: dir)
                try AmendFixture.write("x\n", to: "g", in: dir)
                try AmendFixture.git(["add", "g"], in: dir)
                try AmendFixture.git(["commit", "-q", "-m", "c3"], in: dir)
                try AmendFixture.write("three\n", to: "f", in: dir)
                try AmendFixture.git(["commit", "-q", "-am", "c4"], in: dir)
                // Reverts c3, then stops on c2's conflict: the last pick.
                let revert = try AmendFixture.run(
                    ["revert", "--no-edit", "HEAD~1", "HEAD~2"], in: dir,
                    env: ["GIT_AUTHOR_DATE": AmendFixture.authorDate,
                          "GIT_COMMITTER_DATE": AmendFixture.authorDate])
                #expect(revert.status == 1)
                for name in state {
                    #expect(FileManager.default.fileExists(atPath: dir.path + "/.git/" + name))
                }
                try AmendFixture.write("three\n", to: "f", in: dir)
                try AmendFixture.git(["add", "f"], in: dir)
            },
            gitArgs: ["--no-edit"], subject: "Revert \"c3\"",
            after: { viaGit, viaKit in
                for name in state {
                    #expect(!FileManager.default.fileExists(atPath: viaGit.path + "/.git/" + name))
                    #expect(!FileManager.default.fileExists(atPath: viaKit.path + "/.git/" + name))
                }
            },
            amend: { repo, env in
                try repo.amendDetailed(env: env)
            })
    }

    @Test("a held index.lock refuses the amend and is left in place")
    func indexLocked() throws {
        let dir = try AmendFixture.makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try AmendFixture.twoCommits(dir)
        let lock = dir.path + "/.git/index.lock"
        #expect(FileManager.default.createFile(atPath: lock, contents: nil))
        let git = try AmendFixture.run(["commit", "--amend", "-m", "x"], in: dir)
        #expect(git.status == 128)
        #expect(git.err.hasPrefix("fatal: Unable to create '"))
        let head = try AmendFixture.git(["rev-parse", "HEAD"], in: dir)
        let error = #expect(throws: Libgit2Error.self) {
            try Repository.open(at: dir).amendDetailed(message: "x\n")
        }
        #expect(error?.isLocked == true)
        #expect(FileManager.default.fileExists(atPath: lock))
        #expect(try AmendFixture.git(["rev-parse", "HEAD"], in: dir) == head)

        try FileManager.default.removeItem(atPath: lock)
        try Repository.open(at: dir).amendDetailed(message: "x\n")
        #expect(!FileManager.default.fileExists(atPath: lock))
    }

    @Test("nothing to amend on an unborn HEAD")
    func nothingToAmend() throws {
        let dir = try AmendFixture.makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let git = try AmendFixture.run(["commit", "--amend", "-m", "x"], in: dir)
        #expect(git.status == 128)
        #expect(git.err == "fatal: \(CommitAmendError.nothingToAmend)\n")
        #expect(throws: CommitAmendError.nothingToAmend) {
            try Repository.open(at: dir).amendDetailed(message: "x\n")
        }
    }

    @Test("amending during a merge is refused")
    func mergeInProgress() throws {
        let dir = try AmendFixture.makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try AmendFixture.twoCommits(dir)
        try AmendFixture.git(["checkout", "-q", "-b", "side", "HEAD~1"], in: dir)
        try AmendFixture.write("s\n", to: "s", in: dir)
        try AmendFixture.git(["add", "s"], in: dir)
        try AmendFixture.git(["commit", "-q", "-m", "side"], in: dir)
        try AmendFixture.git(["checkout", "-q", "main"], in: dir)
        try AmendFixture.git(["merge", "-q", "--no-commit", "--no-ff", "side"], in: dir)
        let git = try AmendFixture.run(["commit", "--amend", "-m", "x"], in: dir)
        #expect(git.status == 128)
        #expect(git.err == "fatal: \(CommitAmendError.mergeInProgress)\n")
        #expect(throws: CommitAmendError.mergeInProgress) {
            try Repository.open(at: dir).amendDetailed(message: "x\n")
        }
    }

    @Test("an amend leaving the parent's tree is refused unless --allow-empty")
    func emptyRule() throws {
        let setup: (URL) throws -> Void = { dir in
            try AmendFixture.twoCommits(dir)
            try AmendFixture.git(["rm", "-q", "g"], in: dir)
        }
        let dir = try AmendFixture.makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try setup(dir)
        let git = try AmendFixture.run(["commit", "--amend", "-m", "x"], in: dir)
        #expect(git.status == 1)
        #expect(git.err == CommitAmendError.emptyAmendAdvice)
        let repo = try Repository.open(at: dir)
        #expect(throws: CommitAmendError.wouldBeEmpty) { try repo.amendDetailed(message: "x\n") }

        // An already-empty commit is refused too, root or not.
        try AmendFixture.git(["reset", "-q", "--hard"], in: dir)
        try AmendFixture.git(["commit", "-q", "--allow-empty", "-m", "empty"], in: dir)
        #expect(throws: CommitAmendError.wouldBeEmpty) { try repo.amendDetailed() }
        let root = try AmendFixture.makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try AmendFixture.git(["commit", "-q", "--allow-empty", "-m", "empty root"], in: root)
        #expect(throws: CommitAmendError.wouldBeEmpty) {
            try Repository.open(at: root).amendDetailed(message: "x\n")
        }

        let details = try AmendFixture.expectParity(
            setup: setup, gitArgs: ["--allow-empty", "-m", "now empty"], subject: "now empty") { repo, env in
                try repo.amendDetailed(message: "now empty\n", allowEmpty: true, env: env)
            }
        #expect(details.filesChanged == 0)
    }

    @Test("a merge commit may keep its first parent's tree")
    func mergeCommitTree() throws {
        try AmendFixture.expectParity(
            setup: { dir in
                try AmendFixture.twoCommits(dir)
                try AmendFixture.git(["checkout", "-q", "-b", "side", "HEAD~1"], in: dir)
                try AmendFixture.write("s\n", to: "s", in: dir)
                try AmendFixture.git(["add", "s"], in: dir)
                try AmendFixture.git(["commit", "-q", "-m", "side"], in: dir)
                try AmendFixture.git(["checkout", "-q", "main"], in: dir)
                try AmendFixture.git(["merge", "-q", "--no-ff", "-m", "merge", "side"], in: dir)
                try AmendFixture.git(["read-tree", "HEAD^1"], in: dir)
            },
            gitArgs: ["-m", "merge kept"], subject: "merge kept", amend: { repo, env in
                try repo.amendDetailed(message: "merge kept\n", env: env)
            })
    }
}
#endif

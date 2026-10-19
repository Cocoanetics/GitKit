// Integration tests that fork the system `git` via `Process` for parity
// checks — gated to macOS/Linux like the other `git`-driven suites.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

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
                    try repo.amendDetailed(message: message, cleanup: .verbatim, env: env)
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

    @Test("the message is cleaned up as git does, -m or --no-edit, per commit.cleanup")
    func messageCleanup() throws {
        let raw = "\n\nsubject   \n\n\nbody   \n# hash\n\n"
        for mode in [nil, "strip", "verbatim", "scissors"] {
            let configure: (URL) throws -> Void = { dir in
                try AmendFixture.twoCommits(dir)
                if let mode { try AmendFixture.git(["config", "commit.cleanup", mode], in: dir) }
            }
            try AmendFixture.expectSameRepos(setup: configure, gitArgs: ["-m", raw]) { repo, env in
                try repo.amendDetailed(message: raw, env: env)
            }
            // The kept message is cleaned up too.
            try AmendFixture.expectSameRepos(
                setup: { dir in
                    try configure(dir)
                    try AmendFixture.git(["commit", "-q", "--amend", "--cleanup=verbatim", "-m", raw], in: dir)
                },
                gitArgs: ["--no-edit"], amend: { repo, env in try repo.amendDetailed(env: env) })
        }
        // An explicit mode wins over commit.cleanup, as --cleanup does.
        try AmendFixture.expectSameRepos(
            setup: { dir in
                try AmendFixture.twoCommits(dir)
                try AmendFixture.git(["config", "commit.cleanup", "verbatim"], in: dir)
            },
            gitArgs: ["--cleanup=strip", "-m", raw], amend: { repo, env in
                try repo.amendDetailed(message: raw, cleanup: .strip, env: env)
            })
        // core.commentChar names the comment lines strip removes.
        try AmendFixture.expectSameRepos(
            setup: { dir in
                try AmendFixture.twoCommits(dir)
                try AmendFixture.git(["config", "core.commentChar", ";"], in: dir)
            },
            gitArgs: ["--cleanup=strip", "-m", "kept\n# also kept\n; dropped\n"], amend: { repo, env in
                try repo.amendDetailed(message: "kept\n# also kept\n; dropped\n", cleanup: .strip, env: env)
            })
    }

    @Test("a message empty after cleanup is refused unless --allow-empty-message")
    func emptyMessage() throws {
        let dir = try AmendFixture.makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try AmendFixture.twoCommits(dir)
        let git = try AmendFixture.run(["commit", "--amend", "-m", "  \n\n"], in: dir)
        #expect(git.status == 1)
        #expect(git.err == "\(CommitAmendError.emptyMessage)\n")
        #expect(throws: CommitAmendError.emptyMessage) {
            try Repository.open(at: dir).amendDetailed(message: "  \n\n")
        }
        try AmendFixture.expectSameRepos(
            setup: AmendFixture.twoCommits, gitArgs: ["--allow-empty-message", "-m", "  \n"]) { repo, env in
                try repo.amendDetailed(message: "  \n", allowEmptyMessage: true, env: env)
            }
        // Verbatim, only a message of no bytes is empty: git refuses "" but
        // keeps " ".
        let verbatim = try AmendFixture.run(["commit", "--amend", "--cleanup=verbatim", "-m", ""], in: dir)
        #expect(verbatim.status == 1)
        #expect(verbatim.err == "\(CommitAmendError.emptyMessage)\n")
        #expect(throws: CommitAmendError.emptyMessage) {
            try Repository.open(at: dir).amendDetailed(message: "", cleanup: .verbatim)
        }
        try AmendFixture.expectSameRepos(
            setup: AmendFixture.twoCommits, gitArgs: ["--cleanup=verbatim", "-m", " "]) { repo, env in
                try repo.amendDetailed(message: " \n", cleanup: .verbatim, env: env)
            }
    }

    @Test("an unknown commit.cleanup is refused")
    func invalidCleanupMode() throws {
        let dir = try AmendFixture.makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try AmendFixture.twoCommits(dir)
        try AmendFixture.git(["config", "commit.cleanup", "bogus"], in: dir)
        let git = try AmendFixture.run(["commit", "--amend", "-m", "x"], in: dir)
        #expect(git.status == 128)
        #expect(git.err == "fatal: \(CommitAmendError.invalidCleanupMode("bogus"))\n")
        #expect(throws: CommitAmendError.invalidCleanupMode("bogus")) {
            try Repository.open(at: dir).amendDetailed(message: "x\n")
        }
    }

    @Test("a reflog emptied by git reflog expire gets the amend under the committer")
    func expiredReflog() throws {
        try AmendFixture.expectSameRepos(
            setup: { dir in
                try AmendFixture.twoCommits(dir)
                try AmendFixture.git(["reflog", "expire", "--expire=all", "--all"], in: dir)
            },
            gitArgs: ["-m", "after expiry"], amend: { repo, env in
                try repo.amendDetailed(message: "after expiry\n", env: env)
            })
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
        // The merge is reported before an unknown commit.cleanup.
        try AmendFixture.git(["config", "commit.cleanup", "bogus"], in: dir)
        let bogus = try AmendFixture.run(["commit", "--amend", "-m", "x"], in: dir)
        #expect(bogus.err == "fatal: \(CommitAmendError.mergeInProgress)\n")
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

// Where the old message and the reflogs come from.
extension RepositoryAmendTests {

    @Test("--no-edit --cleanup=verbatim skips the old message's leading blank lines, as git does")
    func verbatimKeptMessage() throws {
        try AmendFixture.expectSameRepos(
            setup: { dir in
                try AmendFixture.twoCommits(dir)
                try AmendFixture.git(
                    ["commit", "-q", "--amend", "--cleanup=verbatim", "-m", "\n  \n\t\nsubject  \n\n\nbody\n"], in: dir)
            },
            gitArgs: ["--no-edit", "--cleanup=verbatim"], amend: { repo, env in
                try repo.amendDetailed(cleanup: .verbatim, env: env)
            })
    }

    @Test("in a linked worktree, an emptied branch reflog is restamped in the common dir")
    func linkedWorktreeExpiredReflog() throws {
        let viaGit = try AmendFixture.makeRepo()
        let viaKit = try AmendFixture.makeRepo()
        defer {
            try? FileManager.default.removeItem(at: viaGit)
            try? FileManager.default.removeItem(at: viaKit)
        }
        for dir in [viaGit, viaKit] {
            try AmendFixture.twoCommits(dir)
            try AmendFixture.git(["worktree", "add", "-q", "-b", "side", "wt"], in: dir)
            try AmendFixture.git(["reflog", "expire", "--expire=all", "--all"], in: dir)
        }
        let env = ["GIT_COMMITTER_DATE": AmendFixture.commitDate]
        let wtGit = viaGit.appendingPathComponent("wt")
        let wtKit = viaKit.appendingPathComponent("wt")
        let amended = try AmendFixture.run(["commit", "-q", "--amend", "-m", "in worktree"], in: wtGit, env: env)
        #expect(amended.status == 0, "git failed: \(amended.err)")
        try Repository.open(at: wtKit).amendDetailed(message: "in worktree\n", env: env)
        #expect(try AmendFixture.git(["rev-parse", "HEAD"], in: wtKit)
            == AmendFixture.git(["rev-parse", "HEAD"], in: wtGit))
        for log in [".git/worktrees/wt/logs/HEAD", ".git/logs/refs/heads/side"] {
            let kitLog = FileManager.default.contents(atPath: viaKit.appendingPathComponent(log).path)
            let gitLog = FileManager.default.contents(atPath: viaGit.appendingPathComponent(log).path)
            #expect(kitLog != nil)
            #expect(kitLog == gitLog, "\(log) differs")
        }
    }

    @Test("a reflog left discontinuous by git reflog delete gets the amend under the committer")
    func discontinuousReflog() throws {
        try AmendFixture.expectSameRepos(
            setup: { dir in
                try AmendFixture.twoCommits(dir)
                try AmendFixture.git(["reflog", "delete", "HEAD@{0}"], in: dir)
                try AmendFixture.git(["reflog", "delete", "refs/heads/main@{0}"], in: dir)
            },
            gitArgs: ["-m", "after delete"], amend: { repo, env in
                try repo.amendDetailed(message: "after delete\n", env: env)
            })
    }

    @Test("a given message gets its last line ended, as -m does, even verbatim")
    func verbatimGivenMessage() throws {
        for message in ["x", "x\n\ny  "] {
            try AmendFixture.expectSameRepos(
                setup: AmendFixture.twoCommits, gitArgs: ["--cleanup=verbatim", "-m", message]) { repo, env in
                    try repo.amendDetailed(message: message, cleanup: .verbatim, env: env)
                }
        }
    }

    @Test("an empty or multi-line comment string is refused first, as git does")
    func invalidCommentString() throws {
        let cases: [(key: String, value: String, empty: Bool)] = [
            ("core.commentString", "", true), ("core.commentChar", "", true), ("core.commentChar", "a\nb", false)
        ]
        for (key, value, empty) in cases {
            for unborn in [false, true] {
                let dir = try AmendFixture.makeRepo()
                defer { try? FileManager.default.removeItem(at: dir) }
                if !unborn { try AmendFixture.twoCommits(dir) }
                try AmendFixture.git(["config", key, value], in: dir)
                let error = CommitAmendError.invalidCommentString(key: key.lowercased(), empty: empty)
                let git = try AmendFixture.run(["commit", "--amend", "-m", "x"], in: dir)
                #expect(git.status == 128)
                #expect(git.err.hasPrefix("error: \(error)\nfatal: bad config variable '\(key.lowercased())'"))
                #expect(throws: error) { try Repository.open(at: dir).amendDetailed(message: "x\n") }
            }
        }
    }

    @Test("the ref and reflog locks taken to restamp are all released")
    func reflogLocksReleased() throws {
        let dir = try AmendFixture.makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try AmendFixture.twoCommits(dir)
        let details = try Repository.open(at: dir).amendDetailed(message: "locked\n")
        let entry = try #require(try Repository.open(at: dir).reflog(refName: "refs/heads/main").first)
        #expect(entry.newSHA == details.sha)
        let git = dir.appendingPathComponent(".git")
        let leftovers = FileManager.default.enumerator(atPath: git.path)?
            .compactMap { $0 as? String }.filter { $0.hasSuffix(".lock") } ?? []
        #expect(leftovers.isEmpty)
    }
}
#endif

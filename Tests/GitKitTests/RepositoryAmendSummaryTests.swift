// Integration tests that fork the system `git` via `Process` for parity
// checks — gated to macOS/Linux like the other `git`-driven suites.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

// The amended commit's summary (renames) and object (extra headers).
extension RepositoryAmendTests {

    @Test("renames are found for the summary, as git finds them, even with diff.renames=false")
    func renamesInSummary() throws {
        let details = try AmendFixture.expectParity(
            setup: { dir in
                try AmendFixture.twoCommits(dir)
                try AmendFixture.git(["config", "diff.renames", "false"], in: dir)
                try FileManager.default.createDirectory(
                    at: dir.appendingPathComponent("d"), withIntermediateDirectories: true)
                let lines = (1...20).map { "line \($0)\n" }.joined()
                try AmendFixture.write(lines, to: "d/a", in: dir)
                try AmendFixture.write(lines + "more\n", to: "b", in: dir)
                try AmendFixture.git(["add", "d/a", "b"], in: dir)
                try AmendFixture.git(["commit", "-q", "-m", "files"], in: dir)
                try AmendFixture.git(["mv", "d/a", "d/z"], in: dir)
                try AmendFixture.git(["commit", "-q", "-m", "moves"], in: dir)
                // Amended in: the rename gains a new mode, and next to it
                // come a rename with an edit and a plain addition.
                try AmendFixture.git(["update-index", "--chmod=+x", "d/z"], in: dir)
                try AmendFixture.git(["mv", "b", "b2"], in: dir)
                try AmendFixture.write(lines + "changed\n", to: "b2", in: dir)
                try AmendFixture.git(["add", "b2"], in: dir)
                try AmendFixture.write("new\n", to: "n", in: dir)
                try AmendFixture.git(["add", "n"], in: dir)
            },
            gitArgs: ["--no-edit"], subject: "moves", amend: { repo, env in
                try repo.amendDetailed(env: env)
            })
        #expect(details.renamedFiles.map(\.newPath) == ["b2", "d/z"])
        #expect(details.renamedFiles.map { $0.name() } == ["b => b2", "d/{a => z}"])
        #expect(details.deletedFiles.isEmpty)
        #expect(details.addedFiles.map(\.path) == ["n"])
    }

    @Test("a plain commit's summary finds renames too")
    func commitSummaryRenames() throws {
        let dir = try AmendFixture.makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try AmendFixture.twoCommits(dir)
        try AmendFixture.git(["mv", "g", "h"], in: dir)
        let details = try Repository.open(at: dir).commitDetailed(message: "move\n", author: nil, allowEmpty: false)
        #expect(details.filesChanged == 1)
        #expect(details.insertions == 0 && details.deletions == 0)
        #expect(details.addedFiles.isEmpty && details.deletedFiles.isEmpty)
        #expect(details.renamedFiles.map { "\($0.name()) (\($0.similarity)%)" } == ["g => h (100%)"])
    }

    @Test("rename percentages and the 50% threshold are git's, for small, CRLF and long-line files")
    func renameSimilarity() throws {
        let long = String(repeating: "abcdefghij", count: 30)
        struct Move {
            let old: String, new: String, before: String, after: String
        }
        let files = [
            Move(old: "tiny", new: "tiny2", before: "x\n", after: "x\ny\n"),
            Move(old: "crlf", new: "crlf2", before: "one\r\ntwo\r\nthree\r\nfour\r\n",
                 after: "one\r\ntwo\r\nthree\r\nfive\r\n"),
            Move(old: "far", new: "far2", before: "1\n2\n3\n4\n5\n6\n", after: "1\n2\nq\nw\ne\nr\nt\n"),
            Move(old: "long", new: "long2", before: long + "\nend\n", after: long + "X\nend\n")
        ]
        try AmendFixture.expectParity(
            setup: { dir in
                try AmendFixture.twoCommits(dir)
                for file in files { try AmendFixture.write(file.before, to: file.old, in: dir) }
                try AmendFixture.git(["add", "."], in: dir)
                try AmendFixture.git(["commit", "-q", "-m", "files"], in: dir)
                try AmendFixture.git(["commit", "-q", "--allow-empty", "-m", "moves"], in: dir)
                for file in files {
                    try AmendFixture.git(["rm", "-q", file.old], in: dir)
                    try AmendFixture.write(file.after, to: file.new, in: dir)
                    try AmendFixture.git(["add", file.new], in: dir)
                }
            },
            gitArgs: ["--no-edit"], subject: "moves", amend: { repo, env in
                try repo.amendDetailed(env: env)
            })
    }

    @Test("extra headers like mergetag are kept, the old signature dropped, as git does")
    func extraHeaders() throws {
        try AmendFixture.expectParity(
            setup: { dir in
                try AmendFixture.twoCommits(dir)
                let tree = try AmendFixture.git(["rev-parse", "HEAD^{tree}"], in: dir).dropLast()
                let parent = try AmendFixture.git(["rev-parse", "HEAD^"], in: dir).dropLast()
                let object = """
                    tree \(tree)
                    parent \(parent)
                    author T <t@e.com> 1767258000 +0100
                    committer T <t@e.com> 1767258000 +0100
                    mergetag object \(parent)
                     type commit
                     tag v1
                     tagger T <t@e.com> 1767258000 +0100
                    \u{20}
                     signed tag
                    gpgsig -----BEGIN PGP SIGNATURE-----
                    \u{20}
                     not a real signature
                     -----END PGP SIGNATURE-----
                    x-extra kept too

                    second

                    """
                try AmendFixture.write(object, to: "object", in: dir)
                let sha = try AmendFixture.git(["hash-object", "-t", "commit", "-w", "object"], in: dir).dropLast()
                try FileManager.default.removeItem(at: dir.appendingPathComponent("object"))
                try AmendFixture.git(["update-ref", "HEAD", String(sha)], in: dir)
            },
            gitArgs: ["-m", "tagged"], subject: "tagged",
            after: { _, viaKit in
                let object = try AmendFixture.git(["cat-file", "commit", "HEAD"], in: viaKit)
                #expect(object.contains("\nmergetag object ") && object.contains("\n signed tag\n"))
                #expect(object.contains("\nx-extra kept too\n"))
                #expect(!object.contains("gpgsig"))
            },
            amend: { repo, env in
                try repo.amendDetailed(message: "tagged\n", env: env)
            })
    }

    @Test("with no identity configured, the committer from env moves the ref and is logged")
    func identityFromEnvOnly() throws {
        try AmendFixture.expectSameRepos(
            setup: { dir in
                try AmendFixture.twoCommits(dir)
                // Empty values override any global identity: none is left.
                try AmendFixture.git(["config", "user.name", ""], in: dir)
                try AmendFixture.git(["config", "user.email", ""], in: dir)
            },
            gitArgs: ["-m", "from env"],
            env: ["GIT_COMMITTER_NAME": "Env Committer", "GIT_COMMITTER_EMAIL": "env@example.com"],
            after: { _, viaKit in
                let line = try AmendFixture.lastLine(of: ".git/logs/HEAD", in: viaKit)
                #expect(line.contains(" Env Committer <env@example.com> 1770026400 +0100\t"))
            },
            amend: { repo, env in
                try repo.amendDetailed(message: "from env\n", env: env)
            })
    }
}
#endif

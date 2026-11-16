#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

@Suite("Merge and rebase object parity with git")
struct MergeRebaseParityTests {
    private let fixtures = TemporaryRepositories()
    private static let environment = [
        "GIT_AUTHOR_NAME": "Author", "GIT_AUTHOR_EMAIL": "author@example.com",
        "GIT_AUTHOR_DATE": "1770026400 +0530",
        "GIT_COMMITTER_NAME": "Committer", "GIT_COMMITTER_EMAIL": "committer@example.com",
        "GIT_COMMITTER_DATE": "1770030000 -0230", "GIT_EDITOR": "true"
    ]

    private func twin(_ dir: URL) throws -> URL {
        let other = fixtures.url("parity-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: dir, to: other)
        return other
    }

    @discardableResult
    private func git(_ args: [String], in dir: URL, success: Bool = true) throws -> String {
        let result = try AmendFixture.run(args, in: dir, env: Self.environment)
        #expect((result.status == 0) == success, "git \(args): \(result.err)")
        return result.out
    }

    private func expectParity(_ dir: URL, _ other: URL, rebased: Bool = false) throws {
        let revisions = rebased ? ["HEAD", "HEAD^"] : ["HEAD"]
        for rev in revisions {
            #expect(try git(["rev-parse", rev], in: dir) == git(["rev-parse", rev], in: other))
            let actual = try git(["cat-file", "commit", rev], in: dir)
            let expected = try git(["cat-file", "commit", rev], in: other)
            #expect(actual == expected)
        }
        let branch = rebased ? "side" : "main"
        for ref in ["HEAD", "refs/heads/\(branch)"] {
            let line = try AmendFixture.lastLine(of: ".git/logs/\(ref)", in: dir)
            #expect(line.contains(" Committer <committer@example.com> 1770030000 -0230\t"))
        }
    }

    @Test("merge --no-ff and merge -m match git at fixed dates", arguments: [true, false])
    func merge(noFastForward: Bool) throws {
        defer { fixtures.removeAll() }
        let dir = try AmendFixture.makeRepo(in: fixtures)
        try OperationSigningFixture.forked(dir)
        if noFastForward { try AmendFixture.git(["reset", "--hard", "side^"], in: dir) }
        let other = try twin(dir)
        let message = noFastForward ? nil : "Custom merge"
        _ = try Repository.open(at: dir).merge(ref: "side", fastForward: noFastForward ? .never : .auto,
                                              message: message, env: Self.environment)
        try git(["merge", "--no-edit"] + (noFastForward ? ["--no-ff"] : ["-m", "Custom merge"]) + ["side"],
                in: other)
        try expectParity(dir, other)
    }

    @Test("two rebased commits retain their authors and take the environment committer")
    func rebase() throws {
        defer { fixtures.removeAll() }
        let dir = try AmendFixture.makeRepo(in: fixtures)
        try OperationSigningFixture.forked(dir, extra: 1)
        try AmendFixture.git(["checkout", "side"], in: dir)
        let other = try twin(dir)
        _ = try Repository.open(at: dir).rebase(upstream: "main", env: Self.environment)
        try git(["rebase", "main"], in: other)
        try expectParity(dir, other, rebased: true)
    }

    @Test("a fast-forward records the environment committer in the reflog")
    func fastForward() throws {
        defer { fixtures.removeAll() }
        let dir = try AmendFixture.makeRepo(in: fixtures)
        try OperationSigningFixture.forked(dir)
        try AmendFixture.git(["reset", "--hard", "side^"], in: dir)
        let other = try twin(dir)
        guard case .fastForward = try Repository.open(at: dir).merge(ref: "side", env: Self.environment) else {
            Issue.record("expected a fast-forward"); return
        }
        try git(["merge", "side"], in: other)
        try expectParity(dir, other)
    }

    @Test("a fast-forward needs no configured identity")
    func fastForwardWithoutIdentity() throws {
        defer { fixtures.removeAll() }
        let dir = try AmendFixture.makeRepo(in: fixtures)
        try OperationSigningFixture.forked(dir)
        try AmendFixture.git(["reset", "--hard", "side^"], in: dir)
        try AmendFixture.git(["config", "--unset", "user.name"], in: dir)
        try AmendFixture.git(["config", "--unset", "user.email"], in: dir)
        try AmendFixture.git(["config", "core.logAllRefUpdates", "false"], in: dir)

        guard case .fastForward = try Repository.open(at: dir).merge(
            ref: "side", fastForward: .onlyFastForward, env: [:]
        ) else {
            Issue.record("expected a fast-forward"); return
        }
        #expect(try git(["rev-parse", "HEAD"], in: dir) == git(["rev-parse", "side"], in: dir))
    }

    @Test("rebase continue and skip take the current environment", arguments: [true, false])
    func resumeRebase(skip: Bool) throws {
        defer { fixtures.removeAll() }
        let dir = try AmendFixture.makeRepo(in: fixtures)
        try OperationSigningFixture.forked(dir, conflicting: true, extra: 1)
        try AmendFixture.git(["checkout", "side"], in: dir)
        let other = try twin(dir)
        guard case .conflict = try Repository.open(at: dir).rebase(upstream: "main") else {
            Issue.record("expected a rebase conflict"); return
        }
        try git(["rebase", "main"], in: other, success: false)
        if skip {
            _ = try Repository.open(at: dir).rebaseSkip(env: Self.environment)
            try git(["rebase", "--skip"], in: other)
        } else {
            for url in [dir, other] {
                try AmendFixture.write("resolved\n", to: "c", in: url)
                try AmendFixture.git(["add", "c"], in: url)
            }
            _ = try Repository.open(at: dir).rebaseContinue(env: Self.environment)
            try git(["rebase", "--continue"], in: other)
        }
        try expectParity(dir, other, rebased: true)
    }

    private func tag(_ name: String, target: String, signed: Bool, in dir: URL) throws {
        var options: [String] = []
        if signed {
            let key = try SigningFixture.generateKey(in: fixtures.directory("key-\(UUID().uuidString)"))
            options = ["-c", "gpg.format=ssh", "-c", "user.signingkey=\(key.path)"]
        }
        try AmendFixture.git(options + ["tag", signed ? "-s" : "-a", name, target,
                                       "-m", "Tag message\n\nSecond paragraph"], in: dir)
    }

    @Test("mergetags retain UTF-8 and blank lines and normalize the final LF like git", arguments: [true, false])
    func rawTag(finalNewline: Bool) throws {
        defer { fixtures.removeAll() }
        let dir = try AmendFixture.makeRepo(in: fixtures)
        try OperationSigningFixture.forked(dir)
        let target = try OperationSigningFixture.rev("side", in: dir)
        let header = "object \(target)\ntype commit\ntag raw\ntagger T <t@e.com> 1767258000 +0100\n\n"
        let armor = "\n-----BEGIN PGP SIGNATURE-----\nopaque\n-----END PGP SIGNATURE-----"
        let bytes = Array((header + "é\n" + armor).utf8) + (finalNewline ? [10] : [])
        try Data(bytes).write(to: dir.appendingPathComponent(".git/raw-tag"))
        let oid = try AmendFixture.git(["hash-object", "-w", "-t", "tag", ".git/raw-tag"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let other = try twin(dir)
        _ = try Repository.open(at: dir).merge(ref: oid, fastForward: .never,
                                              message: "Raw tag", env: Self.environment)
        try git(["merge", "--no-ff", "-m", "Raw tag", oid], in: other)
        try expectParity(dir, other)
    }

    @Test("annotated tag merges match git", .enabled(if: SigningFixture.sshKeygenAvailable),
          arguments: [true, false])
    func annotatedTag(signed: Bool) throws {
        defer { fixtures.removeAll() }
        let dir = try AmendFixture.makeRepo(in: fixtures)
        try OperationSigningFixture.forked(dir)
        try tag("release", target: "side", signed: signed, in: dir)
        let other = try twin(dir)
        _ = try Repository.open(at: dir).merge(ref: "release", fastForward: .never,
            message: "Merge release", env: Self.environment)
        try git(["merge", "--no-ff", "-m", "Merge release", "release"], in: other)
        try expectParity(dir, other)
        #expect(try git(["cat-file", "commit", "HEAD"], in: dir).contains("\nmergetag ") == signed)
    }

    @Test("tag objects survive a conflicted merge and reopening", .enabled(if: SigningFixture.sshKeygenAvailable),
          arguments: [true, false])
    func tagContinue(startWithGit: Bool) throws {
        defer { fixtures.removeAll() }
        let dir = try AmendFixture.makeRepo(in: fixtures)
        try OperationSigningFixture.forked(dir, conflicting: true)
        try tag("release", target: "side", signed: true, in: dir)
        let other = try twin(dir)
        if startWithGit {
            try git(["merge", "--no-ff", "-m", "Merge release", "release"], in: dir, success: false)
        } else {
            guard case .conflicts = try Repository.open(at: dir).merge(ref: "release") else {
                Issue.record("expected merge conflicts"); return
            }
        }
        try git(["merge", "--no-ff", "-m", "Merge release", "release"], in: other, success: false)
        #expect(try git(["rev-parse", "release"], in: dir)
            == String(contentsOf: dir.appendingPathComponent(".git/MERGE_HEAD"), encoding: .utf8))
        for url in [dir, other] {
            try AmendFixture.write("resolved\n", to: "c", in: url)
            try AmendFixture.git(["add", "c"], in: url)
        }
        _ = try Repository.open(at: dir).mergeContinue(message: "Merge release\n", env: Self.environment)
        try git(["commit", "-m", "Merge release"], in: other)
        try expectParity(dir, other)
    }

    @Test("octopus retains signed tags in head order", .enabled(if: SigningFixture.sshKeygenAvailable))
    func octopusTags() throws {
        defer { fixtures.removeAll() }
        let dir = try AmendFixture.makeRepo(in: fixtures)
        try OperationSigningFixture.forked(dir)
        try AmendFixture.git(["checkout", "-b", "third", "side^"], in: dir)
        try OperationSigningFixture.commit("third", ["third": "third\n"], in: dir)
        try AmendFixture.git(["checkout", "main"], in: dir)
        try tag("release", target: "side", signed: true, in: dir)
        try tag("another", target: "third", signed: true, in: dir)
        let other = try twin(dir)
        _ = try Repository.open(at: dir).octopusMerge(heads: ["release", "another"], noFastForward: true,
            message: "Merge releases", env: Self.environment)
        try git(["merge", "--no-ff", "-m", "Merge releases", "release", "another"], in: other)
        try expectParity(dir, other)
    }

    @Test("a conflicted octopus retains its tag for mergeContinue", .enabled(if: SigningFixture.sshKeygenAvailable))
    func octopusTagContinue() throws {
        defer { fixtures.removeAll() }
        let dir = try AmendFixture.makeRepo(in: fixtures)
        try OperationSigningFixture.forked(dir, conflicting: true)
        try AmendFixture.git(["checkout", "-b", "third", "side^"], in: dir)
        try OperationSigningFixture.commit("third", ["third": "third\n"], in: dir)
        try AmendFixture.git(["checkout", "main"], in: dir)
        try tag("release", target: "side", signed: true, in: dir)
        let other = try twin(dir)
        let result = try Repository.open(at: dir).octopusMerge(heads: ["third", "release"],
            noFastForward: true, message: "Merge release", env: Self.environment)
        guard case .conflicts = result.outcome else { Issue.record("expected octopus conflicts"); return }
        try git(["merge", "--no-ff", "-m", "Merge release", "third", "release"], in: other, success: false)
        for url in [dir, other] {
            try AmendFixture.write("resolved\n", to: "c", in: url)
            try AmendFixture.git(["add", "c"], in: url)
        }
        _ = try Repository.open(at: dir).mergeContinue(message: "Merge release\n", env: Self.environment)
        try git(["commit", "-m", "Merge release"], in: other)
        try expectParity(dir, other)
    }
}
#endif

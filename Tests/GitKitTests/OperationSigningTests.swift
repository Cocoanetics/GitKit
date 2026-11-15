// Signing for every commit path besides `commitDetailed`: merge, octopus,
// cherry-pick, rebase and amend. They fork the system `git` and
// `ssh-keygen`, so they are gated to macOS/Linux like the parity suites.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

/// History shared by the operation suites, built by the `git` CLI.
enum OperationSigningFixture {
    /// `base` on main, then `side` (a commit to `s`, and to `c` when
    /// `conflicting`, followed by `extra` commits) and a commit to `m`
    /// (and `c`) on main, which stays checked out.
    static func forked(_ dir: URL, conflicting: Bool = false, extra: Int = 0) throws {
        try commit("base", ["c": "base\n"], in: dir)
        try AmendFixture.git(["checkout", "-q", "-b", "side"], in: dir)
        try commit("side", conflicting ? ["c": "side\n", "s": "s\n"] : ["s": "s\n"], in: dir)
        for number in 0..<extra { try commit("extra \(number)", ["e\(number)": "e\n"], in: dir) }
        try AmendFixture.git(["checkout", "-q", "main"], in: dir)
        try commit("main", conflicting ? ["c": "main\n", "m": "m\n"] : ["m": "m\n"], in: dir)
    }

    static func commit(_ message: String, _ files: [String: String], in dir: URL) throws {
        for (name, text) in files {
            try AmendFixture.write(text, to: name, in: dir)
            try AmendFixture.git(["add", name], in: dir)
        }
        try AmendFixture.git(["commit", "-q", "--no-gpg-sign", "-m", message], in: dir)
    }

    /// `commit.gpgsign=true` with `key`, and an allowed-signers file so
    /// `git verify-commit` can check the result.
    static func configureSigning(_ dir: URL, key: URL, enabled: Bool = true) throws {
        let publicKey = try String(contentsOf: URL(fileURLWithPath: key.path + ".pub"), encoding: .utf8)
        let allowed = dir.appendingPathComponent(".git/allowed-signers")
        try Data(("t@e.com " + publicKey).utf8).write(to: allowed)
        try AmendFixture.git(["config", "gpg.format", "ssh"], in: dir)
        try AmendFixture.git(["config", "user.signingkey", key.path], in: dir)
        try AmendFixture.git(["config", "gpg.ssh.allowedSignersFile", allowed.path], in: dir)
        try AmendFixture.git(["config", "commit.gpgsign", enabled ? "true" : "false"], in: dir)
    }

    static func rev(_ rev: String, in dir: URL) throws -> String {
        String(try AmendFixture.git(["rev-parse", rev], in: dir).dropLast())
    }

    static func isSigned(_ rev: String, in dir: URL) throws -> Bool {
        try AmendFixture.git(["cat-file", "commit", rev], in: dir).contains("\ngpgsig ")
    }

    /// `rev` passes `git verify-commit` when `signed`, else has no signature.
    static func expectSigned(_ signed: Bool, _ rev: String, in dir: URL,
                             sourceLocation: SourceLocation = #_sourceLocation) throws {
        if signed {
            let verified = try AmendFixture.run(["verify-commit", rev], in: dir)
            #expect(verified.status == 0, "git verify-commit \(rev) failed: \(verified.err)",
                    sourceLocation: sourceLocation)
        } else {
            #expect(try !isSigned(rev, in: dir), "\(rev) is signed", sourceLocation: sourceLocation)
        }
    }

    /// Signs SSH-format with the key it is given, whatever format GitKit
    /// passes for an explicit `-S<key>`, and records the keys asked for.
    final class SSHSigner: GitSigner, @unchecked Sendable {
        var keys: [String?] = []

        func sign(_ payload: [UInt8], request: SigningRequest) throws -> String {
            keys.append(request.key)
            let ssh = SigningRequest(format: .ssh, key: request.key, identity: request.identity)
            return try ExternalProgramSigner().sign(payload, request: ssh)
        }
    }
}

@Suite("Signed merge, octopus, cherry-pick, rebase and amend commits", .serialized,
       .enabled(if: SigningFixture.sshKeygenAvailable))
struct OperationSigningTests {
    typealias Fixture = OperationSigningFixture
    private let fixtures = TemporaryRepositories()

    /// A repository built by `build`, then set to sign with a fresh key.
    private func repository(
        signingEnabled: Bool = true, _ build: (URL) throws -> Void
    ) throws -> (dir: URL, repo: Repository, key: URL) {
        let key = try SigningFixture.generateKey(in: fixtures.directory("keys-\(UUID().uuidString)"))
        let dir = try AmendFixture.makeRepo(in: fixtures)
        try build(dir)
        try Fixture.configureSigning(dir, key: key, enabled: signingEnabled)
        return (dir, try Repository.open(at: dir), key)
    }

    /// `.config` with `commit.gpgsign=true` signs; `.noSign` overrides it.
    private func mode(_ signed: Bool) -> SignMode { signed ? .config : .noSign }

    @Test("merge signs its merge commit", arguments: [true, false])
    func merge(signed: Bool) throws {
        CommitSigningTests.signerDefaultsLock.lock()
        defer { CommitSigningTests.signerDefaultsLock.unlock() }
        defer { fixtures.removeAll() }
        let (dir, repo, _) = try repository { try Fixture.forked($0) }
        let outcome = try repo.merge(ref: "side", fastForward: .never, sign: mode(signed))
        guard case .mergeCommit(let sha, _, _, _) = outcome else {
            Issue.record("expected a merge commit, got \(outcome)"); return
        }
        #expect(try Fixture.rev("HEAD", in: dir) == sha)
        #expect(try Fixture.rev("HEAD^2", in: dir) == Fixture.rev("side", in: dir))
        try Fixture.expectSigned(signed, "HEAD", in: dir)
    }

    @Test("mergeContinue signs the concluded merge", arguments: [true, false])
    func mergeContinue(signed: Bool) throws {
        CommitSigningTests.signerDefaultsLock.lock()
        defer { CommitSigningTests.signerDefaultsLock.unlock() }
        defer { fixtures.removeAll() }
        let (dir, repo, _) = try repository { try Fixture.forked($0, conflicting: true) }
        guard case .conflicts = try repo.merge(ref: "side") else {
            Issue.record("expected conflicts"); return
        }
        try AmendFixture.write("resolved\n", to: "c", in: dir)
        try repo.add(paths: [])
        let details = try repo.mergeContinue(env: SigningFixture.environment, sign: mode(signed))
        #expect(try Fixture.rev("HEAD", in: dir) == details.sha)
        try Fixture.expectSigned(signed, "HEAD", in: dir)
    }

    @Test("octopusMerge signs its merge commit", arguments: [true, false])
    func octopusMerge(signed: Bool) throws {
        CommitSigningTests.signerDefaultsLock.lock()
        defer { CommitSigningTests.signerDefaultsLock.unlock() }
        defer { fixtures.removeAll() }
        let (dir, repo, _) = try repository { dir in
            try Fixture.commit("base", ["c": "base\n"], in: dir)
            for branch in ["a", "b"] {
                try AmendFixture.git(["checkout", "-q", "-b", branch, "main"], in: dir)
                try Fixture.commit(branch, [branch: "\(branch)\n"], in: dir)
            }
            try AmendFixture.git(["checkout", "-q", "main"], in: dir)
            try Fixture.commit("main", ["m": "m\n"], in: dir)
        }
        let result = try repo.octopusMerge(heads: ["a", "b"], message: "Merge branches 'a' and 'b'",
                                           env: SigningFixture.environment, sign: mode(signed))
        guard case .mergeCommit(let sha, _, _, _, _) = result.outcome else {
            Issue.record("expected a merge commit, got \(result.outcome)"); return
        }
        #expect(try Fixture.rev("HEAD", in: dir) == sha)
        #expect(try Fixture.rev("HEAD^3", in: dir) == Fixture.rev("b", in: dir))
        let reflog = try AmendFixture.lastLine(of: ".git/logs/refs/heads/main", in: dir)
        #expect(reflog.hasSuffix("\tmerge: Merge made by the 'octopus' strategy."))
        try Fixture.expectSigned(signed, "HEAD", in: dir)
    }

    @Test("cherryPick signs the picked commit", arguments: [true, false])
    func cherryPick(signed: Bool) throws {
        CommitSigningTests.signerDefaultsLock.lock()
        defer { CommitSigningTests.signerDefaultsLock.unlock() }
        defer { fixtures.removeAll() }
        let (dir, repo, _) = try repository { try Fixture.forked($0) }
        let outcome = try repo.cherryPick("side", env: SigningFixture.environment, sign: mode(signed))
        guard case .completed(let sha, _, _, _, _, _, _, _) = outcome else {
            Issue.record("expected a commit, got \(outcome)"); return
        }
        #expect(try Fixture.rev("HEAD", in: dir) == sha)
        try Fixture.expectSigned(signed, "HEAD", in: dir)
    }

    @Test("cherryPickContinue signs the resolved commit", arguments: [true, false])
    func cherryPickContinue(signed: Bool) throws {
        CommitSigningTests.signerDefaultsLock.lock()
        defer { CommitSigningTests.signerDefaultsLock.unlock() }
        defer { fixtures.removeAll() }
        let (dir, repo, _) = try repository { try Fixture.forked($0, conflicting: true) }
        guard case .conflict = try repo.cherryPick("side", env: SigningFixture.environment) else {
            Issue.record("expected a conflict"); return
        }
        try AmendFixture.write("resolved\n", to: "c", in: dir)
        try repo.add(paths: [])
        let outcome = try repo.cherryPickContinue(env: SigningFixture.environment, sign: mode(signed))
        guard case .completed(let sha, _, _, _, _, _, _, _) = outcome else {
            Issue.record("expected a commit, got \(outcome)"); return
        }
        #expect(try Fixture.rev("HEAD", in: dir) == sha)
        try Fixture.expectSigned(signed, "HEAD", in: dir)
    }

    @Test("rebase signs every replayed commit", arguments: [true, false])
    func rebase(signed: Bool) throws {
        CommitSigningTests.signerDefaultsLock.lock()
        defer { CommitSigningTests.signerDefaultsLock.unlock() }
        defer { fixtures.removeAll() }
        let (dir, _, _) = try repository { dir in
            try Fixture.forked(dir, extra: 1)
            try AmendFixture.git(["checkout", "-q", "side"], in: dir)
        }
        let outcome = try Repository.open(at: dir).rebase(upstream: "main", sign: mode(signed))
        guard case .completed(_, let applied) = outcome else {
            Issue.record("expected a completed rebase, got \(outcome)"); return
        }
        #expect(applied == 2)
        #expect(try Fixture.rev("HEAD~2", in: dir) == Fixture.rev("main", in: dir))
        try Fixture.expectSigned(signed, "HEAD", in: dir)
        try Fixture.expectSigned(signed, "HEAD~1", in: dir)
    }

    @Test("a signed rebase keeps a message in another encoding byte for byte")
    func rebaseKeepsMessageBytes() throws {
        CommitSigningTests.signerDefaultsLock.lock()
        defer { CommitSigningTests.signerDefaultsLock.unlock() }
        defer { fixtures.removeAll() }
        // "café" in ISO-8859-1: 0xE9 is not valid UTF-8 on its own.
        let message: [UInt8] = Array("caf".utf8) + [0xE9, 0x0A]
        let (dir, repo, _) = try repository { dir in
            try Fixture.forked(dir)
            try AmendFixture.git(["checkout", "-q", "side"], in: dir)
            try AmendFixture.write("latin\n", to: "l", in: dir)
            try AmendFixture.git(["add", "l"], in: dir)
            let file = dir.appendingPathComponent(".git/latin-message")
            try Data(message).write(to: file)
            try AmendFixture.git(["-c", "i18n.commitEncoding=ISO-8859-1", "commit", "-q", "--no-gpg-sign",
                                  "-F", file.path], in: dir)
        }
        guard case .completed = try repo.rebase(upstream: "main") else {
            Issue.record("expected a completed rebase"); return
        }
        var oid = git_oid()
        try check(git_oid_fromstr(&oid, Fixture.rev("HEAD", in: dir)))
        var odb: OpaquePointer?
        try check(git_repository_odb(&odb, repo.pointer))
        defer { git_odb_free(odb) }
        var object: OpaquePointer?
        try check(git_odb_read(&object, odb, &oid))
        defer { git_odb_object_free(object) }
        let raw = Array(UnsafeRawBufferPointer(start: git_odb_object_data(object), count: git_odb_object_size(object)))
        let text = String(decoding: raw, as: UTF8.self)
        #expect(text.contains("\nencoding ISO-8859-1\n"))
        #expect(Array(raw.suffix(message.count + 1)) == [0x0A] + message)
        try Fixture.expectSigned(true, "HEAD", in: dir)
    }

    @Test("rebaseContinue and rebaseSkip sign the commits they replay, and keep --no-gpg-sign",
          arguments: [true, false], [false, true])
    func rebaseResume(signed: Bool, skip: Bool) throws {
        CommitSigningTests.signerDefaultsLock.lock()
        defer { CommitSigningTests.signerDefaultsLock.unlock() }
        defer { fixtures.removeAll() }
        let (dir, _, _) = try repository { dir in
            try Fixture.forked(dir, conflicting: true, extra: 1)
            try AmendFixture.git(["checkout", "-q", "side"], in: dir)
        }
        guard case .conflict = try Repository.open(at: dir).rebase(upstream: "main", sign: mode(signed)) else {
            Issue.record("expected a conflict"); return
        }
        // Resumed with the default: the start's --no-gpg-sign still applies.
        let repo = try Repository.open(at: dir)
        let outcome: RebaseOutcome
        if skip {
            outcome = try repo.rebaseSkip()
        } else {
            try AmendFixture.write("resolved\n", to: "c", in: dir)
            try repo.add(paths: [])
            outcome = try repo.rebaseContinue()
        }
        guard case .completed = outcome else {
            Issue.record("expected a completed rebase, got \(outcome)"); return
        }
        try Fixture.expectSigned(signed, "HEAD", in: dir)
        if skip {
            #expect(try Fixture.rev("HEAD~1", in: dir) == Fixture.rev("main", in: dir))
        } else {
            try Fixture.expectSigned(signed, "HEAD~1", in: dir)
            #expect(try Fixture.rev("HEAD~2", in: dir) == Fixture.rev("main", in: dir))
        }
    }

    @Test("an explicit -S<key> rebase survives a reopened repository in gpg_sign_opt",
          arguments: [false, true])
    func explicitKeyRebase(skip: Bool) throws {
        defer { fixtures.removeAll() }
        let (dir, repo, key) = try repository(signingEnabled: false) { dir in
            try Fixture.forked(dir, conflicting: true, extra: 1)
            try AmendFixture.git(["checkout", "-q", "side"], in: dir)
        }
        let signer = Fixture.SSHSigner()
        repo.setSigner(signer)
        guard case .conflict = try repo.rebase(upstream: "main", sign: .sign(keyID: key.path)) else {
            Issue.record("expected a conflict"); return
        }
        // Stored as git stores `-S<key>`.
        #expect(try String(contentsOf: dir.appendingPathComponent(".git/rebase-merge/gpg_sign_opt"),
                           encoding: .utf8) == "-S\(key.path)\n")

        let reopened = try Repository.open(at: dir)
        reopened.setSigner(signer)
        let outcome: RebaseOutcome
        if skip {
            outcome = try reopened.rebaseSkip()
        } else {
            try AmendFixture.write("resolved\n", to: "c", in: dir)
            try reopened.add(paths: [])
            outcome = try reopened.rebaseContinue()
        }
        guard case .completed = outcome else {
            Issue.record("expected a completed rebase, got \(outcome)"); return
        }
        #expect(signer.keys == Array(repeating: key.path, count: skip ? 1 : 2))
        try Fixture.expectSigned(true, "HEAD", in: dir)
        if !skip { try Fixture.expectSigned(true, "HEAD~1", in: dir) }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git/rebase-merge").path))
    }

    @Test("an explicit override on continue wins over the stored choice")
    func continueOverride() throws {
        defer { fixtures.removeAll() }
        let (dir, repo, key) = try repository(signingEnabled: false) { dir in
            try Fixture.forked(dir, conflicting: true, extra: 1)
            try AmendFixture.git(["checkout", "-q", "side"], in: dir)
        }
        let signer = Fixture.SSHSigner()
        repo.setSigner(signer)
        guard case .conflict = try repo.rebase(upstream: "main", sign: .sign(keyID: key.path)) else {
            Issue.record("expected a conflict"); return
        }
        try AmendFixture.write("resolved\n", to: "c", in: dir)
        try repo.add(paths: [])
        guard case .completed = try repo.rebaseContinue(sign: .noSign) else {
            Issue.record("expected a completed rebase"); return
        }
        #expect(signer.keys.isEmpty)
        try Fixture.expectSigned(false, "HEAD", in: dir)
        try Fixture.expectSigned(false, "HEAD~1", in: dir)
    }

    @Test("a signed amend matches git commit --amend -S byte for byte, extra headers kept",
          arguments: [true, false])
    func amend(signed: Bool) throws {
        CommitSigningTests.signerDefaultsLock.lock()
        defer { CommitSigningTests.signerDefaultsLock.unlock() }
        defer { fixtures.removeAll() }
        let key = try SigningFixture.generateKey(in: fixtures.directory("keys"))
        try AmendFixture.expectParity(
            setup: { dir in
                try AmendFixture.twoCommits(dir)
                let tree = try Fixture.rev("HEAD^{tree}", in: dir)
                let parent = try Fixture.rev("HEAD^", in: dir)
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
                try Fixture.configureSigning(dir, key: key)
            },
            gitArgs: (signed ? [] : ["--no-gpg-sign"]) + ["-m", "tagged"], subject: "tagged",
            after: { _, viaKit in
                let object = try AmendFixture.git(["cat-file", "commit", "HEAD"], in: viaKit)
                #expect(object.contains("\nmergetag object ") && object.contains("\n signed tag\n"))
                #expect(object.contains("\nx-extra kept too\n"))
                #expect(!object.contains("not a real signature"))
                #expect(object.contains("\ngpgsig -----BEGIN SSH SIGNATURE-----\n") == signed)
                try Fixture.expectSigned(signed, "HEAD", in: viaKit)
            },
            amend: { repo, env in
                try repo.amendDetailed(message: "tagged\n", env: env, sign: mode(signed))
            })
    }
}

/// A signer that fails must leave HEAD, the branch and their reflogs as
/// they were, and surface its own error rather than libgit2's.
@Suite("A failing signer moves no ref", .serialized)
struct OperationSigningFailureTests {
    typealias Fixture = OperationSigningFixture
    private let fixtures = TemporaryRepositories()

    struct Failing: GitSigner {
        func sign(_ payload: [UInt8], request: SigningRequest) throws -> String {
            throw SigningError.failed(program: "injected", stderr: "cancelled")
        }
    }

    enum Operation: String, CaseIterable, Sendable {
        case merge, mergeContinue, octopusMerge, cherryPick, cherryPickContinue
        case rebase, rebaseContinue, rebaseSkip, amend
    }

    @Test("the signer's error propagates and HEAD stays", arguments: Operation.allCases)
    func failingSigner(operation: Operation) throws {
        defer { fixtures.removeAll() }
        let dir = try AmendFixture.makeRepo(in: fixtures)
        let conflicting = [.mergeContinue, .cherryPickContinue, .rebaseContinue, .rebaseSkip].contains(operation)
        try Fixture.forked(dir, conflicting: conflicting, extra: 1)
        if operation == .octopusMerge {
            try AmendFixture.git(["branch", "other", "side~1"], in: dir)
            try AmendFixture.git(["checkout", "-q", "other"], in: dir)
            try Fixture.commit("other", ["o": "o\n"], in: dir)
            try AmendFixture.git(["checkout", "-q", "main"], in: dir)
        }
        if operation.rawValue.hasPrefix("rebase") { try AmendFixture.git(["checkout", "-q", "side"], in: dir) }
        // Signing is configured on, so `.config` asks the injected signer.
        try AmendFixture.git(["config", "gpg.format", "ssh"], in: dir)
        try AmendFixture.git(["config", "commit.gpgsign", "true"], in: dir)
        let repo = try Repository.open(at: dir)
        repo.setSigner(Failing())
        let env = SigningFixture.environment

        // Conflicted operations stop, unsigned, before the commit to sign.
        switch operation {
        case .mergeContinue:
            _ = try repo.merge(ref: "side")
        case .cherryPickContinue:
            _ = try repo.cherryPick("side~1", env: env)
        case .rebaseContinue, .rebaseSkip:
            _ = try repo.rebase(upstream: "main")
        default: break
        }
        if conflicting, operation != .rebaseSkip {
            try AmendFixture.write("resolved\n", to: "c", in: dir)
            try repo.add(paths: [])
        }
        let head = try Fixture.rev("HEAD", in: dir)
        let branch = try AmendFixture.run(["symbolic-ref", "-q", "HEAD"], in: dir).out
        let branchTip = try Fixture.rev(operation.rawValue.hasPrefix("rebase") ? "side" : "main", in: dir)
        let reflog = try Data(contentsOf: dir.appendingPathComponent(".git/logs/HEAD"))
        let status = try AmendFixture.git(["status", "--porcelain"], in: dir)

        #expect(throws: SigningError.failed(program: "injected", stderr: "cancelled")) {
            switch operation {
            case .merge: _ = try repo.merge(ref: "side", fastForward: .never)
            case .mergeContinue: _ = try repo.mergeContinue(env: env)
            case .octopusMerge: _ = try repo.octopusMerge(heads: ["side", "other"], message: "octopus", env: env)
            case .cherryPick: _ = try repo.cherryPick("side", env: env)
            case .cherryPickContinue: _ = try repo.cherryPickContinue(env: env)
            case .rebase: _ = try repo.rebase(upstream: "main")
            case .rebaseContinue: _ = try repo.rebaseContinue()
            case .rebaseSkip: _ = try repo.rebaseSkip()
            case .amend: _ = try repo.amendDetailed(message: "amended\n", env: env)
            }
        }

        let sideOrMain = operation.rawValue.hasPrefix("rebase") ? "side" : "main"
        #expect(try Fixture.rev(sideOrMain, in: dir) == branchTip)
        switch operation {
        case .rebase, .rebaseSkip:
            // A rebase stays paused where libgit2 left HEAD: on the
            // last commit written, which no signed commit has replaced.
            #expect(try Fixture.rev("HEAD", in: dir) == Fixture.rev("main", in: dir))
        case .merge, .cherryPick:
            #expect(try Fixture.rev("HEAD", in: dir) == head)
            #expect(try AmendFixture.run(["symbolic-ref", "-q", "HEAD"], in: dir).out == branch)
            #expect(try Data(contentsOf: dir.appendingPathComponent(".git/logs/HEAD")) == reflog)
        default:
            #expect(try Fixture.rev("HEAD", in: dir) == head)
            #expect(try AmendFixture.run(["symbolic-ref", "-q", "HEAD"], in: dir).out == branch)
            #expect(try Data(contentsOf: dir.appendingPathComponent(".git/logs/HEAD")) == reflog)
            if operation == .octopusMerge {
                // The checked-out merge is taken back too.
                #expect(try AmendFixture.git(["status", "--porcelain"], in: dir) == status)
            }
        }

        // Turned off per call, the merge left staged needs no signer.
        if operation == .merge || operation == .mergeContinue {
            let details = try repo.mergeContinue(env: env, sign: .noSign)
            #expect(try Fixture.rev("HEAD", in: dir) == details.sha)
            #expect(try Fixture.rev("HEAD^2", in: dir) == Fixture.rev("side", in: dir))
            #expect(try !Fixture.isSigned("HEAD", in: dir))
        }
    }
}
#endif

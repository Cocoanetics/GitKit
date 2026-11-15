// Signed annotated tags. Like AmendFixture, these fork the system `git`
// (and ssh-keygen for parity), so they are gated to macOS/Linux.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

@Suite("Signed annotated tags", .serialized)
struct SignedTagTests {
    private let fixtures = TemporaryRepositories()
    private static let armor = "-----BEGIN SSH SIGNATURE-----\nopaque\n-----END SSH SIGNATURE-----\n"

    private func repository() throws -> (URL, Repository) {
        let dir = try AmendFixture.makeRepo(in: fixtures)
        try AmendFixture.twoCommits(dir)
        let repo = try Repository.open(at: dir)
        try repo.configSet("tag.gpgsign", "true")
        return (dir, repo)
    }

    private func tag(
        _ repo: Repository, _ name: String = "v1", message: String = "signed\n",
        force: Bool = false, sign: SignMode = .config
    ) throws -> String {
        try repo.tagCreateAnnotated(name: name, message: message, force: force,
                                    env: SigningFixture.environment, sign: sign)
    }

    /// Loose and packed objects, as `git count-objects -v` reports them.
    private func objectCount(_ dir: URL) throws -> Int {
        let lines = try AmendFixture.git(["count-objects", "-v"], in: dir).split(separator: "\n")
        return lines.compactMap { line -> Int? in
            let parts = line.split(separator: " ")
            guard parts.count == 2, ["count:", "in-pack:"].contains(parts[0]) else { return nil }
            return Int(parts[1])
        }.reduce(0, +)
    }

    @Test("tag.gpgsign signs under .config; the signature follows the message")
    func configSigns() throws {
        defer { fixtures.removeAll() }
        let (dir, repo) = try repository()
        let signer = CommitSigningTests.Signer(Self.armor)
        repo.setSigner(signer)
        try repo.configSet("user.signingkey", "~/key")
        let before = try objectCount(dir)
        _ = try tag(repo, message: "no trailing newline")
        let request = try #require(signer.requests.first)
        #expect(signer.requests.count == 1)
        #expect(request.key == "~/key")
        #expect(request.identity == "T <t@e.com>")
        let head = try AmendFixture.git(["rev-parse", "HEAD"], in: dir)
        let payload = "object \(head)type commit\ntag v1\ntagger T <t@e.com> 1767258000 +0100\n\n"
            + "no trailing newline\n"
        #expect(signer.payloads.first == Array(payload.utf8))
        #expect(try AmendFixture.git(["cat-file", "tag", "v1"], in: dir) == payload + Self.armor)
        let signature = try #require(try repo.tagSignature("v1"))
        #expect(signature.signature == Self.armor)
        #expect(signature.signedPayload == Array(payload.utf8))
        // Only the signed tag object was written: no unsigned twin dangles.
        #expect(try objectCount(dir) == before + 1)
        #expect(try AmendFixture.git(["fsck", "--dangling"], in: dir).isEmpty)
    }

    @Test(".noSign overrides tag.gpgsign; unset config stays unsigned; lightweight tags never sign")
    func unsignedModes() throws {
        defer { fixtures.removeAll() }
        let (dir, repo) = try repository()
        let signer = CommitSigningTests.Signer(Self.armor)
        repo.setSigner(signer)
        let unsigned = try tag(repo, sign: .noSign)
        _ = try repo.tagCreate(name: "light")
        try repo.configSet("tag.gpgsign", "false")
        _ = try tag(repo, "v2")
        #expect(signer.requests.isEmpty)
        #expect(try repo.tagSignature("v1") == nil)
        #expect(try repo.tagSignature("v2") == nil)
        // Unsigned output is unchanged: the same object as `git tag --no-sign`.
        try repo.tagDelete(name: "v1")
        try AmendFixture.git(["tag", "-a", "--no-sign", "-m", "signed", "v1"], in: dir)
        #expect(unsigned + "\n" == (try AmendFixture.git(["rev-parse", "v1"], in: dir)))
        // An explicit key implies signing even with tag.gpgsign off.
        _ = try tag(repo, "v3", sign: .sign(keyID: "explicit"))
        #expect(signer.requests.last?.key == "explicit")
    }

    @Test("a failing signer leaves no object and no ref")
    func signerFailure() throws {
        defer { fixtures.removeAll() }
        let (dir, repo) = try repository()
        let signer = CommitSigningTests.Signer()
        signer.callback = { _, _ in throw SigningError.failed(program: "gpg", stderr: "no key") }
        repo.setSigner(signer)
        let before = try objectCount(dir)
        #expect(throws: SigningError.failed(program: "gpg", stderr: "no key")) { try tag(repo) }
        #expect(signer.requests.count == 1)
        #expect(try !repo.tagExists("v1"))
        #expect(try objectCount(dir) == before)
    }

    @Test("an existing or invalid name fails before the signer runs; force replaces")
    func refusedBeforeSigning() throws {
        defer { fixtures.removeAll() }
        let (_, repo) = try repository()
        let signer = CommitSigningTests.Signer(Self.armor)
        repo.setSigner(signer)
        let first = try tag(repo, sign: .noSign)
        let error = try #require(throws: Libgit2Error.self) { try tag(repo) }
        #expect(error.code == GIT_EEXISTS.rawValue)
        #expect(throws: Libgit2Error.self) { try tag(repo, "bad..name") }
        #expect(signer.requests.isEmpty)
        let replaced = try tag(repo, force: true)
        #expect(replaced != first)
        #expect(signer.requests.count == 1)
        #expect(try repo.tagSignature("v1")?.signature == Self.armor)
    }
}

@Suite("Signed tag git parity", .enabled(if: SigningFixture.sshKeygenAvailable))
struct SignedTagParityTests {
    private let fixtures = TemporaryRepositories()

    @Test("git verify-tag passes and the object matches git tag -s")
    func parity() throws {
        CommitSigningTests.signerDefaultsLock.lock()
        defer { CommitSigningTests.signerDefaultsLock.unlock() }
        defer { fixtures.removeAll() }
        let key = try SigningFixture.generateKey(in: fixtures.directory("keys"))
        let viaGit = try AmendFixture.makeRepo(in: fixtures)
        let viaKit = try AmendFixture.makeRepo(in: fixtures)
        for dir in [viaGit, viaKit] {
            try AmendFixture.twoCommits(dir)
            try AmendFixture.git(["config", "gpg.format", "ssh"], in: dir)
            try AmendFixture.git(["config", "user.signingkey", key.path], in: dir)
            let publicKey = try String(contentsOf: URL(fileURLWithPath: key.path + ".pub"), encoding: .utf8)
            try AmendFixture.write("t@e.com " + publicKey, to: "allowed-signers", in: dir)
            try AmendFixture.git(["config", "gpg.ssh.allowedSignersFile", "allowed-signers"], in: dir)
            try AmendFixture.git(["config", "tag.gpgsign", "true"], in: dir)
        }
        try AmendFixture.git(["tag", "-s", "-m", "signed", "v1"], in: viaGit)
        let repo = try Repository.open(at: viaKit)
        let before = try AmendFixture.git(["count-objects", "-v"], in: viaKit)
        let sha = try repo.tagCreateAnnotated(name: "v1", message: "signed\n", env: SigningFixture.environment)
        #expect(sha + "\n" == (try AmendFixture.git(["rev-parse", "v1"], in: viaGit)))
        let actual = try AmendFixture.git(["cat-file", "tag", "v1"], in: viaKit)
        let expected = try AmendFixture.git(["cat-file", "tag", "v1"], in: viaGit)
        #expect(actual == expected, "GitKit:\n\(actual)\nGit:\n\(expected)")
        let verified = try AmendFixture.run(["verify-tag", "v1"], in: viaKit)
        #expect(verified.status == 0, "git verify-tag failed: \(verified.err)")
        #expect(try AmendFixture.git(["count-objects", "-v"], in: viaKit)
            == (try AmendFixture.git(["count-objects", "-v"], in: viaGit)))
        #expect(before != (try AmendFixture.git(["count-objects", "-v"], in: viaKit)))
        #expect(try AmendFixture.git(["fsck", "--dangling"], in: viaKit).isEmpty)
    }
}
#endif

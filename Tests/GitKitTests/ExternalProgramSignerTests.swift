#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

@Suite("External signing program conventions")
struct ExternalProgramSignerTests {
    private let fixtures = TemporaryRepositories()

    @Test("gpg and gpgsm receive git's argv and payload; SIG_CREATED is required", arguments: [
        SigningFormat.openpgp, .x509
    ])
    func gpgArguments(format: SigningFormat) throws {
        defer { fixtures.removeAll() }
        let dir = try fixtures.directory("gpg")
        let program = try SigningFixture.script("""
            printf '%s\\n' "$@" > args
            cat > input
            printf 'armored signature\\n'
            printf '[GNUPG:] SIG_CREATED D 22 8 00 0 fingerprint\\n' >&2
            """, in: dir)
        let request = SigningRequest(format: format, key: "key-id", identity: "T <t@e.com>",
                                     program: program.path, workingDirectory: dir)
        #expect(try ExternalProgramSigner().sign([0, 255, 10], request: request) == "armored signature\n")
        #expect(try String(contentsOf: dir.appendingPathComponent("args"), encoding: .utf8)
            == "--status-fd=2\n-bsau\nkey-id\n")
        #expect(try Data(contentsOf: dir.appendingPathComponent("input")) == Data([0, 255, 10]))

        let noKey = SigningRequest(format: format, key: nil, identity: "T <t@e.com>",
                                   program: program.path, workingDirectory: dir)
        _ = try ExternalProgramSigner().sign([], request: noKey)
        #expect(try String(contentsOf: dir.appendingPathComponent("args"), encoding: .utf8)
            == "--status-fd=2\n-bsau\nT <t@e.com>\n")

        for body in ["printf 'output without status'", "printf '[GNUPG:] SIG_CREATED x' >&2; exit 1"] {
            let bad = try SigningFixture.script(body, name: "bad", in: dir)
            let request = SigningRequest(format: format, key: nil, identity: "T <t@e.com>", program: bad.path)
            #expect(throws: SigningError.self) { try ExternalProgramSigner().sign([], request: request) }
        }
    }

    @Test("large stdin/stdout/stderr do not deadlock")
    func largeStreams() throws {
        defer { fixtures.removeAll() }
        let dir = try fixtures.directory("large")
        let program = try SigningFixture.script("""
            dd if=/dev/zero bs=1024 count=256 >&2 2>/dev/null
            printf '[GNUPG:] SIG_CREATED x\\n' >&2
            cat
            """, in: dir)
        let payload = [UInt8](repeating: 65, count: 256 * 1024)
        let request = SigningRequest(format: .openpgp, key: nil, identity: "T <t@e.com>", program: program.path)
        #expect(try ExternalProgramSigner().sign(payload, request: request).utf8.count == payload.count)
    }

    @Test("CRLF armor from GPG and SSH is normalized like git")
    func crlfArmor() throws {
        defer { fixtures.removeAll() }
        let dir = try fixtures.directory("crlf")
        let gpg = try SigningFixture.script("""
            cat >/dev/null
            printf 'first\r\nsecond\rstandalone\r\n'
            printf '[GNUPG:] SIG_CREATED x\n' >&2
            """, name: "gpg", in: dir)
        let gpgRequest = SigningRequest(
            format: .openpgp, key: nil, identity: "T <t@e.com>", program: gpg.path)
        #expect(try ExternalProgramSigner().sign([], request: gpgRequest)
            == "first\nsecond\rstandalone\n")

        let ssh = try SigningFixture.script("""
            for last do :; done
            printf 'first\r\nsecond\rstandalone\r\n' > "$last.sig"
            """, name: "ssh-keygen", in: dir)
        let sshRequest = SigningRequest(
            format: .ssh, key: "key", identity: "T <t@e.com>", program: ssh.path)
        #expect(try ExternalProgramSigner().sign([], request: sshRequest)
            == "first\nsecond\rstandalone\n")
    }

    @Test("SSH paths, literal keys and defaultKeyCommand", arguments: [
        "~/key", "relative key", "key::ssh-ed25519 AAAA test", "ssh-ed25519 AAAA test", ""
    ])
    func sshArguments(key: String) throws {
        defer { fixtures.removeAll() }
        let dir = try fixtures.directory("ssh")
        let program = try SigningFixture.script("""
            printf '%s\\n' "$@" > args
            keyfile="$6"
            if [ "$7" = '-U' ]; then cat "$keyfile" > literal; fi
            for last do :; done
            cat "$last" > input
            printf 'ssh armor\\n' > "$last.sig"
            """, in: dir)
        let request = SigningRequest(
            format: .ssh, key: key, identity: "T <t@e.com>", program: program.path,
            defaultKeyCommand: "printf 'ignored\\nkey::ssh-ed25519 AAAA fallback\\n'", workingDirectory: dir)
        #expect(try ExternalProgramSigner().sign(Array("payload".utf8), request: request) == "ssh armor\n")
        let args = try String(contentsOf: dir.appendingPathComponent("args"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(Array(args.prefix(5)) == ["-Y", "sign", "-n", "git", "-f"])
        if key == "~/key" {
            #expect(args[5] == (key as NSString).expandingTildeInPath)
            #expect(args.count == 7)
        } else if key == "relative key" {
            #expect(args[5] == key)
            #expect(args.count == 7)
        } else {
            #expect(args[6] == "-U")
            #expect(args.count == 8)
            let expected = key.isEmpty ? "ssh-ed25519 AAAA fallback" : "ssh-ed25519 AAAA test"
            #expect(try String(contentsOf: dir.appendingPathComponent("literal"), encoding: .utf8) == expected + "\n")
        }
        #expect(try String(contentsOf: dir.appendingPathComponent("input"), encoding: .utf8) == "payload")
        // All key/payload temporaries are removed before returning.
        #expect(!FileManager.default.fileExists(atPath: args[5]) || key == "~/key" || key == "relative key")
    }

    @Test("missing keys, failed key commands, failed programs and missing SSH output")
    func failures() throws {
        defer { fixtures.removeAll() }
        let dir = try fixtures.directory("failures")
        for key in [String?.none, ""] {
            let request = SigningRequest(format: .ssh, key: key, identity: "T <t@e.com>")
            #expect(throws: SigningError.missingKey) { try ExternalProgramSigner().sign([], request: request) }
        }
        let failedCommand = SigningRequest(format: .ssh, key: nil, identity: "T <t@e.com>",
                                           defaultKeyCommand: "printf 'failed command' >&2; exit 1")
        #expect(throws: SigningError.self) { try ExternalProgramSigner().sign([], request: failedCommand) }
        let noKeyCommand = SigningRequest(format: .ssh, key: nil, identity: "T <t@e.com>",
                                          defaultKeyCommand: "printf 'not a key'")
        #expect(throws: SigningError.missingKey) { try ExternalProgramSigner().sign([], request: noKeyCommand) }
        let program = try SigningFixture.script("printf 'diagnostic' >&2; exit 1", in: dir)
        let failed = SigningRequest(format: .ssh, key: "key", identity: "T <t@e.com>", program: program.path)
        #expect(throws: SigningError.failed(program: program.path, stderr: "diagnostic")) {
            try ExternalProgramSigner().sign([], request: failed)
        }
        let noOutput = try SigningFixture.script("exit 0", name: "no-output", in: dir)
        let missing = SigningRequest(format: .ssh, key: "key", identity: "T <t@e.com>", program: noOutput.path)
        #expect(throws: SigningError.self) { try ExternalProgramSigner().sign([], request: missing) }
        let absent = SigningRequest(format: .openpgp, key: nil, identity: "T <t@e.com>",
                                    program: dir.appendingPathComponent("absent").path)
        #expect(throws: SigningError.self) { try ExternalProgramSigner().sign([], request: absent) }
    }
}

@Suite("Signed commit git parity", .enabled(if: SigningFixture.sshKeygenAvailable))
struct SignedCommitParityTests {
    private let fixtures = TemporaryRepositories()

    @Test("git verify-commit, object bytes and reflogs match git commit -S",
          arguments: [false, true], [false, true])
    func parity(hasParent: Bool, detached: Bool) throws {
        CommitSigningTests.signerDefaultsLock.lock()
        defer { CommitSigningTests.signerDefaultsLock.unlock() }
        defer { fixtures.removeAll() }
        let key = try SigningFixture.generateKey(in: fixtures.directory("keys"))
        let viaGit = try AmendFixture.makeRepo(in: fixtures)
        let viaKit = try AmendFixture.makeRepo(in: fixtures)
        for dir in [viaGit, viaKit] {
            try AmendFixture.git(["config", "commit.gpgsign", "false"], in: dir)
            if hasParent || detached { try AmendFixture.twoCommits(dir) }
            if detached { try AmendFixture.git(["checkout", "--detach", "-q"], in: dir) }
            try AmendFixture.git(["config", "gpg.format", "ssh"], in: dir)
            try AmendFixture.git(["config", "user.signingkey", key.path], in: dir)
            let publicKey = try String(contentsOf: URL(fileURLWithPath: key.path + ".pub"), encoding: .utf8)
            try AmendFixture.write("t@e.com " + publicKey, to: "allowed-signers", in: dir)
            try AmendFixture.git(["config", "gpg.ssh.allowedSignersFile", "allowed-signers"], in: dir)
            try AmendFixture.git(["config", "commit.gpgsign", "true"], in: dir)
            try AmendFixture.write("staged\n", to: "file", in: dir)
            try AmendFixture.git(["add", "file"], in: dir)
        }
        try AmendFixture.git(["commit", "-q", "-S" + key.path, "-m", "signed"], in: viaGit)
        let repo = try Repository.open(at: viaKit)
        let result = try repo.commitDetailed(message: "signed\n", author: nil, allowEmpty: false,
                                             env: SigningFixture.environment)
        #expect(result.sha + "\n" == (try AmendFixture.git(["rev-parse", "HEAD"], in: viaGit)))
        let actual = try AmendFixture.git(["cat-file", "commit", "HEAD"], in: viaKit)
        let expected = try AmendFixture.git(["cat-file", "commit", "HEAD"], in: viaGit)
        #expect(actual == expected, "GitKit:\n\(actual)\nGit:\n\(expected)")
        let verified = try AmendFixture.run(["verify-commit", "HEAD"], in: viaKit)
        #expect(verified.status == 0, "git verify-commit failed: \(verified.err)")
        for log in [".git/logs/HEAD", ".git/logs/refs/heads/main"] {
            #expect(try Data(contentsOf: viaKit.appendingPathComponent(log))
                == Data(contentsOf: viaGit.appendingPathComponent(log)))
        }
        // --no-gpg-sign overrides commit.gpgsign without invoking a signer.
        try AmendFixture.git(["commit", "-q", "--allow-empty", "--no-gpg-sign", "-m", "unsigned"], in: viaGit)
        let unsigned = try repo.commitDetailed(message: "unsigned\n", author: nil, allowEmpty: true,
                                               env: SigningFixture.environment, sign: .noSign)
        #expect(unsigned.sha + "\n" == (try AmendFixture.git(["rev-parse", "HEAD"], in: viaGit)))
    }
}
#endif

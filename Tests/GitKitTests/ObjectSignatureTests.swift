import Foundation
import Testing
@testable import GitKit

@Suite("Object signature parser")
struct ObjectSignatureParserTests {
    private let headers = "object 0000000000000000000000000000000000000000\ntype commit\ntag test\n\n"

    @Test("Each supported armor header starts a tag signature", arguments: [
        ("-----BEGIN PGP SIGNATURE-----", SigningFormat.openpgp),
        ("-----BEGIN PGP MESSAGE-----", SigningFormat.openpgp),
        ("-----BEGIN SSH SIGNATURE-----", SigningFormat.ssh),
        ("-----BEGIN SIGNED MESSAGE-----", SigningFormat.x509)
    ])
    func supportedArmor(header: String, format: SigningFormat) throws {
        // Neither payload decoding nor C-string termination may alter the bytes.
        let payload = Array((headers + "annotation\r\n").utf8) + [0xff, 0, 10]
        let signature = header + "\nopaque armor\ntrailing bytes"
        let result = try #require(parseTagSignature(payload + Array(signature.utf8)))
        #expect(result.field == nil)
        #expect(result.format == format)
        #expect(result.signature == signature)
        #expect(result.signedPayload == payload)
        #expect(result == parseTagSignature(payload + Array(signature.utf8)))
    }

    @Test("Unsigned, embedded, indented, unknown, and header-only markers are absent")
    func unsignedAndBoundaries() {
        for message in ["", "unsigned\n", "prefix -----BEGIN SSH SIGNATURE-----\n",
                        " -----BEGIN SSH SIGNATURE-----\n", "-----BEGIN UNKNOWN SIGNATURE-----\n"] {
            #expect(parseTagSignature(Array((headers + message).utf8)) == nil)
        }
        #expect(parseTagSignature([]) == nil)
        #expect(parseTagSignature(Array("-----BEGIN SSH SIGNATURE-----\n".utf8)) == nil)
        let headerMarker = headers.replacingOccurrences(of: "tag test", with: "-----BEGIN SSH SIGNATURE-----")
        #expect(parseTagSignature(Array((headerMarker + "unsigned\n").utf8)) == nil)
    }

    @Test("The last candidate at a line start wins, even without a final newline")
    func lastCandidate() throws {
        let payload = headers + "-----BEGIN PGP SIGNATURE-----\nfirst block\n"
        let signature = "-----BEGIN SSH SIGNATURE-----suffix\nlast block"
        let result = try #require(parseTagSignature(Array((payload + signature).utf8)))
        #expect(result.signedPayload == Array(payload.utf8))
        #expect(result.signature == signature)
        #expect(result.format == .ssh)
    }
}

// Integration tests invoke the system git and ssh-keygen, like AmendFixture.
#if os(macOS) || os(Linux)
@Suite("Repository object signatures")
struct ObjectSignatureTests {
    private let fixtures = TemporaryRepositories()

    @Test("Unsigned objects return absence; missing revisions and wrong types throw")
    func unsignedAndErrors() throws {
        defer { fixtures.removeAll() }
        let dir = try AmendFixture.makeRepo(in: fixtures)
        try AmendFixture.twoCommits(dir)
        try AmendFixture.git(["tag", "-a", "unsigned", "-m", "annotation"], in: dir)
        try AmendFixture.git(["tag", "lightweight"], in: dir)
        let repo = try Repository.open(at: dir)
        #expect(try repo.commitSignatures("HEAD").isEmpty)
        #expect(try repo.commitSignatures("unsigned").isEmpty)
        #expect(try repo.tagSignature("unsigned") == nil)
        for rev in ["missing-ref", "HEAD^{tree}", "HEAD:f"] {
            #expect(throws: Libgit2Error.self) { try repo.commitSignatures(rev) }
            #expect(throws: Libgit2Error.self) { try repo.tagSignature(rev) }
        }
        for rev in ["HEAD", "lightweight", "unsigned^{}"] {
            #expect(throws: Libgit2Error.self) { try repo.tagSignature(rev) }
        }
    }

    @Test("Literal commit headers preserve each field's exact payload", arguments: [
        ["gpgsig"], ["gpgsig-sha256"], ["gpgsig", "gpgsig-sha256"]
    ])
    func literalCommit(fields: [String]) throws {
        defer { fixtures.removeAll() }
        let dir = try AmendFixture.makeRepo(in: fixtures)
        try AmendFixture.twoCommits(dir)
        let tree = try AmendFixture.git(["rev-parse", "HEAD^{tree}"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let headers = "tree \(tree)\nauthor T <t@e.com> 1767258000 +0100\n"
            + "committer T <t@e.com> 1767258000 +0100\n"
        let message = Array("\nmessage\r\n".utf8) + [0xff, 0xfe, 10]
        let signatures = ["gpgsig": "-----BEGIN SSH SIGNATURE-----\nfirst\n-----END SSH SIGNATURE-----",
                          "gpgsig-sha256": "unknown armor\nsecond"]
        let blocks = try fields.map { field in
            field + " " + (try #require(signatures[field])).replacingOccurrences(of: "\n", with: "\n ") + "\n"
        }
        let raw = Array((headers + blocks.joined()).utf8) + message
        let sha = try ObjectSignatureFixture.writeObject(raw, type: "commit", in: dir)
        let result = try Repository.open(at: dir).commitSignatures(sha)
        #expect(result.map(\.field) == fields.map(Optional.some))
        for (index, signature) in result.enumerated() {
            let otherBlocks = blocks.enumerated().filter { $0.offset != index }.map(\.element).joined()
            #expect(signature.signedPayload == Array((headers + otherBlocks).utf8) + message)
            #expect(signature.signature == signatures[fields[index]])
            #expect(signature.format == (fields[index] == "gpgsig" ? .ssh : nil))
        }
    }

    @Test("Raw tag payload keeps non-UTF8 bytes and embedded NULs")
    func literalTag() throws {
        defer { fixtures.removeAll() }
        let dir = try AmendFixture.makeRepo(in: fixtures)
        try AmendFixture.twoCommits(dir)
        let head = try AmendFixture.git(["rev-parse", "HEAD"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let headers = "object \(head)\ntype commit\ntag raw\ntagger T <t@e.com> 1767258000 +0100\n\n"
        let payload = Array(headers.utf8) + [0xff, 0, 10]
        let signature = "-----BEGIN SIGNED MESSAGE-----\nopaque\n"
        let sha = try ObjectSignatureFixture.writeObject(payload + Array(signature.utf8), type: "tag", in: dir)
        let repo = try Repository.open(at: dir)
        let result = try #require(try repo.tagSignature(sha))
        #expect(result.signedPayload == payload)
        #expect(result.signature == signature)
        #expect(result.format == .x509)
    }

    @Test("Git CLI SSH signatures verify with the extracted payloads",
          .enabled(if: ObjectSignatureFixture.supportsSSHSigning, "Requires git SSH signing and ssh-keygen -Y"))
    func sshSignatures() throws {
        defer { fixtures.removeAll() }
        let dir = try AmendFixture.makeRepo(in: fixtures)
        try AmendFixture.twoCommits(dir)
        let key = dir.appendingPathComponent("signing-key")
        try ObjectSignatureFixture.ssh(["-t", "ed25519", "-N", "", "-f", key.path], in: dir)
        try AmendFixture.git(["config", "gpg.format", "ssh"], in: dir)
        try AmendFixture.git(["config", "user.signingkey", key.path], in: dir)
        try AmendFixture.git(["commit", "--allow-empty", "-S", "-m", "signed commit"], in: dir)
        try AmendFixture.git(["tag", "-s", "signed-tag", "-m", "signed annotation"], in: dir)
        let repo = try Repository.open(at: dir)
        let signatures = try repo.commitSignatures("HEAD")
        #expect(signatures.count == 1)
        let commit = try #require(signatures.first)
        #expect(commit.field == "gpgsig")
        #expect(commit.format == .ssh)
        #expect(try repo.commitSignatures("signed-tag") == signatures)
        let tag = try #require(try repo.tagSignature("signed-tag"))
        #expect(tag.field == nil)
        #expect(tag.format == .ssh)
        let publicKey = try String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8)
        try AmendFixture.write("test@example.com \(publicKey)", to: "allowed-signers", in: dir)
        for signature in [commit, tag] {
            try ObjectSignatureFixture.verify(signature, in: dir)
        }

        // Use a real SSH signature in the alternate header, independently of SHA-256 object support.
        let payload = try #require(String(bytes: commit.signedPayload, encoding: .utf8))
        let separator = try #require(payload.range(of: "\n\n"))
        let armor = commit.signature.trimmingCharacters(in: .newlines)
        let header = "gpgsig-sha256 " + armor.replacingOccurrences(of: "\n", with: "\n ") + "\n"
        let raw = String(payload[..<separator.lowerBound]) + "\n" + header
            + "\n" + String(payload[separator.upperBound...])
        let sha = try ObjectSignatureFixture.writeObject(Array(raw.utf8), type: "commit", in: dir)
        let alternate = try #require(try repo.commitSignatures(sha).first)
        #expect(alternate.field == "gpgsig-sha256")
        #expect(alternate.signedPayload == commit.signedPayload)
        try ObjectSignatureFixture.verify(alternate, in: dir)
    }
}

private enum ObjectSignatureFixture {
    static let supportsSSHSigning: Bool = {
        let fixtures = TemporaryRepositories()
        defer { fixtures.removeAll() }
        do {
            guard try AmendFixture.gitIsAtLeast(2, 34) else { return false }
            let dir = try fixtures.directory("ssh-probe")
            try ssh(["-t", "ed25519", "-N", "", "-f", dir.appendingPathComponent("key").path], in: dir)
            try AmendFixture.write("probe", to: "payload", in: dir)
            try ssh(["-Y", "sign", "-n", "git", "-f", dir.appendingPathComponent("key").path,
                     dir.appendingPathComponent("payload").path], in: dir)
            return true
        } catch { return false }
    }()

    static func writeObject(_ bytes: [UInt8], type: String, in dir: URL) throws -> String {
        let file = dir.appendingPathComponent("object-\(UUID().uuidString)")
        try Data(bytes).write(to: file)
        return try AmendFixture.git(["hash-object", "-w", "-t", type, "--literally", file.path], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    static func ssh(_ args: [String], in dir: URL, input: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ssh-keygen"] + args
        process.currentDirectoryURL = dir
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let file = try input.map { try FileHandle(forReadingFrom: $0) }
        defer { try? file?.close() }
        process.standardInput = file ?? FileHandle.nullDevice
        try process.run()
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AmendFixture.Failure(description: "ssh-keygen failed: \(String(decoding: errors, as: UTF8.self))")
        }
        return String(decoding: output, as: UTF8.self)
    }

    static func verify(_ signature: ObjectSignature, in dir: URL) throws {
        let payload = dir.appendingPathComponent("verify-payload")
        let armor = dir.appendingPathComponent("verify-signature")
        try Data(signature.signedPayload).write(to: payload)
        try Data(signature.signature.utf8).write(to: armor)
        let output = try ssh(["-Y", "verify", "-n", "git", "-I", "test@example.com",
                              "-f", dir.appendingPathComponent("allowed-signers").path,
                              "-s", armor.path], in: dir, input: payload)
        #expect(output.contains("Good \"git\" signature"))
    }
}

#endif

#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

enum SigningFixture {
    static let environment = [
        "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@e.com", "GIT_AUTHOR_DATE": AmendFixture.authorDate,
        "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@e.com", "GIT_COMMITTER_DATE": AmendFixture.authorDate
    ]

    /// Probe actual signing, since older ssh-keygen versions lack -Y.
    static let sshKeygenAvailable: Bool = {
        let fixtures = TemporaryRepositories()
        defer { fixtures.removeAll() }
        do {
            let dir = try fixtures.directory("probe")
            let key = try generateKey(in: dir)
            let request = SigningRequest(format: .ssh, key: key.path, identity: "T <t@e.com>")
            _ = try ExternalProgramSigner().sign(Array("probe\n".utf8), request: request)
            return true
        } catch { return false }
    }()

    static func generateKey(in dir: URL) throws -> URL {
        let key = dir.appendingPathComponent("signing-key")
        let result = try run("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key.path], in: dir)
        guard result.status == 0 else { throw AmendFixture.Failure(description: result.err) }
        return key
    }

    @discardableResult
    static func run(
        _ program: String, _ arguments: [String], in dir: URL, environment: [String: String] = [:]
    ) throws -> (out: String, err: String, status: Int32) {
        let output = dir.appendingPathComponent("process-out-\(UUID().uuidString)")
        let errors = dir.appendingPathComponent("process-err-\(UUID().uuidString)")
        try Data().write(to: output)
        try Data().write(to: errors)
        let stdout = try FileHandle(forWritingTo: output)
        let stderr = try FileHandle(forWritingTo: errors)
        defer {
            try? stdout.close()
            try? stderr.close()
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: errors)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [program] + arguments
        process.currentDirectoryURL = dir
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (String(decoding: try Data(contentsOf: output), as: UTF8.self),
                String(decoding: try Data(contentsOf: errors), as: UTF8.self), process.terminationStatus)
    }

    /// A local test executable, allowing exact argv/stdin/status assertions
    /// without depending on a gpg keyring or an ssh-agent.
    ///
    /// A child that parallel tests fork while this process holds the script
    /// open for writing inherits that descriptor, and on Linux executing the
    /// script then fails with ETXTBSY. Writing it from a short-lived `cp`
    /// keeps the only writable descriptor out of this process.
    static func script(_ body: String, name: String = "signer", in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let source = dir.appendingPathComponent("\(name)-source-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: source)
        let copy = try run("cp", [source.path, url.path], in: dir)
        guard copy.status == 0 else { throw AmendFixture.Failure(description: copy.err) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
#endif

// Integration tests for push options (`git push -o`). The remote is a
// real `git receive-pack` reached through the fake SSH channel, so the
// smart transport negotiates push options as against a real server; its
// pre-receive hook records what it was sent. libgit2's local path
// transport never supports them.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

@Suite("Push options")
struct PushOptionsTests {

    private let fixtures = TemporaryRepositories()

    private func tmp(_ label: String) -> URL {
        fixtures.url("PushOptionsTests-\(label)-\(UUID().uuidString)")
    }

    @discardableResult
    private func runGit(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-c", "user.name=Test", "-c", "user.email=test@example.com"] + args
        p.currentDirectoryURL = dir
        let out = Pipe(); let err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        p.waitUntilExit()
        let outStr = String(decoding: (try? out.fileHandleForReading.readToEnd()) ?? Data(),
                            as: UTF8.self)
        #expect(p.terminationStatus == 0, "git \(args.joined(separator: " ")) failed")
        return outStr.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A bare remote whose pre-receive hook records the push options it
    /// got in `record`, and a work repository with a commit on `main`
    /// and the remote as `origin`: over `ssh://`, or as a plain path.
    private func makeFixture(
        advertise: Bool, ssh: Bool = true
    ) throws -> (remote: URL, work: URL, record: URL) {
        let remote = tmp("remote").appendingPathExtension("git")
        let work = tmp("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try runGit(["init", "-q", "--bare", "-b", "main", remote.path], in: work)
        if advertise {
            try runGit(["config", "receive.advertisePushOptions", "true"], in: remote)
        }
        let record = remote.appendingPathComponent("push-options.txt")
        let hook = remote.appendingPathComponent("hooks/pre-receive")
        try FileManager.default.createDirectory(
            at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
            #!/bin/sh
            echo "count=${GIT_PUSH_OPTION_COUNT:-none}" > '\(record.path)'
            i=0
            while [ "$i" -lt "${GIT_PUSH_OPTION_COUNT:-0}" ]; do
              eval "echo \\"\\$GIT_PUSH_OPTION_$i\\"" >> '\(record.path)'
              i=$((i + 1))
            done
            """.write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

        try runGit(["init", "-q", "-b", "main"], in: work)
        try runGit(["commit", "-q", "--allow-empty", "-m", "one"], in: work)
        let url = ssh ? "ssh://localhost\(remote.path)" : remote.path
        try runGit(["remote", "add", "origin", url], in: work)
        return (remote, work, record)
    }

    private func withSSHTransport(_ body: () throws -> Void) throws {
        try SSHTransportTestLock.shared.withLock {
            try GitSSHTransport.register(FakeSSHProvider())
            defer { GitSSHTransport.unregister() }
            try body()
        }
    }

    @Test("push options reach the remote's pre-receive hook")
    func testPushOptionsReachRemote() throws {
        defer { fixtures.removeAll() }
        let (remote, work, record) = try makeFixture(advertise: true)
        try withSSHTransport {
            try Repository.open(at: work).push(
                remote: "origin", refspec: "main", setUpstream: false,
                pushOptions: ["ci.skip", "topic=x"], progress: { _ in })
        }
        #expect(try String(contentsOf: record, encoding: .utf8) == "count=2\nci.skip\ntopic=x\n")
        #expect(try runGit(["rev-parse", "main"], in: remote) == runGit(["rev-parse", "HEAD"], in: work))
    }

    @Test("a push without options sends none")
    func noOptionsByDefault() throws {
        defer { fixtures.removeAll() }
        let (_, work, record) = try makeFixture(advertise: true)
        try withSSHTransport {
            try Repository.open(at: work).push(
                remote: "origin", refspec: "main", setUpstream: false, progress: { _ in })
        }
        // An advertising server reports a count of zero.
        #expect(try String(contentsOf: record, encoding: .utf8) == "count=0\n")
    }

    @Test("a server that doesn't advertise push options refuses them")
    func serverWithoutPushOptions() throws {
        defer { fixtures.removeAll() }
        let (remote, work, _) = try makeFixture(advertise: false)
        try withSSHTransport {
            let error = #expect(throws: Libgit2Error.self) {
                try Repository.open(at: work).push(
                    remote: "origin", refspec: "main", setUpstream: false,
                    pushOptions: ["ci.skip"], progress: { _ in })
            }
            #expect(error?.message.contains("push-options not supported by remote") == true)
        }
        #expect(try runGit(["for-each-ref", "refs/heads"], in: remote).isEmpty)
    }

    @Test("a local path remote never supports push options")
    func localPathRefusesPushOptions() throws {
        defer { fixtures.removeAll() }
        let (_, work, record) = try makeFixture(advertise: true, ssh: false)
        let error = #expect(throws: Libgit2Error.self) {
            try Repository.open(at: work).push(
                remote: "origin", refspec: "main", setUpstream: false,
                pushOptions: ["ci.skip"], progress: { _ in })
        }
        #expect(error?.message.contains("push-options not supported by remote") == true)
        #expect(!FileManager.default.fileExists(atPath: record.path))
    }

    @Test("options with a newline or NUL are refused before connecting")
    func invalidOptionsRefused() throws {
        defer { fixtures.removeAll() }
        let (_, work, record) = try makeFixture(advertise: true)
        let repo = try Repository.open(at: work)
        try withSSHTransport {
            for option in ["a\nb", "a\0b"] {
                let error = #expect(throws: Libgit2Error.self) {
                    try repo.push(
                        remote: "origin", refspec: "main", setUpstream: false,
                        pushOptions: [option], progress: { _ in })
                }
                #expect(error?.code == GIT_EINVALID.rawValue)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: record.path))
    }

    @Test("pushing with leases forwards push options")
    func leasesForwardPushOptions() throws {
        defer { fixtures.removeAll() }
        let (_, work, record) = try makeFixture(advertise: true)
        try withSSHTransport {
            try Repository.open(at: work).push(
                remote: "origin", refspecs: ["main"], setUpstream: false,
                leases: PushLeases(trackingForRest: true),
                pushOptions: ["ci.skip"], progress: { _ in })
        }
        #expect(try String(contentsOf: record, encoding: .utf8) == "count=1\nci.skip\n")
    }
}
#endif

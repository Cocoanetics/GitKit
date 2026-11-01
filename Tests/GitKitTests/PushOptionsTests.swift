// Integration test for push options (`git push -o`). The remote's
// pre-receive hook records what it was sent.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

@Suite("Push options")
struct PushOptionsTests {

    private let fixtures = TemporaryRepositories()

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

    @Test("push options reach the remote's pre-receive hook")
    func testPushOptionsReachRemote() throws {
        defer { fixtures.removeAll() }
        let remote = fixtures.url("PushOptionsTests-remote-\(UUID().uuidString)")
            .appendingPathExtension("git")
        let work = fixtures.url("PushOptionsTests-work-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try runGit(["init", "-q", "--bare", "-b", "main", remote.path], in: work)
        try runGit(["config", "receive.advertisePushOptions", "true"], in: remote)

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
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: hook.path)

        try runGit(["init", "-q", "-b", "main"], in: work)
        try runGit(["commit", "-q", "--allow-empty", "-m", "one"], in: work)

        // libgit2's local transport has no push options; serve the remote
        // over git:// so the smart protocol carries them.
        let port = Int.random(in: 20000..<60000)
        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        daemon.arguments = [
            "git", "daemon", "--reuseaddr", "--listen=127.0.0.1", "--port=\(port)",
            "--export-all", "--enable=receive-pack", "--base-path=\(remote.deletingLastPathComponent().path)"
        ]
        daemon.standardError = FileHandle.nullDevice
        try daemon.run()
        defer { daemon.terminate(); daemon.waitUntilExit() }

        let url = "git://127.0.0.1:\(port)/\(remote.lastPathComponent)"
        try runGit(["remote", "add", "origin", url], in: work)
        let repo = try Repository.open(at: work)
        var pushed = false
        for _ in 0..<50 where !pushed {
            do {
                try repo.push(
                    remote: "origin", refspec: "main", setUpstream: false,
                    pushOptions: ["ci.skip"], progress: { _ in })
                pushed = true
            } catch {
                // The daemon may not be listening yet.
                if !"\(error)".contains("connect") { throw error }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        #expect(pushed)

        let recorded = try String(contentsOf: record, encoding: .utf8)
        #expect(recorded == "count=1\nci.skip\n")
    }
}
#endif

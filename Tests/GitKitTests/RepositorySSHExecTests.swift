// Regression test for issue #38: the ssh_exec transport's close path never
// reaped its `ssh` child, so a long-running process that fetches over SSH
// accumulated one zombie per connection. No real network or SSH server is
// involved — `core.sshCommand` points at a local script that ignores the
// host argument and execs `git-upload-pack` on a local bare repo directly,
// which is enough to drive the real ssh_exec subtransport end to end.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

@Suite("Repository ssh_exec transport")
struct RepositorySSHExecTests {

    private func tmp(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)")
    }

    @discardableResult
    private func runGit(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = dir
        let out = Pipe(); let err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        p.waitUntilExit()
        let outStr = String(decoding: (try? out.fileHandleForReading.readToEnd()) ?? Data(),
                            as: UTF8.self)
        if p.terminationStatus != 0 {
            let errStr = String(decoding: (try? err.fileHandleForReading.readToEnd()) ?? Data(),
                                as: UTF8.self)
            throw Failure("git \(args.joined(separator: " ")) failed: \(errStr)")
        }
        return outStr
    }

    private struct Failure: Error, CustomStringConvertible {
        let message: String
        init(_ m: String) { self.message = m }
        var description: String { message }
    }

    /// A bare repo with one commit, servable by `git-upload-pack`.
    private func makeBareSource() throws -> URL {
        let work = tmp("SSHExecSourceWork")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try runGit(["init", "-q", "-b", "main"], in: work)
        try runGit(["config", "user.email", "test@example.com"], in: work)
        try runGit(["config", "user.name", "Test"], in: work)
        try Data("hi\n".utf8).write(to: work.appendingPathComponent("file.txt"))
        try runGit(["add", "."], in: work)
        try runGit(["commit", "-q", "-m", "init"], in: work)

        let bare = tmp("SSHExecSource")
        try runGit(["clone", "-q", "--bare", work.path, bare.path], in: work)
        return bare
    }

    /// A script that stands in for `ssh`: it records its own pid to `pidLog`
    /// (so the test can check specifically on the processes it spawns, not
    /// on every child of the test binary — swift-testing runs suites
    /// concurrently, so unrelated tests' subprocesses can be transiently
    /// visible too), then evals the remote command verbatim, running
    /// `git-upload-pack` against the local bare repo instead of actually
    /// connecting anywhere. Mirrors how `GIT_SSH_COMMAND`/`core.sshCommand`
    /// scripts are invoked for real: `setup_args()` builds
    /// `/bin/sh -c '<script> "$@"' <script> <host> <command>`.
    private func makeFakeSSHScript(pidLog: URL) throws -> URL {
        let script = tmp("fake-ssh").appendingPathExtension("sh")
        let contents = """
        #!/bin/sh
        echo "$$" >> "\(pidLog.path)"
        eval "$2"
        """
        try Data(contents.utf8).write(to: script)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// Every pid currently known to the system (`ps -axo pid=`), as a set
    /// for cheap membership checks. A pid that has fully exited and been
    /// reaped — whether it was a zombie or still running — disappears from
    /// this output entirely.
    private func livePIDs() throws -> Set<Int32> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid="]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let text = String(decoding: (try? out.fileHandleForReading.readToEnd()) ?? Data(),
                          as: UTF8.self)
        return Set(text.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) })
    }

    @Test("fetch over ssh_exec leaves no zombie children")
    func fetchLeavesNoZombies() throws {
        // Serialized with GitSSHTransportTests: both mutate libgit2's
        // process-wide ssh:// transport dispatch, and a `.serialized`
        // suite trait alone wouldn't stop the two suites racing — see
        // SSHTransportTestLock.
        try SSHTransportTestLock.shared.withLock {
            let bare = try makeBareSource()
            let pidLog = tmp("ssh-pids")
            FileManager.default.createFile(atPath: pidLog.path, contents: nil)
            let script = try makeFakeSSHScript(pidLog: pidLog)

            let dest = tmp("SSHExecDest")
            let repo = try Repository.initialize(at: dest, initialBranch: "main")
            try repo.addRemote(
                name: "origin",
                url: URL(string: "ssh://localhost\(bare.path)")!)
            try repo.configSet("core.sshCommand", script.path)

            let fetchCount = 5
            for _ in 0..<fetchCount {
                try repo.fetch(
                    remote: "origin", refspec: "+refs/heads/*:refs/remotes/origin/*",
                    progress: { _ in })
            }

            let pidText = try String(contentsOf: pidLog, encoding: .utf8)
            let spawnedPIDs = pidText.split(separator: "\n").compactMap { Int32($0) }
            #expect(spawnedPIDs.count == fetchCount)

            // Each fetch() call connects, transfers, and disconnects in one
            // shot, so by the time it returns the transport has already closed
            // (and should have reaped) its ssh child — no need to wait here.
            let live = try livePIDs()
            let leaked = spawnedPIDs.filter { live.contains($0) }
            #expect(leaked.isEmpty)
        }
    }
}
#endif

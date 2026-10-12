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

    /// A script that stands in for `ssh`: it ignores the host argument and
    /// evals the remote command verbatim, running `git-upload-pack` against
    /// the local bare repo instead of actually connecting anywhere. Mirrors
    /// how `GIT_SSH_COMMAND`/`core.sshCommand` scripts are invoked for real:
    /// `setup_args()` builds `/bin/sh -c '<script> "$@"' <script> <host> <command>`.
    private func makeFakeSSHScript() throws -> URL {
        let script = tmp("fake-ssh").appendingPathExtension("sh")
        let contents = """
        #!/bin/sh
        eval "$2"
        """
        try Data(contents.utf8).write(to: script)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// Zombie (`Z` state) direct children of this test process.
    private func zombieChildPIDs() throws -> [Int32] {
        let myPID = ProcessInfo.processInfo.processIdentifier

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid=,stat="]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let text = String(decoding: (try? out.fileHandleForReading.readToEnd()) ?? Data(),
                          as: UTF8.self)

        var zombies: [Int32] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3,
                  let pid = Int32(fields[0]), let ppid = Int32(fields[1]),
                  ppid == myPID, fields[2].hasPrefix("Z")
            else { continue }
            zombies.append(pid)
        }
        return zombies
    }

    @Test("fetch over ssh_exec leaves no zombie children")
    func fetchLeavesNoZombies() throws {
        let bare = try makeBareSource()
        let script = try makeFakeSSHScript()

        let dest = tmp("SSHExecDest")
        let repo = try Repository.initialize(at: dest, initialBranch: "main")
        try repo.addRemote(
            name: "origin",
            url: URL(string: "ssh://localhost\(bare.path)")!)
        try repo.configSet("core.sshCommand", script.path)

        for _ in 0..<5 {
            try repo.fetch(
                remote: "origin", refspec: "+refs/heads/*:refs/remotes/origin/*",
                progress: { _ in })
        }

        #expect(try zombieChildPIDs().isEmpty)
    }
}
#endif

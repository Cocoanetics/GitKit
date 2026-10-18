// Tests for the GitSSHTransport registration hook (issue #40): a fake
// provider drives `git upload-pack` / `git receive-pack` locally over
// pipes (no real network or SSH server involved), standing in for an
// in-process SSH client such as SwiftPorts' swift-nio-ssh-backed one.
#if os(macOS) || os(Linux)
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Testing
@testable import GitKit

/// Runs `git upload-pack`/`git receive-pack` as a local child process and
/// exposes its stdin/stdout as a ``GitSSHChannel``. Stands in for a real
/// SSH connection: libgit2 only ever sees bytes flow through `read`/
/// `write`, so it can't tell the difference.
final class FakeSSHChannel: GitSSHChannel {
    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe

    init(command: GitSSHCommand) throws {
        let subcommand: String
        let path: String
        switch command {
        case .uploadPack(let p): subcommand = "upload-pack"; path = p
        case .receivePack(let p): subcommand = "receive-pack"; path = p
        case .uploadArchive(let p): subcommand = "upload-archive"; path = p
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", subcommand, path]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()

        self.process = process
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return 0 }
        // A raw `read(2)` returns as soon as *any* data has arrived (or
        // 0 at EOF); `FileHandle.readData(ofLength:)` instead loops
        // until it fills the whole buffer, which would deadlock
        // against a request/response protocol like git's pkt-line
        // exchange (we'd block waiting for more bytes while the
        // subprocess is itself blocked waiting for our next write).
        let fd = stdoutPipe.fileHandleForReading.fileDescriptor
        while true {
            let n = Foundation.read(fd, base, buffer.count)
            if n >= 0 { return n }
            if errno == EINTR { continue }
            throw FakeSSHChannelError(message: "read from fake ssh channel failed: \(String(cString: strerror(errno)))")
        }
    }

    func write(_ buffer: UnsafeRawBufferPointer) throws {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return }
        // Raw `write(2)` rather than `FileHandle.write(_:)`: the latter
        // raises an uncatchable NSException (not a Swift error) on a
        // write failure, which a broken pipe triggers routinely here —
        // libgit2 sends a courtesy flush packet on close() after
        // `git-upload-pack` may have already exited and closed its end.
        let fd = stdinPipe.fileHandleForWriting.fileDescriptor
        var offset = 0
        while offset < buffer.count {
            let n = Foundation.write(fd, base + offset, buffer.count - offset)
            if n > 0 {
                offset += n
                continue
            }
            if n < 0, errno == EINTR { continue }
            throw FakeSSHChannelError(
                message: "write to fake ssh channel failed: \(String(cString: strerror(errno)))")
        }
    }

    func close() {
        try? stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()
    }
}

struct FakeSSHProviderError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct FakeSSHChannelError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Records every channel it opens so tests can assert the custom
/// transport (rather than `ssh_exec`) actually drove the operation.
/// `@unchecked Sendable`: libgit2 only ever calls into one subtransport
/// from one thread at a time, and these tests never touch an instance
/// concurrently from two threads, so the mutable state is safe in
/// practice despite not being statically checked.
final class FakeSSHProvider: GitSSHTransportProvider, @unchecked Sendable {
    private(set) var openedCommands: [GitSSHCommand] = []
    /// The `user@host` each channel was opened for.
    private(set) var openedDestinations: [String] = []
    var failureMessage: String?

    func openChannel(
        host: String, port: Int?, user: String?, command: GitSSHCommand
    ) throws -> GitSSHChannel {
        openedCommands.append(command)
        openedDestinations.append(user.map { "\($0)@\(host)" } ?? host)
        if let failureMessage {
            throw FakeSSHProviderError(message: failureMessage)
        }
        return try FakeSSHChannel(command: command)
    }
}

// Every test here mutates `GitSSHTransport`'s process-wide registration,
// so each one runs its body inside `SSHTransportTestLock.shared.withLock`
// — not just to serialize within this suite (a `.serialized` trait would
// do that) but to serialize against `RepositorySSHExecTests` too, which
// shares the same `ssh://` transport dispatch. See SSHTransportTestLock.
@Suite("GitSSHTransport")
struct GitSSHTransportTests {

    private func tmp(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)")
    }

    private struct Failure: Error, CustomStringConvertible {
        let message: String
        init(_ m: String) { self.message = m }
        var description: String { message }
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

    /// A bare repo with one commit, servable by `git-upload-pack`.
    private func makeBareSource() throws -> URL {
        let work = tmp("GitSSHSourceWork")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try runGit(["init", "-q", "-b", "main"], in: work)
        try runGit(["config", "user.email", "test@example.com"], in: work)
        try runGit(["config", "user.name", "Test"], in: work)
        try Data("hi\n".utf8).write(to: work.appendingPathComponent("file.txt"))
        try runGit(["add", "."], in: work)
        try runGit(["commit", "-q", "-m", "init"], in: work)

        let bare = tmp("GitSSHSource")
        try runGit(["clone", "-q", "--bare", work.path, bare.path], in: work)
        return bare
    }

    /// An empty bare repo, servable by `git-receive-pack`.
    private func makeBareDestination() throws -> URL {
        let bare = tmp("GitSSHDestination")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try runGit(["init", "-q", "--bare", "-b", "main"], in: bare)
        return bare
    }

    /// A non-bare repo with one commit on `main`, ready to push from.
    private func makeWorkRepo() throws -> URL {
        let work = tmp("GitSSHPushWork")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try runGit(["init", "-q", "-b", "main"], in: work)
        try runGit(["config", "user.email", "test@example.com"], in: work)
        try runGit(["config", "user.name", "Test"], in: work)
        try Data("hi\n".utf8).write(to: work.appendingPathComponent("file.txt"))
        try runGit(["add", "."], in: work)
        try runGit(["commit", "-q", "-m", "init"], in: work)
        return work
    }

    /// A script standing in for `ssh`, as `GIT_SSH_COMMAND`/
    /// `core.sshCommand` would invoke it: it records its pid then execs
    /// the remote command verbatim against a local bare repo.
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

    @Test("fetch over the registered transport is carried by the provider")
    func fetchUsesRegisteredProvider() throws {
        try SSHTransportTestLock.shared.withLock {
            let provider = FakeSSHProvider()
            try GitSSHTransport.register(provider)
            defer { GitSSHTransport.unregister() }

            let bare = try makeBareSource()
            let dest = tmp("GitSSHFetchDest")
            let repo = try Repository.initialize(at: dest, initialBranch: "main")
            try repo.addRemote(name: "origin", url: URL(string: "ssh://localhost\(bare.path)")!)

            try repo.fetch(
                remote: "origin", refspec: "+refs/heads/*:refs/remotes/origin/*",
                progress: { _ in })

            #expect(provider.openedCommands.contains {
                if case .uploadPack = $0 { return true }
                return false
            })
            // The fetched ref landed, proving bytes actually flowed through
            // the fake channel rather than the fetch silently no-oping.
            try runGit(["rev-parse", "refs/remotes/origin/main"], in: dest)
        }
    }

    @Test("push over the registered transport is carried by the provider")
    func pushUsesRegisteredProvider() throws {
        try SSHTransportTestLock.shared.withLock {
            let provider = FakeSSHProvider()
            try GitSSHTransport.register(provider)
            defer { GitSSHTransport.unregister() }

            let destBare = try makeBareDestination()
            let work = try makeWorkRepo()
            let repo = try Repository.open(at: work)
            try repo.addRemote(name: "origin", url: URL(string: "ssh://localhost\(destBare.path)")!)

            try repo.push(remote: "origin", refspec: "main", setUpstream: false)

            #expect(provider.openedCommands.contains {
                if case .receivePack = $0 { return true }
                return false
            })
            let localSHA = try runGit(["rev-parse", "HEAD"], in: work)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let remoteSHA = try runGit(["rev-parse", "main"], in: destBare)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(localSHA == remoteSHA)
        }
    }

    @Test("a scp-style IPv6 remote reaches the provider unmangled")
    func scpStyleIPv6RemoteReachesTheProvider() throws {
        try SSHTransportTestLock.shared.withLock {
            let provider = FakeSSHProvider()
            try GitSSHTransport.register(provider)
            defer { GitSSHTransport.unregister() }

            let bare = try makeBareSource()
            // Built the way a CLI builds it from argv: Foundation
            // percent-encodes the brackets and colons.
            let remote = URL(string: "git@[::1]:\(bare.path)")!

            let dest = tmp("GitSSHScpCloneDest")
            _ = try Repository.clone(from: remote, to: dest, progress: { _ in })
            #expect(provider.openedDestinations == ["git@::1"])
            #expect(FileManager.default.fileExists(
                atPath: dest.appendingPathComponent("file.txt").path))

            let work = try makeWorkRepo()
            let repo = try Repository.open(at: work)
            try repo.addRemote(name: "origin", url: remote)
            let configured = try runGit(["config", "--get", "remote.origin.url"], in: work)
            #expect(configured == "git@[::1]:\(bare.path)\n")
            try repo.remoteSetURL(name: "origin", url: URL(string: "git@[::2]:r.git")!)
            let updated = try runGit(["config", "--get", "remote.origin.url"], in: work)
            #expect(updated == "git@[::2]:r.git\n")

            // The String forms keep the remote exactly as typed, even an
            // escape a URL can't tell from one Foundation added.
            try repo.remoteSetURL(name: "origin", remote: "git@host:repos%20team.git")
            #expect(try runGit(["config", "--get", "remote.origin.url"], in: work)
                    == "git@host:repos%20team.git\n")
            try repo.addRemote(name: "other", remote: "git@[::1]:\(bare.path)")
            #expect(try runGit(["config", "--get", "remote.other.url"], in: work)
                    == "git@[::1]:\(bare.path)\n")
            let viaString = tmp("GitSSHScpCloneString")
            _ = try Repository.clone(fromRemote: "git@[::1]:\(bare.path)", to: viaString,
                                     progress: { _ in })
            #expect(FileManager.default.fileExists(
                atPath: viaString.appendingPathComponent("file.txt").path))
        }
    }

    @Test("a provider error surfaces as a GitKit error")
    func providerErrorSurfacesAsGitKitError() throws {
        try SSHTransportTestLock.shared.withLock {
            let provider = FakeSSHProvider()
            provider.failureMessage = "fake provider refused the connection"
            try GitSSHTransport.register(provider)
            defer { GitSSHTransport.unregister() }

            let bare = try makeBareSource()
            let dest = tmp("GitSSHErrorDest")
            let repo = try Repository.initialize(at: dest, initialBranch: "main")
            try repo.addRemote(name: "origin", url: URL(string: "ssh://localhost\(bare.path)")!)

            do {
                try repo.fetch(
                    remote: "origin", refspec: "+refs/heads/*:refs/remotes/origin/*",
                    progress: { _ in })
                Issue.record("expected the fetch to throw")
            } catch let error as Libgit2Error {
                #expect(error.message.contains("fake provider refused the connection"))
            }
        }
    }

    @Test("unregister restores ssh_exec")
    func unregisterRestoresSSHExec() throws {
        try SSHTransportTestLock.shared.withLock {
            let provider = FakeSSHProvider()
            try GitSSHTransport.register(provider)

            let bare = try makeBareSource()

            // First, confirm the registered provider is actually in the loop.
            let dest1 = tmp("GitSSHUnregisterDest1")
            let repo1 = try Repository.initialize(at: dest1, initialBranch: "main")
            try repo1.addRemote(name: "origin", url: URL(string: "ssh://localhost\(bare.path)")!)
            try repo1.fetch(
                remote: "origin", refspec: "+refs/heads/*:refs/remotes/origin/*",
                progress: { _ in })
            #expect(!provider.openedCommands.isEmpty)
            let openedBeforeUnregister = provider.openedCommands.count

            GitSSHTransport.unregister()

            // Now the same ssh:// scheme should fall back to ssh_exec: drive
            // it through a fake `ssh` script exactly like
            // RepositorySSHExecTests, and confirm it — not the provider —
            // carried this second fetch.
            let pidLog = tmp("ssh-pids")
            FileManager.default.createFile(atPath: pidLog.path, contents: nil)
            let script = try makeFakeSSHScript(pidLog: pidLog)

            let dest2 = tmp("GitSSHUnregisterDest2")
            let repo2 = try Repository.initialize(at: dest2, initialBranch: "main")
            try repo2.addRemote(name: "origin", url: URL(string: "ssh://localhost\(bare.path)")!)
            try repo2.configSet("core.sshCommand", script.path)
            try repo2.fetch(
                remote: "origin", refspec: "+refs/heads/*:refs/remotes/origin/*",
                progress: { _ in })

            let pidText = try String(contentsOf: pidLog, encoding: .utf8)
            #expect(!pidText.split(separator: "\n").isEmpty)
            #expect(provider.openedCommands.count == openedBeforeUnregister)
        }
    }
}
#endif

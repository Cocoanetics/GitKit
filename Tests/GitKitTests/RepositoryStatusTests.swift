// Integration tests that fork the system `git` via `Process` for parity
// checks. Windows has no `/usr/bin/env`, and the swift-android-action's
// MSVC clang doesn't see a stable `git.exe` path either, so gate the
// whole suite to non-Windows. Apple/Linux still cover the integration
// surface.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

@Suite("Repository.status")
struct RepositoryStatusTests {

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
        let message: String; init(_ m: String) { self.message = m }
        var description: String { message }
    }

    private func makeRepoMixedState() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "t@e.com"], in: dir)
        try runGit(["config", "user.name", "T"], in: dir)
        try Data("1\n".utf8).write(to: dir.appendingPathComponent("tracked.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)
        // Workdir: tracked.txt modified but not staged.
        try Data("modified\n".utf8).write(to: dir.appendingPathComponent("tracked.txt"))
        // Index: staged.txt is a brand-new staged file.
        try Data("staged\n".utf8).write(to: dir.appendingPathComponent("staged.txt"))
        try runGit(["add", "staged.txt"], in: dir)
        // Workdir: untracked.txt is a brand-new untracked file.
        try Data("untracked\n".utf8).write(to: dir.appendingPathComponent("untracked.txt"))
        return dir
    }

    @Test("status splits entries into staged / unstaged / untracked")
    func threeWaySplit() throws {
        let dir = try makeRepoMixedState()
        defer { try? FileManager.default.removeItem(at: dir) }

        let report = try Repository.open(at: dir).status()
        #expect(report.branchName == "main")
        #expect(report.isUnborn == false)
        #expect(report.stagedEntries.map(\.path) == ["staged.txt"])
        #expect(report.stagedEntries.first?.indexState == .newFile)
        #expect(report.unstagedEntries.map(\.path) == ["tracked.txt"])
        #expect(report.unstagedEntries.first?.workdirState == .modified)
        #expect(report.untrackedEntries.map(\.path) == ["untracked.txt"])
        #expect(report.isClean == false)
    }

    @Test("clean tree: no entries, isClean true")
    func cleanTree() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "t@e.com"], in: dir)
        try runGit(["config", "user.name", "T"], in: dir)
        try Data("x\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)

        let report = try Repository.open(at: dir).status()
        #expect(report.isClean)
        #expect(report.branchName == "main")
    }

    @Test("unborn HEAD: isUnborn=true, branchName still resolved")
    func unbornHead() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try runGit(["init", "-b", "main"], in: dir)
        try Data("x\n".utf8).write(to: dir.appendingPathComponent("a.txt"))

        let report = try Repository.open(at: dir).status()
        #expect(report.isUnborn)
        #expect(report.branchName == "main")
        #expect(report.untrackedEntries.map(\.path) == ["a.txt"])
    }

    @Test("short format matches `git status --porcelain` byte-for-byte")
    func shortFormatParity() throws {
        let dir = try makeRepoMixedState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ours = try Repository.open(at: dir)
            .status().shortFormat()
        let theirs = try runGit(["status", "--porcelain"], in: dir)
        #expect(ours == theirs)
    }

    @Test("verbose format matches `git status` byte-for-byte")
    func verboseFormatParity() throws {
        let dir = try makeRepoMixedState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ours = try Repository.open(at: dir)
            .status().verboseFormat()
        // Force the system git to print the `(use "git restore …")`
        // hint lines we emit. CI runners with newer git (or with
        // `advice.statusHints` disabled in /etc/gitconfig) suppress
        // them by default, which would diverge from our output.
        let theirs = try runGit(
            ["-c", "advice.statusHints=true", "status"], in: dir)
        #expect(ours == theirs)
    }

    @Test("short -b prints `## <branch>` header")
    func shortBranchHeader() throws {
        let dir = try makeRepoMixedState()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ours = try Repository.open(at: dir)
            .status().shortFormat(branchHeader: true)
        let theirs = try runGit(["status", "-sb"], in: dir)
        #expect(ours == theirs)
    }

    @Test("conflicted entries surface as isConflicted")
    func conflictedEntry() throws {
        // Build a real merge conflict via the CLI, then read status.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "t@e.com"], in: dir)
        try runGit(["config", "user.name", "T"], in: dir)
        try Data("1\n2\n3\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)
        try runGit(["checkout", "-b", "feat"], in: dir)
        try Data("1\n2\nFEAT\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["commit", "-am", "feat"], in: dir)
        try runGit(["checkout", "main"], in: dir)
        try Data("1\n2\nMAIN\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["commit", "-am", "main"], in: dir)
        // Force the conflict via real git's merge so we don't depend on our own.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "merge", "feat"]
        p.currentDirectoryURL = dir
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()  // exits 1, that's fine

        let report = try Repository.open(at: dir).status()
        #expect(report.conflictedEntries.map(\.path) == ["a.txt"])
    }
}
#endif

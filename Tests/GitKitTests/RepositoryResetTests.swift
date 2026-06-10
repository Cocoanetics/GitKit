// Integration tests that fork the system `git` via `Process` for parity
// checks. Windows has no `/usr/bin/env`, and the swift-android-action's
// MSVC clang doesn't see a stable `git.exe` path either, so gate the
// whole suite to non-Windows. Apple/Linux still cover the integration
// surface; Windows-side logic is covered by the unit-shape tests in
// `GitCommandTests` and `GitLabTests`.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

@Suite("Repository.reset")
struct RepositoryResetTests {

    private func makeRepoTwoCommits() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResetTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "t@e.com"], in: dir)
        try runGit(["config", "user.name", "T"], in: dir)
        try Data("1\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)
        try Data("2\n".utf8).write(to: dir.appendingPathComponent("b.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "second"], in: dir)
        return dir
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
        let message: String; init(_ m: String) { self.message = m }
        var description: String { message }
    }

    @Test("--soft moves HEAD only; index keeps the rolled-back files staged")
    func resetSoftKeepsIndex() throws {
        let dir = try makeRepoTwoCommits()
        defer { try? FileManager.default.removeItem(at: dir) }
        let initialHEAD = try runGit(["rev-parse", "HEAD"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try Repository.open(at: dir)
            .reset(to: "HEAD~1", mode: .soft)

        // HEAD moved.
        let newHEAD = try runGit(["rev-parse", "HEAD"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(newHEAD != initialHEAD)

        // b.txt should be staged (was committed in the rolled-back
        // commit; --soft keeps it in the index).
        let staged = try runGit(["diff", "--cached", "--name-only"], in: dir)
            .split(separator: "\n").map(String.init)
        #expect(staged == ["b.txt"])
    }

    @Test("--mixed (default) moves HEAD + clears index but keeps workdir")
    func resetMixedClearsIndex() throws {
        let dir = try makeRepoTwoCommits()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try Repository.open(at: dir)
            .reset(to: "HEAD~1", mode: .mixed)

        let staged = try runGit(["diff", "--cached", "--name-only"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(staged.isEmpty)
        // b.txt still on disk (workdir untouched).
        #expect(FileManager.default.fileExists(atPath:
            dir.appendingPathComponent("b.txt").path))
    }

    @Test("--hard resets workdir too")
    func resetHardClearsWorkdir() throws {
        let dir = try makeRepoTwoCommits()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outcome = try Repository.open(at: dir)
            .reset(to: "HEAD~1", mode: .hard)

        // b.txt should be GONE — --hard nukes it.
        #expect(!FileManager.default.fileExists(atPath:
            dir.appendingPathComponent("b.txt").path))

        guard case let .wholeTree(_, _, subject, mode) = outcome else {
            Issue.record("expected wholeTree, got \(outcome)"); return
        }
        #expect(mode == .hard)
        #expect(subject == "init")
    }

    @Test("per-path reset unstages without moving HEAD")
    func resetPathUnstages() throws {
        let dir = try makeRepoTwoCommits()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("modified\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["add", "a.txt"], in: dir)

        let beforeHEAD = try runGit(["rev-parse", "HEAD"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        _ = try Repository.open(at: dir)
            .reset(paths: ["a.txt"], from: "HEAD")

        // HEAD didn't move.
        let afterHEAD = try runGit(["rev-parse", "HEAD"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(beforeHEAD == afterHEAD)

        // a.txt no longer staged, but workdir change persists.
        let staged = try runGit(["diff", "--cached", "--name-only"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(staged.isEmpty)
        let unstaged = try runGit(["diff", "--name-only"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(unstaged == "a.txt")
    }
}
#endif

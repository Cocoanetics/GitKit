// Integration tests that fork the system `git` via `Process` for parity
// checks. Windows has no `/usr/bin/env`, and the swift-android-action's
// MSVC clang doesn't see a stable `git.exe` path either, so gate the
// whole suite to non-Windows. Apple/Linux still cover the integration
// surface.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

@Suite("Repository.add")
struct RepositoryAddTests {

    private func makeRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepositoryAddTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "t@e.com"], in: dir)
        try runGit(["config", "user.name", "T"], in: dir)
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
        let message: String
        init(_ m: String) { self.message = m }
        var description: String { message }
    }

    @Test("add with empty paths stages everything")
    func addEverything() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("a\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data("b\n".utf8).write(to: dir.appendingPathComponent("b.txt"))

        try Repository.open(at: dir).add(paths: [])

        let staged = try runGit(["diff", "--cached", "--name-only"], in: dir)
            .split(separator: "\n").map(String.init).sorted()
        #expect(staged == ["a.txt", "b.txt"])
    }

    @Test("add with explicit pathspec stages only that path")
    func addOnePath() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("a\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data("b\n".utf8).write(to: dir.appendingPathComponent("b.txt"))

        try Repository.open(at: dir).add(paths: ["a.txt"])

        let staged = try runGit(["diff", "--cached", "--name-only"], in: dir)
            .split(separator: "\n").map(String.init)
        #expect(staged == ["a.txt"])
    }

    @Test("add with multiple pathspecs stages each")
    func addMultiplePaths() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("a\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data("b\n".utf8).write(to: dir.appendingPathComponent("b.txt"))
        try Data("c\n".utf8).write(to: dir.appendingPathComponent("c.txt"))

        try Repository.open(at: dir).add(paths: ["a.txt", "c.txt"])

        let staged = try runGit(["diff", "--cached", "--name-only"], in: dir)
            .split(separator: "\n").map(String.init).sorted()
        #expect(staged == ["a.txt", "c.txt"])
    }

    @Test("add then commit produces a commit with only staged paths")
    func addThenCommit() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("a\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data("b\n".utf8).write(to: dir.appendingPathComponent("b.txt"))

        let repo = try Repository.open(at: dir)
        try repo.add(paths: ["a.txt"])
        let sha = try repo.commitDetailed(
            message: "init", author: nil, allowEmpty: false).sha
        #expect(sha.count == 40)

        // Commit no longer auto-stages, so the tree contains exactly
        // what we asked for — `a.txt` only, `b.txt` left in the
        // worktree as an untracked file.
        let tracked = try runGit(["ls-tree", "-r", "--name-only", "HEAD"], in: dir)
            .split(separator: "\n").map(String.init).sorted()
        #expect(tracked == ["a.txt"])
    }
}
#endif

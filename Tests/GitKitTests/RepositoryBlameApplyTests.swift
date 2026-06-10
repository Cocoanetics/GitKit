// Integration tests that fork the system `git` via `Process` for parity
// checks. Windows has no `/usr/bin/env`, and the swift-android-action's
// MSVC clang doesn't see a stable `git.exe` path either, so gate the
// whole suite to non-Windows. Apple/Linux still cover the integration
// surface.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

@Suite("Repository.blame + apply")
struct RepositoryBlameApplyTests {

    @discardableResult
    private func runGit(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = dir
        let out = Pipe(); let err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run(); p.waitUntilExit()
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

    private func makeRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlameApply-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "t@e.com"], in: dir)
        try runGit(["config", "user.name", "T"], in: dir)
        return dir
    }

    @Test("blame surfaces hunks per change")
    func blameHunks() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("line1\nline2\nline3\n".utf8)
            .write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)
        try Data("line1\nMODIFIED\nline3\n".utf8)
            .write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["commit", "-am", "edit"], in: dir)

        let hunks = try Repository.open(at: dir)
            .blame(path: "a.txt")
        // Should be three hunks (lines 1, 2, 3) covering 1 line each.
        #expect(hunks.count == 3)
        let totalLines = hunks.map(\.linesInHunk).reduce(0, +)
        #expect(totalLines == 3)
        // Line 2 is the modified one — its commit subject is `edit`.
        let line2 = hunks.first(where: { $0.startLine == 2 })
        #expect(line2?.summary == "edit")
    }

    @Test("apply against workdir mutates files")
    func applyToWorkdir() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("1\n2\n3\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)

        // Generate a real-git patch that flips line 2.
        try Data("1\nTWO\n3\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        let patch = try runGit(["diff", "a.txt"], in: dir)
        // Restore the file to baseline so `apply` actually has work to do.
        try runGit(["checkout", "--", "a.txt"], in: dir)

        try Repository.open(at: dir).apply(
            patch: Data(patch.utf8))
        let body = try String(contentsOf: dir.appendingPathComponent("a.txt"),
                              encoding: .utf8)
        #expect(body == "1\nTWO\n3\n")
    }

    @Test("apply --cached lands in the index without touching the workdir")
    func applyToIndex() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("1\n2\n3\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)

        try Data("1\nTWO\n3\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        let patch = try runGit(["diff", "a.txt"], in: dir)
        try runGit(["checkout", "--", "a.txt"], in: dir)

        try Repository.open(at: dir).apply(
            patch: Data(patch.utf8), location: .index)

        // Workdir untouched.
        let workdir = try String(contentsOf: dir.appendingPathComponent("a.txt"),
                                 encoding: .utf8)
        #expect(workdir == "1\n2\n3\n")
        // Index has the change.
        let staged = try runGit(["diff", "--cached"], in: dir)
        #expect(staged.contains("+TWO"))
    }
}
#endif

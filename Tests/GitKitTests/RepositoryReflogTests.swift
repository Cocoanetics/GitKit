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

@Suite("Repository.reflog")
struct RepositoryReflogTests {

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
            .appendingPathComponent("Reflog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "t@e.com"], in: dir)
        try runGit(["config", "user.name", "T"], in: dir)
        return dir
    }

    @Test("reflog returns one entry per commit, newest first")
    func reflogEntries() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("a\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "first"], in: dir)
        try Data("ab\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["commit", "-am", "second"], in: dir)
        try Data("abc\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["commit", "-am", "third"], in: dir)

        let entries = try Repository.open(at: dir).reflog()
        #expect(entries.count == 3)
        // Newest entry first — its message is "commit: third".
        #expect(entries[0].message.contains("third"))
        #expect(entries.last?.message.contains("first") ?? false)
        // Each entry carries committer identity from `git config`.
        for e in entries {
            #expect(e.committerEmail == "t@e.com")
            #expect(e.committerName == "T")
        }
    }

    @Test("reflog records HEAD's old → new SHA progression")
    func reflogShaProgression() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("a\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "first"], in: dir)
        try Data("ab\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["commit", "-am", "second"], in: dir)

        let entries = try Repository.open(at: dir).reflog()
        #expect(entries.count == 2)
        // Newest entry: old (first commit's SHA) → new (second commit's SHA);
        // its old should match the older entry's new.
        #expect(entries[0].oldSHA == entries[1].newSHA)
        // The very first commit has all-zero "old" SHA.
        let zeros = String(repeating: "0", count: 40)
        #expect(entries[1].oldSHA == zeros)
    }

    @Test("reflog of an unknown ref returns empty (libgit2 auto-creates the log)")
    func reflogUnknownRef() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("a\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "first"], in: dir)
        let entries = try Repository.open(at: dir)
            .reflog(refName: "refs/heads/no-such-branch")
        #expect(entries.isEmpty)
    }
}
#endif

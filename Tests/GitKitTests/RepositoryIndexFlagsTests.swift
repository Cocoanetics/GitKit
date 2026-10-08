// Integration tests that fork the system `git` via `Process` for parity
// checks — gated to Apple/Linux like the other parity suites.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

@Suite("Repository index entry flags")
struct RepositoryIndexFlagsTests {

    /// A repository with two committed files, `config.json` and `other.txt`.
    private func makeRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepositoryIndexFlagsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "t@e.com"], in: dir)
        try runGit(["config", "user.name", "T"], in: dir)
        try Data("{}\n".utf8).write(to: dir.appendingPathComponent("config.json"))
        try Data("other\n".utf8).write(to: dir.appendingPathComponent("other.txt"))
        try runGit(["add", "-A"], in: dir)
        try runGit(["commit", "-q", "-m", "initial"], in: dir)
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

    /// `git ls-files -v` as `[path: tag]`.
    private func lsFilesTags(in dir: URL) throws -> [String: String] {
        var tags: [String: String] = [:]
        for line in try runGit(["ls-files", "-v"], in: dir).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            tags[String(parts[1])] = String(parts[0])
        }
        return tags
    }

    @Test("isTracked matches git ls-files --error-unmatch for files, new files and directories")
    func isTracked() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("new\n".utf8).write(to: dir.appendingPathComponent("sub/new.txt"))

        let repo = try Repository.open(at: dir)
        #expect(try repo.isTracked(path: "config.json"))
        #expect(try !repo.isTracked(path: "sub/new.txt"))
        #expect(try !repo.isTracked(path: "missing.txt"))
        #expect(try !repo.isTracked(path: "sub"))
    }

    @Test("isTracked sees a path git added after the repository was opened")
    func isTrackedRereadsTheIndex() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try Repository.open(at: dir)
        #expect(try !repo.isTracked(path: "late.txt"))

        try Data("late\n".utf8).write(to: dir.appendingPathComponent("late.txt"))
        try runGit(["add", "late.txt"], in: dir)
        #expect(try repo.isTracked(path: "late.txt"))
    }

    @Test("setSkipWorktree matches git update-index --skip-worktree and ls-files -v")
    func skipWorktreeParity() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try Repository.open(at: dir)

        try repo.setSkipWorktree(true, path: "config.json")
        #expect(try lsFilesTags(in: dir) == ["config.json": "S", "other.txt": "H"])
        let entry = try repo.indexedEntries().first { $0.path == "config.json" }
        #expect(entry?.skipWorktree == true)
        #expect(entry?.lsFilesTag == "S")

        try repo.setSkipWorktree(false, path: "config.json")
        #expect(try lsFilesTags(in: dir)["config.json"] == "H")
        #expect(try repo.indexedEntries().first { $0.path == "config.json" }?.skipWorktree == false)
    }

    @Test("GitKit reads a skip-worktree bit that git set")
    func readsGitsSkipWorktree() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try runGit(["update-index", "--skip-worktree", "config.json"], in: dir)
        try runGit(["update-index", "--assume-unchanged", "other.txt"], in: dir)

        let entries = try Repository.open(at: dir).indexedEntries()
        let tags = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, String($0.lsFilesTag)) })
        #expect(tags == (try lsFilesTags(in: dir)))
        #expect(tags == ["config.json": "S", "other.txt": "h"])
    }

    @Test("setAssumeUnchanged matches git update-index --assume-unchanged")
    func assumeUnchangedParity() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try Repository.open(at: dir)

        try repo.setAssumeUnchanged(true, path: "other.txt")
        #expect(try lsFilesTags(in: dir)["other.txt"] == "h")
        #expect(try repo.indexedEntries().first { $0.path == "other.txt" }?.assumeUnchanged == true)

        try repo.setAssumeUnchanged(false, path: "other.txt")
        #expect(try lsFilesTags(in: dir)["other.txt"] == "H")
    }

    @Test("a skip-worktree file's local change is neither reported nor staged")
    func skipWorktreeKeepsChangesOutOfStageAll() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try Repository.open(at: dir)
        try repo.setSkipWorktree(true, path: "config.json")

        try Data("{\"secret\":\"token\"}\n".utf8).write(to: dir.appendingPathComponent("config.json"))
        try Data("changed\n".utf8).write(to: dir.appendingPathComponent("other.txt"))

        // git's view.
        #expect(try runGit(["status", "--porcelain"], in: dir) == " M other.txt\n")
        // GitKit's own stage-all.
        try repo.add(paths: [])
        let staged = try runGit(["diff", "--cached", "--name-only"], in: dir)
            .split(separator: "\n").map(String.init)
        #expect(staged == ["other.txt"])
        #expect(try lsFilesTags(in: dir)["config.json"] == "S")
    }

    @Test("an untracked path throws like git's 'Unable to mark file'")
    func untrackedPathThrows() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("new\n".utf8).write(to: dir.appendingPathComponent("new.txt"))
        let repo = try Repository.open(at: dir)
        #expect(throws: Libgit2Error.self) { try repo.setSkipWorktree(true, path: "new.txt") }
        #expect(throws: Libgit2Error.self) { try repo.setAssumeUnchanged(true, path: "missing.txt") }
    }

    @Test("a held index.lock throws isLocked and leaves the index unchanged")
    func heldLockThrowsWithoutChangingTheIndex() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try Repository.open(at: dir)
        let before = try Data(contentsOf: dir.appendingPathComponent(".git/index"))
        let lock = dir.appendingPathComponent(".git/index.lock")
        try Data().write(to: lock)

        do {
            try repo.setSkipWorktree(true, path: "config.json")
            Issue.record("expected the held index.lock to fail the write")
        } catch let error as Libgit2Error {
            #expect(error.isLocked, "\(error)")
        }
        #expect(try Data(contentsOf: dir.appendingPathComponent(".git/index")) == before)
        #expect(try repo.indexedEntries().first { $0.path == "config.json" }?.skipWorktree == false)

        // Once the lock is gone the same call succeeds.
        try FileManager.default.removeItem(at: lock)
        try repo.setSkipWorktree(true, path: "config.json")
        #expect(try lsFilesTags(in: dir)["config.json"] == "S")
    }
}
#endif

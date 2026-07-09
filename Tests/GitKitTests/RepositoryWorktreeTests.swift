// Integration tests that fork the system `git` only for fixture setup.
// Windows has no `/usr/bin/env`, and the swift-android-action's MSVC
// clang doesn't see a stable `git.exe` path either, so gate the suite to
// non-Windows.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

@Suite("Repository worktrees")
struct RepositoryWorktreeTests {

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

    private func makeRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorktreeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "t@e.com"], in: dir)
        try runGit(["config", "user.name", "T"], in: dir)
        try Data("v\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)
        return dir
    }

    private func siblingWorktree(of repo: URL) -> URL {
        repo.deletingLastPathComponent()
            .appendingPathComponent("linked-\(UUID().uuidString)")
    }

    private func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    @Test("add creates branch, list reports metadata, remove deletes directory")
    func addListRemoveRoundTrip() throws {
        let dir = try makeRepo()
        let worktree = siblingWorktree(of: dir)
        defer { try? FileManager.default.removeItem(at: worktree) }
        defer { try? FileManager.default.removeItem(at: dir) }

        let repo = try Repository.open(at: dir)
        let head = try repo.resolveOID("HEAD")
        try repo.worktreeAdd(path: worktree, branch: "feature/worktree")

        #expect(FileManager.default.fileExists(atPath: worktree.path))
        #expect(try Repository.open(at: worktree).currentBranch() == "feature/worktree")
        #expect(try repo.localBranches().contains("feature/worktree"))

        let info = try #require(repo.worktreeList().first)
        #expect(info.name == worktree.lastPathComponent)
        #expect(canonicalPath(info.path) == canonicalPath(worktree))
        #expect(info.head == head)
        #expect(info.isLocked == false)
        #expect(info.isPrunable == false)

        try repo.worktreeRemove(name: info.name)
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
        #expect(try repo.worktreeList().isEmpty)
    }

    @Test("add can check out an existing branch")
    func addExistingBranch() throws {
        let dir = try makeRepo()
        let worktree = siblingWorktree(of: dir)
        defer { try? FileManager.default.removeItem(at: worktree) }
        defer { try? FileManager.default.removeItem(at: dir) }

        try runGit(["branch", "existing"], in: dir)
        let repo = try Repository.open(at: dir)
        try repo.worktreeAdd(path: worktree, branch: "existing")

        #expect(try Repository.open(at: worktree).currentBranch() == "existing")
        let info = try #require(repo.worktreeList().first)
        try repo.worktreeRemove(name: info.name)
    }

    @Test("remove refuses dirty worktree unless forced")
    func removeDirtyRequiresForce() throws {
        let dir = try makeRepo()
        let worktree = siblingWorktree(of: dir)
        defer { try? FileManager.default.removeItem(at: worktree) }
        defer { try? FileManager.default.removeItem(at: dir) }

        let repo = try Repository.open(at: dir)
        try repo.worktreeAdd(path: worktree, branch: "dirty-worktree")
        let info = try #require(repo.worktreeList().first)

        try Data("local\n".utf8).write(to: worktree.appendingPathComponent("local.txt"))
        #expect(throws: Libgit2Error.self) {
            try repo.worktreeRemove(name: info.name)
        }
        #expect(FileManager.default.fileExists(atPath: worktree.path))

        try repo.worktreeRemove(name: info.name, force: true)
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
        #expect(try repo.worktreeList().isEmpty)
    }
}
#endif

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

    private func makeSubmoduleSource() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorktreeSubmodule-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "t@e.com"], in: dir)
        try runGit(["config", "user.name", "T"], in: dir)
        try Data("sub\n".utf8).write(to: dir.appendingPathComponent("sub.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "submodule init"], in: dir)
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

        let allWorktrees = try repo.worktreeList()
        #expect(allWorktrees.count == 2)
        #expect(canonicalPath(allWorktrees[0].path) == canonicalPath(dir))
        #expect(allWorktrees[0].name == dir.lastPathComponent)
        #expect(allWorktrees[0].head == head)
        #expect(allWorktrees[0].isLocked == false)
        #expect(allWorktrees[0].isPrunable == false)

        let info = try #require(repo.linkedWorktreeList().first)
        #expect(info.name == worktree.lastPathComponent)
        #expect(canonicalPath(info.path) == canonicalPath(worktree))
        #expect(info.head == head)
        #expect(info.isLocked == false)
        #expect(info.isPrunable == false)

        try repo.worktreeRemove(name: info.name)
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
        #expect(try repo.linkedWorktreeList().isEmpty)
        #expect(try repo.worktreeList().count == 1)
    }

    @Test("list reports primary first when opened from linked worktree")
    func listFromLinkedWorktreeReportsPrimaryFirst() throws {
        let dir = try makeRepo()
        let worktree = siblingWorktree(of: dir)
        defer { try? FileManager.default.removeItem(at: worktree) }
        defer { try? FileManager.default.removeItem(at: dir) }

        let repo = try Repository.open(at: dir)
        try repo.worktreeAdd(path: worktree, branch: "linked-list")
        try Data("linked\n".utf8).write(to: worktree.appendingPathComponent("linked.txt"))
        try runGit(["add", "."], in: worktree)
        try runGit(["commit", "-m", "linked commit"], in: worktree)

        let mainHead = try runGit(["rev-parse", "HEAD"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let linkedHead = try runGit(["rev-parse", "HEAD"], in: worktree)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let linkedRepo = try Repository.open(at: worktree)
        let infos = try linkedRepo.worktreeList()
        #expect(infos.count == 2)
        #expect(canonicalPath(infos[0].path) == canonicalPath(dir))
        #expect(infos[0].head == mainHead)

        let linkedInfo = try #require(infos.first {
            canonicalPath($0.path) == canonicalPath(worktree)
        })
        #expect(linkedInfo.head == linkedHead)
        #expect(Set(infos.map { canonicalPath($0.path) }).count == infos.count)
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
        let info = try #require(repo.linkedWorktreeList().first)
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
        let info = try #require(repo.linkedWorktreeList().first)

        try Data("local\n".utf8).write(to: worktree.appendingPathComponent("local.txt"))
        #expect(throws: Libgit2Error.self) {
            try repo.worktreeRemove(name: info.name)
        }
        #expect(FileManager.default.fileExists(atPath: worktree.path))

        try repo.worktreeRemove(name: info.name, force: true)
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
        #expect(try repo.linkedWorktreeList().isEmpty)
        #expect(try repo.worktreeList().count == 1)
    }

    @Test("add chooses unique names for duplicate path basenames")
    func addDuplicateBasenames() throws {
        let dir = try makeRepo()
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorktreeParents-\(UUID().uuidString)")
        let first = parent.appendingPathComponent("one/wt")
        let second = parent.appendingPathComponent("two/wt")
        try FileManager.default.createDirectory(
            at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        defer { try? FileManager.default.removeItem(at: dir) }

        let repo = try Repository.open(at: dir)
        try repo.worktreeAdd(path: first, branch: "duplicate-one")
        try repo.worktreeAdd(path: second, branch: "duplicate-two")

        let infos = try repo.linkedWorktreeList()
        let firstInfo = try #require(infos.first { canonicalPath($0.path) == canonicalPath(first) })
        let secondInfo = try #require(infos.first { canonicalPath($0.path) == canonicalPath(second) })
        #expect(firstInfo.name == "wt")
        #expect(secondInfo.name == "wt1")

        try repo.worktreeRemove(name: firstInfo.name)
        try repo.worktreeRemove(name: secondInfo.name)
    }

    @Test("add creates missing branch at an explicit start point")
    func addCreatesBranchAtStartPoint() throws {
        let dir = try makeRepo()
        let worktree = siblingWorktree(of: dir)
        defer { try? FileManager.default.removeItem(at: worktree) }
        defer { try? FileManager.default.removeItem(at: dir) }

        let firstCommit = try runGit(["rev-parse", "HEAD"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try Data("v2\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["commit", "-am", "second"], in: dir)

        let repo = try Repository.open(at: dir)
        try repo.worktreeAdd(
            path: worktree, branch: "from-start-point", startPoint: firstCommit)

        #expect(try Repository.open(at: worktree).currentBranch() == "from-start-point")
        #expect(try repo.resolveOID("from-start-point") == firstCommit)

        let info = try #require(repo.linkedWorktreeList().first)
        try repo.worktreeRemove(name: info.name)
    }

    @Test("add tracks a remote-tracking start point, like git worktree add")
    func addTracksRemoteTrackingStartPoint() throws {
        let origin = try makeRepo()
        defer { try? FileManager.default.removeItem(at: origin) }

        let clone = origin.deletingLastPathComponent()
            .appendingPathComponent("clone-\(UUID().uuidString)")
        try runGit(["clone", origin.path, clone.path], in: origin.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: clone) }

        let worktree = siblingWorktree(of: clone)
        defer { try? FileManager.default.removeItem(at: worktree) }

        let repo = try Repository.open(at: clone)
        try repo.worktreeAdd(
            path: worktree, branch: "feature-from-origin", startPoint: "origin/main")

        #expect(try Repository.open(at: worktree).currentBranch() == "feature-from-origin")
        #expect(try repo.upstreamBranch(of: "feature-from-origin") == "origin/main")

        let info = try #require(repo.linkedWorktreeList().first)
        try repo.worktreeRemove(name: info.name)
    }

    @Test("prune removes administrative data for worktrees whose directory is gone")
    func pruneRemovesMissingWorktree() throws {
        let dir = try makeRepo()
        let worktree = siblingWorktree(of: dir)
        defer { try? FileManager.default.removeItem(at: worktree) }
        defer { try? FileManager.default.removeItem(at: dir) }

        let repo = try Repository.open(at: dir)
        try repo.worktreeAdd(path: worktree, branch: "prune-me")
        let info = try #require(repo.linkedWorktreeList().first)

        try FileManager.default.removeItem(at: worktree)

        let pruned = try repo.worktreePrune()
        #expect(pruned == [info.name])
        #expect(try repo.linkedWorktreeList().isEmpty)
        #expect(try repo.worktreeList().count == 1)
    }

    @Test("prune leaves worktrees with a present directory untouched")
    func pruneLeavesPresentWorktreeAlone() throws {
        let dir = try makeRepo()
        let worktree = siblingWorktree(of: dir)
        defer { try? FileManager.default.removeItem(at: worktree) }
        defer { try? FileManager.default.removeItem(at: dir) }

        let repo = try Repository.open(at: dir)
        try repo.worktreeAdd(path: worktree, branch: "keep-me")
        let info = try #require(repo.linkedWorktreeList().first)

        let pruned = try repo.worktreePrune()
        #expect(pruned.isEmpty)
        #expect(try repo.linkedWorktreeList().map(\.name) == [info.name])

        try repo.worktreeRemove(name: info.name)
    }

    @Test("prune leaves a locked worktree's administrative data alone")
    func pruneLeavesLockedWorktreeAlone() throws {
        let dir = try makeRepo()
        let worktree = siblingWorktree(of: dir)
        defer { try? FileManager.default.removeItem(at: worktree) }
        defer { try? FileManager.default.removeItem(at: dir) }

        let repo = try Repository.open(at: dir)
        try repo.worktreeAdd(path: worktree, branch: "locked-prune")
        let info = try #require(repo.linkedWorktreeList().first)
        try runGit(["worktree", "lock", worktree.path], in: dir)
        try FileManager.default.removeItem(at: worktree)

        let pruned = try repo.worktreePrune()
        #expect(pruned.isEmpty)
        #expect(try repo.linkedWorktreeList().map(\.name) == [info.name])

        try runGit(["worktree", "unlock", info.name], in: dir)
        try repo.worktreeRemove(name: info.name, force: true)
    }

    @Test("remove refuses checked-out submodules unless forced")
    func removeSubmoduleRequiresForce() throws {
        let submoduleSource = try makeSubmoduleSource()
        let dir = try makeRepo()
        let worktree = siblingWorktree(of: dir)
        defer { try? FileManager.default.removeItem(at: worktree) }
        defer { try? FileManager.default.removeItem(at: dir) }
        defer { try? FileManager.default.removeItem(at: submoduleSource) }

        try runGit([
            "-c", "protocol.file.allow=always",
            "submodule", "add", submoduleSource.path, "deps/sub"
        ], in: dir)
        try runGit(["commit", "-m", "add submodule"], in: dir)

        let repo = try Repository.open(at: dir)
        try repo.worktreeAdd(path: worktree, branch: "submodule-worktree")
        try runGit([
            "-c", "protocol.file.allow=always",
            "submodule", "update", "--init"
        ], in: worktree)

        let info = try #require(repo.linkedWorktreeList().first)
        #expect(try Repository.open(at: worktree).status().isClean)
        #expect(throws: Libgit2Error.self) {
            try repo.worktreeRemove(name: info.name)
        }
        #expect(FileManager.default.fileExists(atPath: worktree.path))

        try repo.worktreeRemove(name: info.name, force: true)
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
    }
}
#endif

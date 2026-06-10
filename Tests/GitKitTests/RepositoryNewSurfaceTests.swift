// Integration tests that fork the system `git` via `Process` for parity
// checks. Windows has no `/usr/bin/env`, and the swift-android-action's
// MSVC clang doesn't see a stable `git.exe` path either, so gate the
// whole suite to non-Windows. Apple/Linux still cover the integration
// surface.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

/// Round-trip tests for the late-additions to Repository (branch
/// delete/rename, rev-parse helpers, mv/rm). The tag suite lives in
/// `RepositoryTagTests.swift`.
@Suite("Repository new surface")
struct RepositoryNewSurfaceTests {

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
            .appendingPathComponent("NewSurface-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "t@e.com"], in: dir)
        try runGit(["config", "user.name", "T"], in: dir)
        try Data("v\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)
        return dir
    }

    @Test("branchDelete removes a fully-merged branch")
    func deleteFullyMerged() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try Repository.open(at: dir)
        _ = try repo.checkoutNewBranch(name: "feat")
        try repo.checkout(ref: "main")
        try repo.branchDelete(name: "feat")
        let names = try repo.localBranches()
        #expect(names == ["main"])
    }

    @Test("branchDelete refuses an unmerged branch without force")
    func deleteUnmergedRefused() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try Repository.open(at: dir)
        _ = try repo.checkoutNewBranch(name: "feat")
        try Data("feat\n".utf8).write(to: dir.appendingPathComponent("b.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "feat"], in: dir)
        // The CLI moved the index + refs behind the open handle —
        // re-open, like the per-call GitClient effectively did.
        let reopened = try Repository.open(at: dir)
        try reopened.checkout(ref: "main")
        #expect(throws: Libgit2Error.self) {
            try reopened.branchDelete(name: "feat", force: false)
        }
        // Force delete works.
        try reopened.branchDelete(name: "feat", force: true)
    }

    @Test("branchRename moves the ref")
    func rename() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try Repository.open(at: dir)
        _ = try repo.checkoutNewBranch(name: "feat")
        try repo.branchRename(to: "feat-renamed")
        let names = try repo.localBranches().sorted()
        #expect(names == ["feat-renamed", "main"])
    }

    @Test("resolveOID resolves HEAD")
    func resolveOIDHead() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sha = try Repository.open(at: dir)
            .resolveOID("HEAD")
        #expect(sha.count == 40)
        let theirs = try runGit(["rev-parse", "HEAD"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(sha == theirs)
    }

    @Test("isInsideWorkTree true inside repo, false outside")
    func insideWorkTree() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try Repository.open(at: dir).isInsideWorkTree() == true)

        let outsideDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-repo-\(UUID())")
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        // Outside a repo it's `Repository.open` itself that fails — the
        // old GitClient mapped that failure to `false`; do the same here.
        let outsideIsWorkTree: Bool
        do {
            outsideIsWorkTree = try Repository.open(at: outsideDir).isInsideWorkTree()
        } catch {
            outsideIsWorkTree = false
        }
        #expect(outsideIsWorkTree == false)
    }

    @Test("move stages the rename in the index and on disk")
    func moveStages() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Repository.open(at: dir).move(from: "a.txt", to: "renamed.txt")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.txt").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("renamed.txt").path))
        let staged = try runGit(["diff", "--cached", "--name-status"], in: dir)
        #expect(staged.contains("renamed.txt") || staged.contains("R"))
    }

    @Test("remove with keepWorktree=false deletes file + index entry")
    func removeAlsoDeletesFile() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Repository.open(at: dir).remove(paths: ["a.txt"])
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.txt").path))
        let staged = try runGit(["diff", "--cached", "--name-status"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(staged == "D\ta.txt")
    }

    @Test("remove keepWorktree=true leaves file but stages deletion")
    func removeKeepsFile() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Repository.open(at: dir)
            .remove(paths: ["a.txt"], keepWorktree: true)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.txt").path))
        let staged = try runGit(["diff", "--cached", "--name-status"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(staged.contains("D\ta.txt"))
    }
}
#endif

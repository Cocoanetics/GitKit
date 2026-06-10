// Integration tests that fork the system `git` via `Process` for parity
// checks. Windows has no `/usr/bin/env`, and the swift-android-action's
// MSVC clang doesn't see a stable `git.exe` path either, so gate the
// whole suite to non-Windows. Apple/Linux still cover the integration
// surface.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

@Suite("Repository.rebase")
struct RepositoryRebaseTests {

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

    /// Build a divergent repo: `main` advanced by `trunk`, `feature`
    /// advanced by `feat1`+`feat2`. Both branched off the same root.
    /// Working dir left checked-out to feature.
    private func makeDivergentRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RebaseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "t@e.com"], in: dir)
        try runGit(["config", "user.name", "T"], in: dir)
        try Data("1\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)

        try runGit(["checkout", "-b", "feature"], in: dir)
        try Data("feat1\n".utf8).write(to: dir.appendingPathComponent("b.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "feat1"], in: dir)
        try Data("feat1\nfeat2\n".utf8).write(to: dir.appendingPathComponent("b.txt"))
        try runGit(["commit", "-am", "feat2"], in: dir)

        try runGit(["checkout", "main"], in: dir)
        try Data("trunk\n".utf8).write(to: dir.appendingPathComponent("t.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "trunk"], in: dir)

        try runGit(["checkout", "feature"], in: dir)
        return dir
    }

    @Test("clean rebase replays both commits onto upstream")
    func cleanRebase() throws {
        let dir = try makeDivergentRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let originalFeatureSHA = try runGit(["rev-parse", "feature"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let outcome = try Repository.open(at: dir).rebase(
            upstream: "main",
            author: Signature(name: "T", email: "t@e.com"))
        guard case let .completed(refName, applied) = outcome else {
            Issue.record("expected completed, got \(outcome)"); return
        }
        #expect(applied == 2)
        #expect(refName.hasSuffix("/feature"))

        // After rebase, feature's tip must differ from before but its
        // history must include trunk.
        let newFeatureSHA = try runGit(["rev-parse", "feature"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(originalFeatureSHA != newFeatureSHA)
        let history = try runGit(["log", "--format=%s", "feature"], in: dir)
            .split(separator: "\n").map(String.init)
        #expect(history == ["feat2", "feat1", "trunk", "init"])
    }

    @Test("alreadyUpToDate when feature has no commits past upstream")
    func alreadyUpToDate() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RebaseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "t@e.com"], in: dir)
        try runGit(["config", "user.name", "T"], in: dir)
        try Data("x\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)
        try runGit(["checkout", "-b", "feature"], in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcome = try Repository.open(at: dir).rebase(
            upstream: "main",
            author: Signature(name: "T", email: "t@e.com"))
        guard case let .alreadyUpToDate(refName) = outcome else {
            Issue.record("expected alreadyUpToDate, got \(outcome)"); return
        }
        #expect(refName?.hasSuffix("/feature") == true)
    }

    @Test("conflict surfaces commit info, paths, and persists rebase state")
    func conflictPath() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RebaseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "t@e.com"], in: dir)
        try runGit(["config", "user.name", "T"], in: dir)
        try Data("1\n2\n3\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)
        try runGit(["checkout", "-b", "feature"], in: dir)
        try Data("1\n2\nFEAT\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["commit", "-am", "feat"], in: dir)
        try runGit(["checkout", "main"], in: dir)
        try Data("1\n2\nMAIN\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["commit", "-am", "main"], in: dir)
        try runGit(["checkout", "feature"], in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcome = try Repository.open(at: dir).rebase(
            upstream: "main",
            author: Signature(name: "T", email: "t@e.com"))
        guard case let .conflict(sha, subject, paths) = outcome else {
            Issue.record("expected conflict, got \(outcome)"); return
        }
        #expect(sha.count == 7)
        #expect(subject == "feat")
        #expect(paths == ["a.txt"])

        // libgit2 should have left .git/rebase-merge in place.
        let rebaseDir = dir.appendingPathComponent(".git/rebase-merge")
        #expect(FileManager.default.fileExists(atPath: rebaseDir.path))
    }

    @Test("rebaseAbort wipes an in-progress conflicting rebase")
    func abortAfterConflict() throws {
        // Re-use the conflict scenario, then abort and verify state.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RebaseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "t@e.com"], in: dir)
        try runGit(["config", "user.name", "T"], in: dir)
        try Data("1\n2\n3\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)
        try runGit(["checkout", "-b", "feature"], in: dir)
        try Data("1\n2\nFEAT\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["commit", "-am", "feat"], in: dir)
        try runGit(["checkout", "main"], in: dir)
        try Data("1\n2\nMAIN\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["commit", "-am", "main"], in: dir)
        try runGit(["checkout", "feature"], in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let repo = try Repository.open(at: dir)
        _ = try repo.rebase(
            upstream: "main",
            author: Signature(name: "T", email: "t@e.com"))

        // The old client re-opened the repo per call; rebase state lives
        // on disk, so a fresh handle is the faithful translation.
        try Repository.open(at: dir).rebaseAbort()
        // .git/rebase-merge should be gone, working tree restored.
        let rebaseDir = dir.appendingPathComponent(".git/rebase-merge")
        #expect(!FileManager.default.fileExists(atPath: rebaseDir.path))
        let body = try String(contentsOf: dir.appendingPathComponent("a.txt"),
                              encoding: .utf8)
        #expect(body == "1\n2\nFEAT\n")
    }

    @Test("rebaseSkip drops the conflicting commit and continues")
    func skipDropsCommit() throws {
        // Conflict on commit #1, clean commit #2 follows. Skip should
        // discard #1 and apply #2.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RebaseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "t@e.com"], in: dir)
        try runGit(["config", "user.name", "T"], in: dir)
        try Data("1\n2\n3\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)
        try runGit(["checkout", "-b", "feature"], in: dir)
        try Data("1\n2\nFEAT\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["commit", "-am", "feat-conflict"], in: dir)
        try Data("ok\n".utf8).write(to: dir.appendingPathComponent("b.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "feat-clean"], in: dir)
        try runGit(["checkout", "main"], in: dir)
        try Data("1\n2\nMAIN\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["commit", "-am", "main"], in: dir)
        try runGit(["checkout", "feature"], in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let repo = try Repository.open(at: dir)
        _ = try repo.rebase(
            upstream: "main",
            author: Signature(name: "T", email: "t@e.com"))

        // Fresh handle per call, matching the old per-call client.
        let outcome = try Repository.open(at: dir).rebaseSkip(
            author: Signature(name: "T", email: "t@e.com"))
        guard case .completed = outcome else {
            Issue.record("expected completed, got \(outcome)"); return
        }

        // History should now be: feat-clean, main, init — no feat-conflict.
        let subjects = try runGit(["log", "--format=%s"], in: dir)
            .split(separator: "\n").map(String.init)
        #expect(subjects == ["feat-clean", "main", "init"])
    }

    @Test("rebaseAbort throws when no rebase is in progress")
    func abortWithoutRebase() throws {
        let dir = try makeDivergentRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        let repo = try Repository.open(at: dir)
        #expect(throws: Libgit2Error.self) {
            try repo.rebaseAbort()
        }
    }
}
#endif

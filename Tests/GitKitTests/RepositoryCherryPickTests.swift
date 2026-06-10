// Integration tests that fork the system `git` via `Process` for parity
// checks. Windows has no `/usr/bin/env`, and the swift-android-action's
// MSVC clang doesn't see a stable `git.exe` path either, so gate the
// whole suite to non-Windows. Apple/Linux still cover the integration
// surface.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

@Suite("Repository.cherry-pick")
struct RepositoryCherryPickTests {

    private func makeRepoForCherryPick() throws -> URL {
        // Two divergent branches: main (just init), feature (init + b.txt).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CherryPickTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "t@e.com"], in: dir)
        try runGit(["config", "user.name", "T"], in: dir)
        try Data("1\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)
        try runGit(["checkout", "-b", "feature"], in: dir)
        try Data("feat\n".utf8).write(to: dir.appendingPathComponent("b.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "feat work"], in: dir)
        try runGit(["checkout", "main"], in: dir)
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

    @Test("clean cherry-pick brings the commit's tree to HEAD")
    func cleanCherryPick() throws {
        let dir = try makeRepoForCherryPick()
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcome = try Repository.open(at: dir)
            .cherryPick("feature")
        guard case let .completed(_, shortSHA, branchName, subject, _, summary, added, _) = outcome else {
            Issue.record("expected completed, got \(outcome)"); return
        }
        #expect(shortSHA.count == 7)
        #expect(branchName == "main")
        #expect(subject == "feat work")
        #expect(summary.contains("file changed"))
        #expect(added.contains(where: { $0.contains("b.txt") }))
        // History is now [feat work, init].
        let history = try runGit(["log", "--format=%s"], in: dir)
            .split(separator: "\n").map(String.init)
        #expect(history == ["feat work", "init"])
    }

    @Test("conflict surfaces commit info + paths and persists CHERRY_PICK_HEAD")
    func conflictPath() throws {
        let dir = try makeRepoForCherryPick()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Make feature and main both modify a.txt to create a conflict
        // when cherry-picking the feature commit.
        try runGit(["checkout", "feature"], in: dir)
        try Data("1\nFEAT\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["commit", "-am", "edit a"], in: dir)
        try runGit(["checkout", "main"], in: dir)
        try Data("1\nMAIN\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["commit", "-am", "main edit"], in: dir)

        let outcome = try Repository.open(at: dir)
            .cherryPick("feature")
        guard case let .conflict(sha, subject, paths) = outcome else {
            Issue.record("expected conflict, got \(outcome)"); return
        }
        #expect(sha.count == 7)
        #expect(subject == "edit a")
        #expect(paths == ["a.txt"])

        // CHERRY_PICK_HEAD should now exist.
        let cph = dir.appendingPathComponent(".git/CHERRY_PICK_HEAD")
        #expect(FileManager.default.fileExists(atPath: cph.path))

        // Working tree contains conflict markers.
        let body = try String(contentsOf: dir.appendingPathComponent("a.txt"),
                              encoding: .utf8)
        #expect(body.contains("<<<<<<< HEAD"))
        #expect(body.contains(">>>>>>> "))
    }

    @Test("abort wipes the in-progress cherry-pick")
    func abortRestoresState() throws {
        let dir = try makeRepoForCherryPick()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Set up the same conflict as above.
        try runGit(["checkout", "feature"], in: dir)
        try Data("1\nFEAT\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["commit", "-am", "edit a"], in: dir)
        try runGit(["checkout", "main"], in: dir)
        try Data("1\nMAIN\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["commit", "-am", "main edit"], in: dir)

        let repo = try Repository.open(at: dir)
        _ = try repo.cherryPick("feature")
        // Fresh handle per call, matching the old per-call client; the
        // cherry-pick conflict state lives on disk.
        try Repository.open(at: dir).cherryPickAbort()

        let cph = dir.appendingPathComponent(".git/CHERRY_PICK_HEAD")
        #expect(!FileManager.default.fileExists(atPath: cph.path))
        // a.txt restored to MAIN content (HEAD), no conflict markers.
        let body = try String(contentsOf: dir.appendingPathComponent("a.txt"),
                              encoding: .utf8)
        #expect(!body.contains("<<<<<<<"))
        #expect(body == "1\nMAIN\n")
    }

    @Test("abort throws when no cherry-pick is in progress")
    func abortWithoutInProgress() throws {
        let dir = try makeRepoForCherryPick()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try Repository.open(at: dir)
        #expect(throws: Libgit2Error.self) {
            try repo.cherryPickAbort()
        }
    }

    @Test("continue after manual conflict resolution writes the commit")
    func continueAfterResolution() throws {
        let dir = try makeRepoForCherryPick()
        defer { try? FileManager.default.removeItem(at: dir) }
        try runGit(["checkout", "feature"], in: dir)
        try Data("1\nFEAT\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["commit", "-am", "edit a"], in: dir)
        try runGit(["checkout", "main"], in: dir)
        try Data("1\nMAIN\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["commit", "-am", "main edit"], in: dir)

        let repo = try Repository.open(at: dir)
        _ = try repo.cherryPick("feature")
        // Resolve: take FEAT side, stage.
        try Data("1\nFEAT\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["add", "a.txt"], in: dir)

        // The CLI `git add` mutated the index behind the handle —
        // re-open so cherryPickContinue sees the staged resolution.
        let outcome = try Repository.open(at: dir).cherryPickContinue()
        guard case .completed = outcome else {
            Issue.record("expected completed, got \(outcome)"); return
        }
        let cph = dir.appendingPathComponent(".git/CHERRY_PICK_HEAD")
        #expect(!FileManager.default.fileExists(atPath: cph.path))
    }
}
#endif

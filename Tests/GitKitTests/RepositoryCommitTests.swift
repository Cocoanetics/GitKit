// Integration tests that fork the system `git` via `Process` for parity
// checks. Windows has no `/usr/bin/env`, and the swift-android-action's
// MSVC clang doesn't see a stable `git.exe` path either, so gate the
// whole suite to non-Windows. Apple/Linux still cover the integration
// surface.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

@Suite("Repository.commit")
struct RepositoryCommitTests {

    /// Build a tmp repo using the `git` CLI for setup. The CLI is *only*
    /// for fixture creation; everything we assert against goes through
    /// `Repository` so the test exercises libgit2 end-to-end.
    private func makeRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepositoryCommitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "test@example.com"], in: dir)
        try runGit(["config", "user.name", "Test"], in: dir)
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

    @Test("first commit on unborn HEAD")
    func firstCommit() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("hello\n".utf8).write(to: dir.appendingPathComponent("README.md"))

        let repo = try Repository.open(at: dir)
        // `commitDetailed` records the index; stage the new file first.
        try repo.add(paths: [])
        let sha = try repo.commitDetailed(
            message: "init",
            author: Signature(name: "Test", email: "t@example.com"),
            allowEmpty: false).sha

        #expect(sha.count == 40)

        // HEAD should now point at the same SHA we returned.
        let headSHA = try runGit(["rev-parse", "HEAD"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(headSHA == sha)

        let branch = try repo.currentBranch()
        #expect(branch == "main")
    }

    @Test("second commit on top of first")
    func secondCommit() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("v1\n".utf8).write(to: dir.appendingPathComponent("file.txt"))
        let repo = try Repository.open(at: dir)
        try repo.add(paths: [])
        let firstSHA = try repo.commitDetailed(
            message: "first", author: Signature(name: "T", email: "t@e.com"),
            allowEmpty: false).sha

        try Data("v2\n".utf8).write(to: dir.appendingPathComponent("file.txt"))
        try repo.add(paths: [])
        let secondSHA = try repo.commitDetailed(
            message: "second", author: Signature(name: "T", email: "t@e.com"),
            allowEmpty: false).sha

        #expect(firstSHA != secondSHA)

        // Verify the parent linkage via the CLI.
        let parent = try runGit(["rev-parse", "\(secondSHA)^"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(parent == firstSHA)
    }

    @Test("empty commit refused without --allow-empty")
    func emptyCommitRefused() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("hi\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        let repo = try Repository.open(at: dir)
        try repo.add(paths: [])
        _ = try repo.commitDetailed(
            message: "init", author: Signature(name: "T", email: "t@e.com"),
            allowEmpty: false)

        #expect(throws: (any Error).self) {
            _ = try repo.commitDetailed(
                message: "empty", author: Signature(name: "T", email: "t@e.com"),
                allowEmpty: false)
        }
    }

    @Test("empty commit allowed with --allow-empty")
    func emptyCommitAllowed() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("hi\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        let repo = try Repository.open(at: dir)
        try repo.add(paths: [])
        let firstSHA = try repo.commitDetailed(
            message: "init", author: Signature(name: "T", email: "t@e.com"),
            allowEmpty: false).sha
        let emptySHA = try repo.commitDetailed(
            message: "empty", author: Signature(name: "T", email: "t@e.com"),
            allowEmpty: true).sha

        #expect(emptySHA != firstSHA)
        let parent = try runGit(["rev-parse", "\(emptySHA)^"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(parent == firstSHA)
    }

    @Test("commits with nil author use repo config")
    func defaultSignatureFromConfig() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x\n".utf8).write(to: dir.appendingPathComponent("x.txt"))

        let repo = try Repository.open(at: dir)
        try repo.add(paths: [])
        let sha = try repo.commitDetailed(
            message: "no-author", author: nil, allowEmpty: false).sha

        let authorEmail = try runGit(["log", "-1", "--format=%ae", sha], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(authorEmail == "test@example.com")
    }
}
#endif

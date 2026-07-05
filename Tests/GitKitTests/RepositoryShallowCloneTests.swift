// Integration tests for shallow / single-branch clone + fetch (issue #13).
// Fixtures are built with the system `git` CLI (gated to non-Windows for
// the same reasons as the other integration suites); everything under
// test goes through `Repository` so libgit2 is exercised end-to-end.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

@Suite("Repository.clone shallow & single-branch")
struct RepositoryShallowCloneTests {

    // MARK: Fixtures

    private func tmp(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)")
    }

    /// A source repo with three commits on `main` and one extra branch
    /// `feature`, left checked out on `main`. Returned as a `file://` URL
    /// so libgit2 uses the smart transport (shallow needs it).
    private func makeSource() throws -> (dir: URL, url: URL) {
        let dir = tmp("ShallowSource")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "test@example.com"], in: dir)
        try runGit(["config", "user.name", "Test"], in: dir)

        for i in 1...3 {
            try Data("line \(i)\n".utf8).write(to: dir.appendingPathComponent("file.txt"))
            try runGit(["add", "."], in: dir)
            try runGit(["commit", "-m", "commit \(i)"], in: dir)
        }
        // A second branch so single-branch has something to exclude.
        try runGit(["branch", "feature"], in: dir)

        let url = URL(fileURLWithPath: dir.path, isDirectory: true)
        return (dir, url)
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

    /// Silence the transfer-progress sink so tests don't spam stderr.
    private let quiet: @Sendable (String) -> Void = { _ in }

    // MARK: Tests

    @Test("depth clones only the requested number of commits")
    func shallowLimitsHistory() throws {
        let (srcDir, url) = try makeSource()
        let dest = tmp("ShallowClone")
        defer {
            try? FileManager.default.removeItem(at: srcDir)
            try? FileManager.default.removeItem(at: dest)
        }

        let repo = try Repository.clone(from: url, to: dest, depth: 1, progress: quiet)
        // Only the tip commit is present.
        #expect(try repo.log(LogQuery(starts: ["HEAD"])).count == 1)
        // libgit2 records the shallow boundary in `.git/shallow`.
        #expect(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent(".git/shallow").path))
    }

    @Test("no depth clones the full history")
    func fullCloneHasFullHistory() throws {
        let (srcDir, url) = try makeSource()
        let dest = tmp("FullClone")
        defer {
            try? FileManager.default.removeItem(at: srcDir)
            try? FileManager.default.removeItem(at: dest)
        }

        let repo = try Repository.clone(from: url, to: dest, progress: quiet)
        #expect(try repo.log(LogQuery(starts: ["HEAD"])).count == 3)
        #expect(!FileManager.default.fileExists(
            atPath: dest.appendingPathComponent(".git/shallow").path))
    }

    @Test("singleBranch with an explicit branch transfers only that branch")
    func singleBranchExplicit() throws {
        let (srcDir, url) = try makeSource()
        let dest = tmp("SingleBranchClone")
        defer {
            try? FileManager.default.removeItem(at: srcDir)
            try? FileManager.default.removeItem(at: dest)
        }

        let repo = try Repository.clone(
            from: url, to: dest, singleBranch: true, branch: "main", progress: quiet)
        #expect(try repo.currentBranch() == "main")

        let refs = try runGit(
            ["for-each-ref", "--format=%(refname)", "refs/remotes"], in: dest)
        #expect(refs.contains("refs/remotes/origin/main"))
        #expect(!refs.contains("refs/remotes/origin/feature"))
    }

    @Test("singleBranch without a branch uses the remote's default branch")
    func singleBranchDefault() throws {
        let (srcDir, url) = try makeSource()
        let dest = tmp("SingleBranchDefaultClone")
        defer {
            try? FileManager.default.removeItem(at: srcDir)
            try? FileManager.default.removeItem(at: dest)
        }

        let repo = try Repository.clone(
            from: url, to: dest, singleBranch: true, progress: quiet)
        #expect(try repo.currentBranch() == "main")

        let refs = try runGit(
            ["for-each-ref", "--format=%(refname)", "refs/remotes"], in: dest)
        #expect(refs.contains("refs/remotes/origin/main"))
        #expect(!refs.contains("refs/remotes/origin/feature"))
    }

    @Test("shallow + single-branch compose")
    func shallowSingleBranch() throws {
        let (srcDir, url) = try makeSource()
        let dest = tmp("ShallowSingleBranchClone")
        defer {
            try? FileManager.default.removeItem(at: srcDir)
            try? FileManager.default.removeItem(at: dest)
        }

        let repo = try Repository.clone(
            from: url, to: dest, depth: 1, singleBranch: true, branch: "main", progress: quiet)
        #expect(try repo.log(LogQuery(starts: ["HEAD"])).count == 1)
        let refs = try runGit(
            ["for-each-ref", "--format=%(refname)", "refs/remotes"], in: dest)
        #expect(!refs.contains("refs/remotes/origin/feature"))
    }

    @Test("fetch depth deepens a shallow clone")
    func shallowFetchDeepens() throws {
        let (srcDir, url) = try makeSource()
        let dest = tmp("DeepenClone")
        defer {
            try? FileManager.default.removeItem(at: srcDir)
            try? FileManager.default.removeItem(at: dest)
        }

        let repo = try Repository.clone(from: url, to: dest, depth: 1, progress: quiet)
        #expect(try repo.log(LogQuery(starts: ["HEAD"])).count == 1)

        try repo.fetch(
            remote: "origin", refspec: "+refs/heads/main:refs/remotes/origin/main",
            depth: 2, progress: quiet)
        #expect(try repo.log(LogQuery(starts: ["HEAD"])).count == 2)
    }

    @Test("unshallow restores the full history")
    func unshallowRestoresHistory() throws {
        let (srcDir, url) = try makeSource()
        let dest = tmp("UnshallowClone")
        defer {
            try? FileManager.default.removeItem(at: srcDir)
            try? FileManager.default.removeItem(at: dest)
        }

        let repo = try Repository.clone(from: url, to: dest, depth: 1, progress: quiet)
        #expect(try repo.log(LogQuery(starts: ["HEAD"])).count == 1)

        try repo.unshallow(
            remote: "origin", refspec: "+refs/heads/*:refs/remotes/origin/*", progress: quiet)
        #expect(try repo.log(LogQuery(starts: ["HEAD"])).count == 3)
        #expect(!FileManager.default.fileExists(
            atPath: dest.appendingPathComponent(".git/shallow").path))
    }
}
#endif

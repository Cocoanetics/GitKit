// Integration tests that fork the system `git` via `Process` for parity
// checks. Windows has no `/usr/bin/env`, and the swift-android-action's
// MSVC clang doesn't see a stable `git.exe` path either, so gate the
// whole suite to non-Windows. Apple/Linux still cover the integration
// surface.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

@Suite("Repository.checkout (-b / -- paths)")
struct RepositoryCheckoutTests {

    private func makeRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CheckoutTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "t@e.com"], in: dir)
        try runGit(["config", "user.name", "T"], in: dir)
        try Data("v1\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)
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

    @Test("-b creates a new branch and switches HEAD to it")
    func newBranch() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        let repo = try Repository.open(at: dir)
        let outcome = try repo.checkoutNewBranch(name: "feat")
        guard case .createdNew(let n) = outcome, n == "feat" else {
            Issue.record("expected createdNew, got \(outcome)"); return
        }

        let current = try repo.currentBranch()
        #expect(current == "feat")
        // Listed by `localBranches` too.
        let names = try repo.localBranches().sorted()
        #expect(names == ["feat", "main"])
    }

    @Test("-b on an existing branch errors")
    func newBranchDuplicateRejected() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try Repository.open(at: dir)
        _ = try repo.checkoutNewBranch(name: "feat")
        try repo.checkout(ref: "main")
        #expect(throws: Libgit2Error.self) {
            _ = try repo.checkoutNewBranch(name: "feat")
        }
    }

    @Test("-B force-resets an existing branch")
    func forceResetExisting() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try Repository.open(at: dir)
        _ = try repo.checkoutNewBranch(name: "feat")
        try repo.checkout(ref: "main")
        let outcome = try repo.checkoutNewBranch(name: "feat", force: true)
        guard case .resetExisting = outcome else {
            Issue.record("expected resetExisting, got \(outcome)"); return
        }
    }

    @Test("checkoutPaths restores working tree from index")
    func restoreFromIndex() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("modified\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Repository.open(at: dir).checkoutPaths(["a.txt"])
        let body = try Data(contentsOf: dir.appendingPathComponent("a.txt"))
        #expect(String(decoding: body, as: UTF8.self) == "v1\n")
    }

    @Test("checkoutPaths(from:) restores working tree from a ref's tree")
    func restoreFromRef() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Commit v2 so we have a ref to pull v2 back from later.
        try Data("v2\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "v2"], in: dir)

        // Restore a.txt to its v1 (HEAD~1) tree state.
        try Repository.open(at: dir)
            .checkoutPaths(["a.txt"], from: "HEAD~1")
        let body = try Data(contentsOf: dir.appendingPathComponent("a.txt"))
        #expect(String(decoding: body, as: UTF8.self) == "v1\n")
    }
}
#endif

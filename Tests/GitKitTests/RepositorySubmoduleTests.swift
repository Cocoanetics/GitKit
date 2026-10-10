// Integration tests that fork the system `git` only for fixture setup.
// Windows has no `/usr/bin/env`, and the swift-android-action's MSVC
// clang doesn't see a stable `git.exe` path either, so gate the suite to
// non-Windows.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

@Suite("Repository submodule sync")
struct RepositorySubmoduleTests {

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

    private func makeRepo(name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "t@e.com"], in: dir)
        try runGit(["config", "user.name", "T"], in: dir)
        try Data("v\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)
        return dir
    }

    /// Builds `outer/middle-sub/inner-sub` — a superproject with a
    /// submodule that itself has a submodule — and checks both levels
    /// out, matching the "nested test repositories" scenario the sync
    /// implementation has to resolve relative/local `file` URLs for.
    private func makeNestedFixture() throws -> (outer: URL, innermostSource: URL, cleanup: () -> Void) {
        let innermost = try makeRepo(name: "Innermost")
        let middle = try makeRepo(name: "Middle")
        let outer = try makeRepo(name: "Outer")

        try runGit([
            "-c", "protocol.file.allow=always",
            "submodule", "add", innermost.path, "inner-sub"
        ], in: middle)
        try runGit(["commit", "-m", "add inner-sub"], in: middle)

        try runGit([
            "-c", "protocol.file.allow=always",
            "submodule", "add", middle.path, "middle-sub"
        ], in: outer)
        try runGit(["commit", "-m", "add middle-sub"], in: outer)
        try runGit([
            "-c", "protocol.file.allow=always",
            "submodule", "update", "--init", "--recursive"
        ], in: outer)

        let cleanup = {
            try? FileManager.default.removeItem(at: innermost)
            try? FileManager.default.removeItem(at: middle)
            try? FileManager.default.removeItem(at: outer)
        }
        return (outer, innermost, cleanup)
    }

    @Test("non-recursive sync updates only the direct submodule's URL")
    func nonRecursiveSyncUpdatesDirectSubmoduleOnly() throws {
        let (outer, _, cleanup) = try makeNestedFixture()
        defer { cleanup() }

        // Simulate the URL having moved, the way real `git submodule sync`
        // reconciles a changed `.gitmodules` entry into local config.
        let newURL = outer.appendingPathComponent("middle-sub").path
        try runGit(["config", "--file", ".gitmodules",
                    "submodule.middle-sub.url", newURL], in: outer)

        let innerConfiguredBefore = try runGit(
            ["config", "--get", "remote.origin.url"],
            in: outer.appendingPathComponent("middle-sub/inner-sub")
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        let repo = try Repository.open(at: outer)
        try repo.submoduleSync()

        let syncedTopLevelURL = try runGit(
            ["config", "--get", "submodule.middle-sub.url"], in: outer
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(syncedTopLevelURL == newURL)

        let middleRemoteURL = try runGit(
            ["config", "--get", "remote.origin.url"],
            in: outer.appendingPathComponent("middle-sub")
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(middleRemoteURL == newURL)

        // Non-recursive: the nested inner-sub's own remote is untouched.
        let innerConfiguredAfter = try runGit(
            ["config", "--get", "remote.origin.url"],
            in: outer.appendingPathComponent("middle-sub/inner-sub")
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(innerConfiguredAfter == innerConfiguredBefore)
    }

    @Test("recursive sync propagates into nested checked-out submodules")
    func recursiveSyncPropagatesIntoNestedSubmodules() throws {
        let (outer, innermostSource, cleanup) = try makeNestedFixture()
        defer { cleanup() }

        // Move the leaf submodule's recorded URL — a relative/local `file`
        // URL resolved against the middle submodule's own on-disk location.
        let movedInnermost = innermostSource.deletingLastPathComponent()
            .appendingPathComponent("Innermost-moved-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: innermostSource, to: movedInnermost)
        defer { try? FileManager.default.removeItem(at: movedInnermost) }

        let middleDir = outer.appendingPathComponent("middle-sub")
        try runGit(["config", "--file", ".gitmodules",
                    "submodule.inner-sub.url", movedInnermost.path], in: middleDir)

        let repo = try Repository.open(at: outer)
        try repo.submoduleSync(recursive: true)

        let innerDir = middleDir.appendingPathComponent("inner-sub")
        let syncedMiddleConfigURL = try runGit(
            ["config", "--get", "submodule.inner-sub.url"], in: middleDir
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(syncedMiddleConfigURL == movedInnermost.path)

        let innerRemoteURL = try runGit(
            ["config", "--get", "remote.origin.url"], in: innerDir
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(innerRemoteURL == movedInnermost.path)
    }

    @Test("recursive sync skips submodules that aren't checked out")
    func recursiveSyncSkipsUncheckedOutSubmodules() throws {
        let (outer, _, cleanup) = try makeNestedFixture()
        defer { cleanup() }

        try runGit(["submodule", "deinit", "-f", "middle-sub"], in: outer)

        let repo = try Repository.open(at: outer)
        // Should not throw even though middle-sub (and its nested
        // inner-sub) are no longer present in the working tree.
        try repo.submoduleSync(recursive: true)
    }

    @Test("recursive sync propagates errors opening a corrupt checked-out submodule")
    func recursiveSyncPropagatesCorruptSubmoduleErrors() throws {
        let (outer, _, cleanup) = try makeNestedFixture()
        defer { cleanup() }

        // `middle-sub/.git` is a gitlink file ("gitdir: ../.git/modules/…").
        // Corrupting its content (not the "not checked out" case — the path
        // still exists) makes libgit2 fail to open it with a generic error
        // rather than GIT_ENOTFOUND, simulating a corrupt `.git` link.
        let gitlinkPath = outer.appendingPathComponent("middle-sub/.git")
        try Data("not a gitdir pointer\n".utf8).write(to: gitlinkPath)

        let repo = try Repository.open(at: outer)
        #expect(throws: Libgit2Error.self) {
            try repo.submoduleSync(recursive: true)
        }
    }
}
#endif

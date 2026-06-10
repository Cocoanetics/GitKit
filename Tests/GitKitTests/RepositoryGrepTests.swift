// Integration tests that fork the system `git` via `Process` to seed a
// repo, then call into our libgit2-backed `grep`. Same Windows-gating
// rationale as the other Repository tests — `Process` + `/usr/bin/env`
// don't behave portably on the swift-android-action MSVC runners.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

@Suite("Repository.grep")
struct RepositoryGrepTests {

    private func makeRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Libgit2Grep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "t@e.com"], in: dir)
        try runGit(["config", "user.name", "T"], in: dir)
        return dir
    }

    @discardableResult
    private func runGit(_ args: [String], in dir: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = dir
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let stdout = String(
            decoding: (try? out.fileHandleForReading.readToEnd()) ?? Data(),
            as: UTF8.self)
        if process.terminationStatus != 0 {
            let stderr = String(
                decoding: (try? err.fileHandleForReading.readToEnd()) ?? Data(),
                as: UTF8.self)
            throw Failure("git \(args.joined(separator: " ")) failed: \(stderr)")
        }
        return stdout
    }

    private func write(_ contents: String, to path: String, in dir: URL) throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    private struct Failure: Error, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { message }
    }

    @Test("grep matches a tracked line with path + 1-indexed line number")
    func tracked() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("hello world\nfoo bar\nbaz\n", to: "a.txt", in: dir)
        try write("only other\n", to: "b.txt", in: dir)
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)

        let repo = try Repository.open(at: dir)
        let matches = try repo.grep(pattern: "foo")
        #expect(matches.count == 1)
        #expect(matches.first?.path == "a.txt")
        #expect(matches.first?.lineNumber == 2)
        #expect(matches.first?.line == "foo bar")
    }

    @Test("grep skips gitignored files because they aren't in the index")
    func skipsIgnored() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("*.log\n", to: ".gitignore", in: dir)
        try write("ERROR boom\n", to: "tracked.txt", in: dir)
        try write("ERROR sneaky\n", to: "secret.log", in: dir)
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)

        let repo = try Repository.open(at: dir)
        let matches = try repo.grep(pattern: "ERROR")
        #expect(matches.map(\.path) == ["tracked.txt"])
    }

    @Test("grep --untracked includes untracked-not-ignored files")
    func untracked() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("*.log\n", to: ".gitignore", in: dir)
        try write("ERROR tracked\n", to: "a.txt", in: dir)
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)

        // Untracked + not gitignored → should be searched with --untracked.
        try write("ERROR untracked\n", to: "b.txt", in: dir)
        // Untracked + gitignored → must stay invisible.
        try write("ERROR ignored\n", to: "c.log", in: dir)

        let repo = try Repository.open(at: dir)

        let defaults = try repo.grep(pattern: "ERROR")
        #expect(defaults.map(\.path) == ["a.txt"])

        let withUntracked = try repo.grep(pattern: "ERROR", includeUntracked: true)
        #expect(Set(withUntracked.map(\.path)) == ["a.txt", "b.txt"])
    }

    @Test("grep honours .caseInsensitive option")
    func caseInsensitive() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("HELLO\nhello\nHeLLo\n", to: "a.txt", in: dir)
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)

        let repo = try Repository.open(at: dir)
        let sensitive = try repo.grep(pattern: "hello")
        #expect(sensitive.count == 1)
        #expect(sensitive.first?.lineNumber == 2)

        let insensitive = try repo.grep(
            pattern: "hello", options: [.caseInsensitive])
        #expect(insensitive.map(\.lineNumber) == [1, 2, 3])
    }

    @Test("grep pathFilters narrow by basename glob")
    func pathFilters() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("needle\n", to: "src/a.swift", in: dir)
        try write("needle\n", to: "docs/b.md", in: dir)
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)

        let repo = try Repository.open(at: dir)
        let swiftOnly = try repo.grep(
            pattern: "needle", pathFilters: ["*.swift"])
        #expect(swiftOnly.map(\.path) == ["src/a.swift"])
    }

    @Test("grep skips binary files silently")
    func skipsBinary() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("text needle\n", to: "a.txt", in: dir)
        // Embed a NUL byte so UTF-8 decode succeeds line-by-line but
        // the file's bytes won't actually round-trip through String —
        // matches what FileManager+String returns nil for.
        let binary = Data([0x00, 0x01, 0x02, 0xFF, 0xFE, 0xFD, 0xC3, 0x28])
        try binary.write(to: dir.appendingPathComponent("b.bin"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)

        let repo = try Repository.open(at: dir)
        let matches = try repo.grep(pattern: "needle")
        #expect(matches.map(\.path) == ["a.txt"])
    }
}
#endif

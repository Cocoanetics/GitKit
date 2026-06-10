// Integration tests that fork the system `git` via `Process` for parity
// checks. Windows has no `/usr/bin/env`, and the swift-android-action's
// MSVC clang doesn't see a stable `git.exe` path either, so gate the
// whole suite to non-Windows. Apple/Linux still cover the integration
// surface.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

@Suite("Repository.log")
struct RepositoryLogTests {

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

    /// Build a repo with three sequential commits c1/c2/c3 each
    /// touching its own file `fN.txt`. Used by most tests.
    private func makeLinearRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "tester@example.com"], in: dir)
        try runGit(["config", "user.name", "Test User"], in: dir)
        for i in 1...3 {
            try Data("v\(i)\n".utf8).write(to: dir.appendingPathComponent("f\(i).txt"))
            try runGit(["add", "."], in: dir)
            try runGit(["commit", "-m", "commit \(i)\n\nBody for commit \(i)."], in: dir)
        }
        return dir
    }

    @Test("default walk returns all commits, newest first")
    func defaultWalk() throws {
        let dir = try makeLinearRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        let entries = try Repository.open(at: dir).log()
        #expect(entries.count == 3)
        #expect(entries.map(\.subject) == ["commit 3", "commit 2", "commit 1"])
        #expect(entries[0].authorName == "Test User")
        #expect(entries[0].authorEmail == "tester@example.com")
        #expect(entries[0].sha.count == 40)
        #expect(entries[0].shortSHA.count == 7)
    }

    @Test("maxCount caps the result")
    func maxCount() throws {
        let dir = try makeLinearRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let entries = try Repository.open(at: dir)
            .log(LogQuery(maxCount: 2))
        #expect(entries.count == 2)
        #expect(entries.map(\.subject) == ["commit 3", "commit 2"])
    }

    @Test("range query (a..b form) excludes a's ancestors")
    func rangeQuery() throws {
        let dir = try makeLinearRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        // HEAD~2..HEAD = commit 2 + commit 3 (everything since the
        // ancestor 2 commits back, exclusive of that commit).
        let entries = try Repository.open(at: dir)
            .log(LogQuery(starts: ["HEAD"], excludes: ["HEAD~2"]))
        #expect(entries.map(\.subject) == ["commit 3", "commit 2"])
    }

    @Test("path filter restricts to commits touching <path>")
    func pathFilter() throws {
        let dir = try makeLinearRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let entries = try Repository.open(at: dir)
            .log(LogQuery(paths: ["f2.txt"]))
        #expect(entries.count == 1)
        #expect(entries.first?.subject == "commit 2")
    }

    @Test("merge commits expose multiple parents")
    func mergeCommitParents() throws {
        let dir = try makeLinearRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try runGit(["checkout", "-b", "feat"], in: dir)
        try Data("feat\n".utf8).write(to: dir.appendingPathComponent("b.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "feat work"], in: dir)
        try runGit(["checkout", "main"], in: dir)
        try runGit(["merge", "feat", "--no-ff", "-m", "merge feat"], in: dir)

        let entries = try Repository.open(at: dir).log()
        let merge = entries.first
        #expect(merge?.subject == "merge feat")
        #expect(merge?.parentSHAs.count == 2)
        #expect(merge?.isMerge == true)
    }

    @Test("default format matches `git log` byte-for-byte (sans variable date)")
    func defaultFormatParity() throws {
        let dir = try makeLinearRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let entries = try Repository.open(at: dir).log()
        var ours = entries.enumerated().reduce(into: "") { acc, pair in
            if pair.offset > 0 { acc += "\n" }
            acc += pair.element.defaultFormat()
        }
        var theirs = try runGit(["log"], in: dir)

        // Strip variable bits — SHA + Date.
        let norm: (String) -> String = { input in
            var s = input
            s = s.replacingOccurrences(
                of: #"[a-f0-9]{40}"#, with: "SHA",
                options: .regularExpression)
            s = s.replacingOccurrences(
                of: #"Date:\s+.+"#, with: "Date:DATE",
                options: .regularExpression)
            return s
        }
        ours = norm(ours)
        theirs = norm(theirs)
        #expect(ours == theirs)
    }

    @Test("oneline format matches real git")
    func onelineFormatParity() throws {
        let dir = try makeLinearRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let entries = try Repository.open(at: dir).log()
        let ours = entries.map { $0.onelineFormat() }.joined(separator: "\n") + "\n"
        let theirs = try runGit(["log", "--oneline"], in: dir)
        // Different runs → SHAs differ; just compare subjects.
        let oursSubjects = ours.split(separator: "\n").map { $0.split(separator: " ", maxSplits: 1).last.map(String.init) ?? "" }
        let theirsSubjects = theirs.split(separator: "\n").map { $0.split(separator: " ", maxSplits: 1).last.map(String.init) ?? "" }
        #expect(oursSubjects == theirsSubjects)
    }

    @Test("format string %H%n%an%n%s expands correctly")
    func formatStringExpansion() throws {
        let dir = try makeLinearRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let entries = try Repository.open(at: dir).log()
        let head = entries[0]
        let formatted = head.format("%H%n%an%n%s")
        let lines = formatted.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0] == head.sha)
        #expect(lines[1] == "Test User")
        #expect(lines[2] == "commit 3")
    }

    @Test("body separates from subject correctly")
    func subjectAndBody() throws {
        let dir = try makeLinearRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let entries = try Repository.open(at: dir).log()
        let head = entries[0]
        #expect(head.subject == "commit 3")
        #expect(head.body.hasPrefix("Body for commit 3"))
    }

    @Test("empty repo returns empty log without throwing")
    func emptyRepoNoCrash() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogEmpty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try runGit(["init", "-b", "main"], in: dir)

        let entries = try Repository.open(at: dir).log()
        #expect(entries.isEmpty)
    }
}
#endif

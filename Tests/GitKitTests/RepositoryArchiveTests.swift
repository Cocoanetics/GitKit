// Integration tests for the trait-gated `Repository.archive`. They build a
// small repo via the system `git` CLI for fixturing, produce archives
// through the libgit2 + libarchive pipeline, and verify with the system
// `tar` (listing / extraction) plus magic-byte checks.
//
// Compiled only when the `Archive` trait is enabled (the trait doubles as a
// compilation condition) and on platforms with `/usr/bin/env` + a stable
// `git`/`tar` (macOS / Linux) — the same surface the other integration
// suites cover.
#if Archive && (os(macOS) || os(Linux))
import Foundation
import Testing
@testable import GitKit

@Suite("Repository.archive")
struct RepositoryArchiveTests {

    private func makeRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitArchiveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        try run(["git", "init", "-b", "main"], in: dir)
        try run(["git", "config", "user.email", "test@example.com"], in: dir)
        try run(["git", "config", "user.name", "Test"], in: dir)
        // Build a small tree so we can verify ordering + content.
        try Data("# README\n".utf8).write(
            to: dir.appendingPathComponent("README.md"))
        let nested = dir.appendingPathComponent("src")
        try FileManager.default.createDirectory(
            at: nested, withIntermediateDirectories: true)
        try Data("body\n".utf8).write(
            to: nested.appendingPathComponent("main.swift"))
        try run(["git", "add", "."], in: dir)
        try run(["git", "commit", "-m", "init"], in: dir)
        return dir
    }

    @discardableResult
    private func run(
        _ argv: [String], in dir: URL, env: [String: String] = [:]
    ) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = argv
        p.currentDirectoryURL = dir
        if !env.isEmpty {
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in env { merged[k] = v }
            p.environment = merged
        }
        let out = Pipe(); let err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let e = String(decoding:
                (try? err.fileHandleForReading.readToEnd()) ?? Data(),
                as: UTF8.self)
            throw Failure("\(argv.joined(separator: " ")) failed: \(e)")
        }
        return String(decoding:
            (try? out.fileHandleForReading.readToEnd()) ?? Data(),
            as: UTF8.self)
    }

    private struct Failure: Error, CustomStringConvertible {
        let message: String
        init(_ m: String) { self.message = m }
        var description: String { message }
    }

    @Test("plain tar round-trips through system tar")
    func plainTar() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try Repository.open(at: dir)
        let archive = dir.appendingPathComponent("snap.tar")
        try repo.archive(treeish: "HEAD", format: .tar, to: archive)

        let extractDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(
            at: extractDir, withIntermediateDirectories: true)
        try run(["tar", "-xf", archive.path, "-C", extractDir.path], in: dir)

        #expect(FileManager.default.fileExists(
            atPath: extractDir.appendingPathComponent("README.md").path))
        let nested = try String(
            contentsOf: extractDir.appendingPathComponent("src/main.swift"),
            encoding: .utf8)
        #expect(nested == "body\n")
    }

    @Test("tar.gz format produces a valid gzip stream")
    func tarGzip() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try Repository.open(at: dir)
        let archive = dir.appendingPathComponent("snap.tar.gz")
        try repo.archive(treeish: "HEAD", format: .tarGzip, to: archive)
        let head = try FileHandle(forReadingFrom: archive).readData(ofLength: 2)
        #expect(head == Data([0x1f, 0x8b]))
    }

    @Test("tar.zst format produces a valid zstd frame")
    func tarZstd() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try Repository.open(at: dir)
        let archive = dir.appendingPathComponent("snap.tar.zst")
        try repo.archive(treeish: "HEAD", format: .tarZstd, to: archive)
        let head = try FileHandle(forReadingFrom: archive).readData(ofLength: 4)
        #expect(head == Data([0x28, 0xB5, 0x2F, 0xFD]))
    }

    @Test("zip format carries the PKZIP magic")
    func zipFormat() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try Repository.open(at: dir)
        let archive = dir.appendingPathComponent("snap.zip")
        try repo.archive(treeish: "HEAD", format: .zip, to: archive)
        // PKZIP local-file-header magic: PK\x03\x04
        let head = try FileHandle(forReadingFrom: archive).readData(ofLength: 4)
        #expect(head == Data([0x50, 0x4B, 0x03, 0x04]))
    }

    @Test("entry mtimes track the commit timestamp, not wall clock")
    func reproducibleMtime() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Force the commit's author/commit date to a known value via
        // GIT_*_DATE env vars on the most recent commit.
        let when = "2020-01-15T12:34:56+00:00"
        try run(["git", "commit", "--amend", "--no-edit",
                 "--date", when], in: dir, env: [
                     "GIT_COMMITTER_DATE": when,
                     "GIT_AUTHOR_DATE": when,
                 ])

        let repo = try Repository.open(at: dir)
        let archive = dir.appendingPathComponent("snap.tar")
        try repo.archive(treeish: "HEAD", format: .tar, to: archive)

        // System tar restores mtimes on extraction — compare the extracted
        // files' modification dates against the forced commit date.
        let extractDir = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(
            at: extractDir, withIntermediateDirectories: true)
        try run(["tar", "-xf", archive.path, "-C", extractDir.path], in: dir)

        let expected = ISO8601DateFormatter().date(from: when)!
        for rel in ["README.md", "src/main.swift"] {
            let attrs = try FileManager.default.attributesOfItem(
                atPath: extractDir.appendingPathComponent(rel).path)
            guard let m = attrs[.modificationDate] as? Date else {
                Issue.record("entry \(rel) has no modificationDate")
                continue
            }
            // ±2s tolerance for tar's per-second granularity.
            let delta = abs(m.timeIntervalSince(expected))
            #expect(delta < 2,
                "entry \(rel) mtime \(m) differs from commit \(expected) by \(delta)s")
        }
    }

    @Test("--prefix prepends every entry path")
    func prefix() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try Repository.open(at: dir)
        let archive = dir.appendingPathComponent("snap.tar")
        try repo.archive(
            treeish: "HEAD", format: .tar, to: archive, prefix: "myproj-1.0")
        let listing = try run(["tar", "-tf", archive.path], in: dir)
        let entries = listing.split(separator: "\n").map(String.init)
        #expect(!entries.isEmpty)
        #expect(entries.allSatisfy { $0.hasPrefix("myproj-1.0/") })
        #expect(entries.contains("myproj-1.0/README.md"))
    }
}
#endif

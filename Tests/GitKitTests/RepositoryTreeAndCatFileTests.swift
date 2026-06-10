// Integration tests that fork the system `git` via `Process` for parity
// checks. Windows has no `/usr/bin/env`, and the swift-android-action's
// MSVC clang doesn't see a stable `git.exe` path either, so gate the
// whole suite to non-Windows. Apple/Linux still cover the integration
// surface.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

@Suite("Repository.lsTree + cat-file")
struct RepositoryTreeAndCatFileTests {

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
            .appendingPathComponent("Tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "t@e.com"], in: dir)
        try runGit(["config", "user.name", "T"], in: dir)
        return dir
    }

    @Test("ls-tree: top-level entries only by default")
    func lsTreeTopLevel() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("a\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("b\n".utf8).write(to: dir.appendingPathComponent("sub/b.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)

        let entries = try Repository.open(at: dir).lsTree()
        // Expect exactly two top-level entries: a.txt (blob) + sub (tree).
        #expect(entries.count == 2)
        let blob = entries.first { $0.path == "a.txt" }
        let tree = entries.first { $0.path == "sub" }
        #expect(blob?.kind == .blob)
        #expect(blob?.mode == "100644")
        #expect(tree?.kind == .tree)
        #expect(tree?.mode == "040000")
    }

    @Test("ls-tree -r flattens subtree blobs into the result")
    func lsTreeRecursive() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("a\n".utf8).write(to: dir.appendingPathComponent("sub/a.txt"))
        try Data("b\n".utf8).write(to: dir.appendingPathComponent("sub/b.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)

        let entries = try Repository.open(at: dir)
            .lsTree(recursive: true)
        let blobPaths = entries.filter { $0.kind == .blob }.map(\.path).sorted()
        #expect(blobPaths == ["sub/a.txt", "sub/b.txt"])
    }

    @Test("cat-file: blob round-trips its bytes")
    func catFileBlob() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = "hello world\n"
        try Data(payload.utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)
        // Resolve the blob's SHA via real git so we exercise revparse.
        let sha = try runGit(["rev-parse", "HEAD:a.txt"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let repo = try Repository.open(at: dir)
        let data = try repo.catFileBlob(sha)
        #expect(String(decoding: data, as: UTF8.self) == payload)
    }

    @Test("objectMetadata reports kind + size for HEAD commit")
    func objectMetadataCommit() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("a\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)

        let meta = try Repository.open(at: dir)
            .objectMetadata(of: "HEAD")
        #expect(meta.kind == .commit)
        #expect(meta.size > 0)
        #expect(meta.sha.count == 40)
    }
}
#endif

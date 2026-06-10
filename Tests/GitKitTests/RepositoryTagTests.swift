// Integration tests that fork the system `git` via `Process` for parity
// checks. Windows has no `/usr/bin/env`, and the swift-android-action's
// MSVC clang doesn't see a stable `git.exe` path either, so gate the
// whole suite to non-Windows. Apple/Linux still cover the integration
// surface.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

@Suite("Repository.tag")
struct RepositoryTagTests {

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
            .appendingPathComponent("TagTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "t@e.com"], in: dir)
        try runGit(["config", "user.name", "T"], in: dir)
        try Data("x\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)
        return dir
    }

    @Test("create lightweight + list")
    func lightweightAndList() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try Repository.open(at: dir)
        _ = try repo.tagCreate(name: "v1.0")
        _ = try repo.tagCreate(name: "v0.5")
        let names = try repo.tagList()
        #expect(names == ["v0.5", "v1.0"])
    }

    @Test("create annotated has tagger + message")
    func annotated() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try Repository.open(at: dir)
        _ = try repo.tagCreateAnnotated(
            name: "v2.0", message: "release 2.0",
            tagger: Signature(name: "T", email: "t@e.com"))
        let details = try repo.tagDetails()
        #expect(details.count == 1)
        #expect(details[0].name == "v2.0")
        #expect(details[0].isAnnotated)
        #expect(details[0].summary == "release 2.0")
    }

    @Test("pattern filter")
    func patternFilter() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try Repository.open(at: dir)
        for name in ["v0.5", "v1.0", "v1.1", "v2.0"] {
            _ = try repo.tagCreate(name: name)
        }
        let v1s = try repo.tagList(pattern: "v1*")
        #expect(v1s == ["v1.0", "v1.1"])
    }

    @Test("dup without force throws; force replaces")
    func dupAndForce() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try Repository.open(at: dir)
        _ = try repo.tagCreate(name: "v1.0")
        #expect(throws: Libgit2Error.self) {
            _ = try repo.tagCreate(name: "v1.0", force: false)
        }
        // Force succeeds.
        _ = try repo.tagCreate(name: "v1.0", force: true)
    }

    @Test("delete removes tag, returns prior SHA")
    func delete() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try Repository.open(at: dir)
        _ = try repo.tagCreate(name: "v1.0")
        let oldSHA = try repo.tagDelete(name: "v1.0")
        #expect(oldSHA.count == 40)
        let names = try repo.tagList()
        #expect(names.isEmpty)
    }

    @Test("tagExists tracks creation/deletion")
    func existsTracks() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try Repository.open(at: dir)
        #expect(try repo.tagExists("v1.0") == false)
        _ = try repo.tagCreate(name: "v1.0")
        #expect(try repo.tagExists("v1.0") == true)
        _ = try repo.tagDelete(name: "v1.0")
        #expect(try repo.tagExists("v1.0") == false)
    }
}
#endif

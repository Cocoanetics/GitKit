// Integration tests compare the SDK with system git; Process is unavailable on Windows.
#if os(macOS) || os(Linux)
import Foundation
import Testing
import GitKit

@Suite("Repository remote branches and references")
struct RepositoryReferenceTests {

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
        let output = String(decoding: (try? out.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
        if p.terminationStatus != 0 {
            let error = String(decoding: (try? err.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
            throw Failure(message: "git \(args.joined(separator: " ")) failed: \(error)")
        }
        return output
    }

    private struct Failure: Error {
        let message: String
    }

    private func makeRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReferenceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.name", "T"], in: dir)
        try runGit(["config", "user.email", "t@e.com"], in: dir)
        return dir
    }

    private func gitRows(in dir: URL, pattern: String = "refs/") throws -> [String] {
        try runGit([
            "for-each-ref", "--sort=refname", "--format=%(refname) %(objectname)", pattern
        ], in: dir).split(separator: "\n").map(String.init)
    }

    /// Store refs whose names are canonically equivalent directly in packed-refs.
    /// Some macOS file systems normalize loose-ref filenames, so they cannot hold
    /// both spellings at once even though Git's packed-ref format can.
    private func appendPackedRefs(_ names: [String], oid: String, in dir: URL) throws {
        let file = dir.appendingPathComponent(".git/packed-refs")
        var data = (try? Data(contentsOf: file))
            ?? Data("# pack-refs with: peeled fully-peeled\n".utf8)
        for name in names {
            data.append(Data("\(oid) \(name)\n".utf8))
        }
        try data.write(to: file)
    }

    @Test("fetched remote branches match git, including symbolic HEAD and packed refs")
    func remoteBranchesParity() throws {
        let source = try makeRepo()
        defer { try? FileManager.default.removeItem(at: source) }
        try runGit(["commit", "--allow-empty", "-m", "first"], in: source)
        try runGit(["branch", "feature/nested"], in: source)
        try runGit(["commit", "--allow-empty", "-m", "second"], in: source)
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        for remote in ["origin", "origin-extra", "upstream"] {
            try runGit(["remote", "add", remote, source.path], in: dir)
            try runGit(["fetch", remote], in: dir)
            try runGit(["remote", "set-head", remote, "main"], in: dir)
        }
        let remoteOID = try runGit(
            ["rev-parse", "refs/remotes/origin/main"], in: dir
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        try appendPackedRefs(
            ["origin", "origin-extra", "upstream"].flatMap { remote in
                ["refs/remotes/\(remote)/e\u{301}",
                 "refs/remotes/\(remote)/z",
                 "refs/remotes/\(remote)/é"]
            },
            oid: remoteOID, in: dir)
        try runGit(["update-ref", "refs/heads/local-only", "refs/remotes/origin/main"], in: dir)
        let repo = try Repository.open(at: dir)

        for packed in [false, true] {
            if packed { try runGit(["pack-refs", "--all", "--prune"], in: dir) }
            let branches = try repo.remoteBranches()
            let rows = branches.map { "refs/remotes/\($0.name) \($0.targetSHA)" }
            #expect(rows == (try gitRows(in: dir, pattern: "refs/remotes")))
            let gitNames = try runGit([
                "branch", "-r", "--sort=refname", "--format=%(refname:strip=2)"
            ], in: dir).split(separator: "\n").map(String.init)
            #expect(branches.map(\.name) == gitNames)
            #expect(branches.count == 18)
            #expect(branches.contains { $0.name == "origin/HEAD" })
            let origin = try repo.remoteBranches(remote: "origin")
            #expect(origin.map(\.name) == [
                "origin/HEAD", "origin/e\u{301}", "origin/feature/nested",
                "origin/main", "origin/z", "origin/é"
            ])
            #expect(try repo.remoteBranches(remote: "missing").isEmpty)
            let refs = try repo.references(matching: "refs/remotes/*")
            #expect(refs.map { "\($0.name) \($0.targetSHA)" } == rows)
            let head = try #require(refs.first { $0.name == "refs/remotes/origin/HEAD" })
            #expect(head.symbolicTarget == "refs/remotes/origin/main")
            #expect(head.targetSHA == origin.first { $0.name == "origin/main" }?.targetSHA)
        }
    }

    @Test("reference globs list tags and other namespaces, loose and packed")
    func referencesParity() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try runGit(["commit", "--allow-empty", "-m", "first"], in: dir)
        try runGit(["tag", "v1"], in: dir)
        try runGit(["tag", "-a", "v2", "-m", "release"], in: dir)
        try runGit(["tag", "releases/v3"], in: dir)
        try runGit(["update-ref", "refs/custom/published", "HEAD"], in: dir)
        let headOID = try runGit(["rev-parse", "HEAD"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try appendPackedRefs(
            ["refs/custom/e\u{301}", "refs/custom/z", "refs/custom/é"],
            oid: headOID, in: dir)
        let repo = try Repository.open(at: dir)

        for packed in [false, true] {
            if packed { try runGit(["pack-refs", "--all", "--prune"], in: dir) }
            let all = try repo.references()
            #expect(all.map { "\($0.name) \($0.targetSHA)" } == (try gitRows(in: dir)))
            #expect(all.count == 8)
            let tags = try repo.references(matching: "refs/tags/*")
            #expect(tags.map { "\($0.name) \($0.targetSHA)" } == (try gitRows(in: dir, pattern: "refs/tags")))
            #expect(tags.map(\.name) == ["refs/tags/releases/v3", "refs/tags/v1", "refs/tags/v2"])
            #expect(tags.allSatisfy { $0.symbolicTarget == nil })
            let versionTags = try repo.references(matching: "refs/tags/v[12]")
            #expect(versionTags.map(\.name) == ["refs/tags/v1", "refs/tags/v2"])
            let annotated = try #require(tags.first { $0.name == "refs/tags/v2" })
            let tagSHA = try runGit(["rev-parse", "v2"], in: dir).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(annotated.targetSHA == tagSHA)
            #expect(annotated.targetSHA != (try repo.resolveOID("HEAD")))
            #expect(try repo.references(matching: "refs/custom/*").map(\.name) == [
                "refs/custom/e\u{301}", "refs/custom/published",
                "refs/custom/z", "refs/custom/é"
            ])
            #expect(try repo.references(matching: "refs/missing/*").isEmpty)
        }
    }

    @Test("empty repositories and dangling symbolic refs match git")
    func emptyAndDanglingReferences() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try Repository.open(at: dir)
        #expect(try repo.remoteBranches().isEmpty)
        #expect(try repo.references().isEmpty)
        try runGit(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/missing"], in: dir)
        #expect(try repo.remoteBranches().isEmpty)
        #expect(try repo.references().isEmpty)
        #expect(try gitRows(in: dir).isEmpty)
    }
}
#endif

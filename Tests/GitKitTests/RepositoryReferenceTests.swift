// Integration tests compare the SDK with system git; Process is unavailable on Windows.
#if os(macOS) || os(Linux)
import Foundation
import Dispatch
import Testing
import CGitKit
import GitKit

private final class ReferenceDeleteWorker: @unchecked Sendable {
    let repository: Repository
    let name: String

    init(repository: Repository, name: String) {
        self.repository = repository
        self.name = name
    }
}

private final class ReferenceDeleteResults: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [(name: String, code: Int32)] = []

    func record(name: String, code: Int32) {
        lock.lock()
        failures.append((name, code))
        lock.unlock()
    }

    func snapshot() -> [(name: String, code: Int32)] {
        lock.lock()
        defer { lock.unlock() }
        return failures
    }
}

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

    @Test("delete a single review ref, loose or packed", arguments: [false, true], [false, true])
    func deleteReference(packed: Bool, guarded: Bool) throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try runGit(["commit", "--allow-empty", "-m", "first"], in: dir)
        let name = "refs/missioncontrol/reviews/pr-80"
        try runGit(["update-ref", name, "HEAD"], in: dir)
        try runGit(["update-ref", name + "-keep", "HEAD"], in: dir)
        try runGit(["tag", "keep"], in: dir)
        if packed { try runGit(["pack-refs", "--all", "--prune"], in: dir) }
        let before = try gitRows(in: dir)
        let repo = try Repository.open(at: dir)
        let sha = try repo.resolveOID("HEAD")

        try repo.referenceDelete(name: name, expectedTargetSHA: guarded ? sha.uppercased() : nil)

        let expected = before.filter { !$0.hasPrefix(name + " ") }
        #expect(try gitRows(in: dir) == expected)
        #expect(try repo.references().map { "\($0.name) \($0.targetSHA)" } == expected)
    }

    @Test("stale expected targets preserve moved refs", arguments: [false, true])
    func deleteReferenceExpectedTarget(packed: Bool) throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try runGit(["commit", "--allow-empty", "-m", "first"], in: dir)
        let repo = try Repository.open(at: dir)
        let oldSHA = try repo.resolveOID("HEAD")
        let name = "refs/missioncontrol/reviews/pr-80"
        try runGit(["update-ref", name, "HEAD"], in: dir)
        try runGit(["commit", "--allow-empty", "-m", "second"], in: dir)
        let newSHA = try repo.resolveOID("HEAD")
        try runGit(["update-ref", name, newSHA], in: dir)
        if packed { try runGit(["pack-refs", "--all", "--prune"], in: dir) }
        let before = try gitRows(in: dir)

        let error = #expect(throws: Libgit2Error.self) {
            try repo.referenceDelete(name: name, expectedTargetSHA: oldSHA)
        }
        #expect(error?.code == GIT_EMODIFIED.rawValue)
        #expect(try gitRows(in: dir) == before)
        #expect(try repo.resolveOID(name) == newSHA)
        try repo.referenceDelete(name: name, expectedTargetSHA: newSHA)
        #expect(try repo.references(matching: name).isEmpty)
    }

    @Test("a concurrent ref update preserves the moved ref and its reflog")
    func deleteReferenceConcurrentUpdatePreservesReflog() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try runGit(["commit", "--allow-empty", "-m", "first"], in: dir)
        let name = "refs/heads/review-80"
        try runGit(["update-ref", "-m", "create review ref", name, "HEAD"], in: dir)
        let repo = try Repository.open(at: dir)
        var rawRepo: OpaquePointer?
        guard git_repository_open(&rawRepo, dir.path) == 0 else {
            throw Failure(message: "git_repository_open failed")
        }
        defer { git_repository_free(rawRepo) }
        var stale: OpaquePointer?
        guard git_reference_lookup(&stale, rawRepo, name) == 0 else {
            throw Failure(message: "git_reference_lookup failed")
        }
        defer { git_reference_free(stale) }

        try runGit(["commit", "--allow-empty", "-m", "second"], in: dir)
        let movedSHA = try repo.resolveOID("HEAD")
        try runGit(["update-ref", "-m", "move review ref", name, movedSHA], in: dir)
        let logURL = dir.appendingPathComponent(".git/logs/" + name)
        let reflog = try Data(contentsOf: logURL)

        #expect(git_reference_delete(stale) == GIT_EMODIFIED.rawValue)
        #expect(try repo.resolveOID(name) == movedSHA)
        #expect(try Data(contentsOf: logURL) == reflog)

        try repo.referenceDelete(name: name, expectedTargetSHA: movedSHA)
        #expect(!FileManager.default.fileExists(atPath: logURL.path))
    }

    @Test("per-worktree refs are deleted from the linked worktree only")
    func deletePerWorktreeReference() throws {
        let dir = try makeRepo()
        let linked = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReferenceLinked-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: linked)
            try? FileManager.default.removeItem(at: dir)
        }
        try runGit(["commit", "--allow-empty", "-m", "first"], in: dir)
        try runGit(["commit", "--allow-empty", "-m", "second"], in: dir)
        try runGit(["worktree", "add", "-q", "-b", "linked", linked.path, "HEAD~1"], in: dir)
        let mainSHA = try runGit(["rev-parse", "HEAD"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let linkedSHA = try runGit(["rev-parse", "HEAD"], in: linked)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let names = [
            "refs/bisect/review-80", "refs/worktree/review-80",
            "refs/rewritten/review-80"
        ]
        for name in names {
            try runGit(["update-ref", name, mainSHA], in: dir)
            try runGit(["update-ref", name, linkedSHA], in: linked)
        }
        let mainRepo = try Repository.open(at: dir)
        let linkedRepo = try Repository.open(at: linked)

        for name in names {
            try linkedRepo.referenceDelete(name: name, expectedTargetSHA: linkedSHA)
            let error = #expect(throws: Libgit2Error.self) {
                try linkedRepo.resolveOID(name)
            }
            #expect(error?.code == GIT_ENOTFOUND.rawValue)
            #expect(try mainRepo.resolveOID(name) == mainSHA)
        }
    }

    @Test("concurrent packed-ref deletions never resurrect another ref")
    func deletePackedReferencesConcurrently() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try runGit(["commit", "--allow-empty", "-m", "first"], in: dir)

        for round in 0..<20 {
            let prefix = "refs/missioncontrol/reviews/concurrent-\(round)-"
            let names = [prefix + "a", prefix + "b"]
            for name in names { try runGit(["update-ref", name, "HEAD"], in: dir) }
            try runGit(["pack-refs", "--all", "--prune"], in: dir)

            let workers = try names.map {
                ReferenceDeleteWorker(repository: try Repository.open(at: dir), name: $0)
            }
            for worker in workers {
                _ = try worker.repository.references(matching: prefix + "*")
            }
            let ready = DispatchGroup(), finished = DispatchGroup()
            let start = DispatchSemaphore(value: 0)
            let results = ReferenceDeleteResults()
            for worker in workers {
                ready.enter()
                finished.enter()
                // A dedicated thread, not a GCD worker: this test blocks its
                // own thread below, and on a runner with few cores the global
                // queue's workers may never start while every slot is taken.
                Thread {
                    ready.leave()
                    start.wait()
                    defer { finished.leave() }
                    do {
                        try worker.repository.referenceDelete(name: worker.name)
                    } catch let error as Libgit2Error {
                        results.record(name: worker.name, code: error.code)
                    } catch {
                        results.record(name: worker.name, code: Int32.min)
                    }
                }.start()
            }
            ready.wait()
            for _ in workers { start.signal() }
            finished.wait()

            let failures = results.snapshot()
            #expect(failures.allSatisfy { $0.code == GIT_ELOCKED.rawValue })
            let retryRepo = try Repository.open(at: dir)
            for failure in failures {
                try retryRepo.referenceDelete(name: failure.name)
            }
            #expect(try retryRepo.references(matching: prefix + "*").isEmpty)
        }
    }

    @Test("deleting a loose ref cannot resurrect its older packed target", arguments: [false, true])
    func deleteShadowingReference(guarded: Bool) throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try runGit(["commit", "--allow-empty", "-m", "first"], in: dir)
        let name = "refs/missioncontrol/reviews/pr-80"
        try runGit(["update-ref", name, "HEAD"], in: dir)
        try runGit(["update-ref", name + "-keep", "HEAD"], in: dir)
        try runGit(["pack-refs", "--all", "--prune"], in: dir)
        try runGit(["commit", "--allow-empty", "-m", "second"], in: dir)
        try runGit(["update-ref", name, "HEAD"], in: dir)
        let repo = try Repository.open(at: dir)
        let sha = try repo.resolveOID("HEAD")
        let before = try gitRows(in: dir)

        try repo.referenceDelete(name: name, expectedTargetSHA: guarded ? sha : nil)

        let expected = before.filter { !$0.hasPrefix(name + " ") }
        #expect(try gitRows(in: dir) == expected)
        #expect(try Repository.open(at: dir).references().map { "\($0.name) \($0.targetSHA)" } == expected)
    }

    @Test("missing reference deletion throws not-found", arguments: [false, true])
    func deleteMissingReference(guarded: Bool) throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try Repository.open(at: dir)
        let error = #expect(throws: Libgit2Error.self) {
            try repo.referenceDelete(name: "refs/missioncontrol/reviews/missing",
                                     expectedTargetSHA: guarded ? String(repeating: "1", count: 40) : nil)
        }
        #expect(error?.code == GIT_ENOTFOUND.rawValue)
    }

    @Test("expected targets must be full hexadecimal object IDs")
    func deleteReferenceInvalidExpectedTargets() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try runGit(["commit", "--allow-empty", "-m", "first"], in: dir)
        let name = "refs/missioncontrol/reviews/pr-80"
        try runGit(["update-ref", name, "HEAD"], in: dir)
        let repo = try Repository.open(at: dir)
        let sha = try repo.resolveOID("HEAD")
        let before = try gitRows(in: dir)
        for invalid in ["", "HEAD", String(sha.prefix(7)), sha + "0", sha + "\0",
                        String(repeating: "g", count: 40), String(sha.prefix(39)) + "\0"] {
            let error = #expect(throws: Libgit2Error.self) {
                try repo.referenceDelete(name: name, expectedTargetSHA: invalid)
            }
            #expect(error?.code == GIT_EINVALIDSPEC.rawValue)
            #expect(try gitRows(in: dir) == before)
        }
    }

    @Test("symbolic deletion removes only the named ref and rejects SHA guards", arguments: [false, true])
    func deleteSymbolicReference(dangling: Bool) throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try runGit(["commit", "--allow-empty", "-m", "first"], in: dir)
        let name = "refs/missioncontrol/reviews/pr-80"
        let target = dangling ? "refs/heads/missing" : "refs/heads/main"
        try runGit(["symbolic-ref", name, target], in: dir)
        let repo = try Repository.open(at: dir)
        let sha = try repo.resolveOID("HEAD")
        let before = try gitRows(in: dir)
        let error = #expect(throws: Libgit2Error.self) {
            try repo.referenceDelete(name: name, expectedTargetSHA: sha)
        }
        #expect(error?.code == GIT_EMODIFIED.rawValue)
        #expect(try runGit(["symbolic-ref", name], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines) == target)
        #expect(try gitRows(in: dir) == before)

        try repo.referenceDelete(name: name)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git/" + name).path))
        #expect(try repo.resolveOID("refs/heads/main") == sha)
        #expect(try gitRows(in: dir) == before.filter { !$0.hasPrefix(name + " ") })
    }

    @Test("deletion requires a full, single ref name")
    func deleteReferenceInvalidNames() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try runGit(["commit", "--allow-empty", "-m", "first"], in: dir)
        let repo = try Repository.open(at: dir)
        let before = try gitRows(in: dir)
        for invalid in ["HEAD", "main", "refs/heads/*", "refs/heads/main\0suffix"] {
            let error = #expect(throws: Libgit2Error.self) {
                try repo.referenceDelete(name: invalid)
            }
            #expect(error?.code == GIT_EINVALIDSPEC.rawValue)
            #expect(try gitRows(in: dir) == before)
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

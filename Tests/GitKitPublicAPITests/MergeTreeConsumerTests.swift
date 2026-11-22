// Public external-consumer coverage for native preservation checks:
// `import GitKit` ONLY — no `@testable`, no `CGitKit`, no system `git` CLI.
import Foundation
import Testing
import GitKit

@Suite("Public API merge-tree preservation consumer", .serialized)
struct MergeTreeConsumerTests {

    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("GitKitTests-\(UUID().uuidString)")

    private static let author = Signature(name: "Consumer", email: "consumer@example.com")

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    private func initRepo(_ name: String = "repo") throws -> (URL, Repository) {
        let dir = root.appendingPathComponent(name)
        let repo = try Repository.initialize(at: dir, initialBranch: "main")
        try repo.configSet("user.name", "Consumer")
        try repo.configSet("user.email", "consumer@example.com")
        try repo.configSet("core.autocrlf", "false")
        return (dir, repo)
    }

    private func write(_ data: Data, to relPath: String, in dir: URL) throws {
        let url = dir.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    @discardableResult
    private func commit(
        _ repo: Repository, in dir: URL, files: [String: Data], message: String
    ) throws -> String {
        for (path, data) in files { try write(data, to: path, in: dir) }
        try repo.add(paths: Array(files.keys))
        return try repo.commitDetailed(
            message: message, author: Self.author, allowEmpty: true, env: [:], sign: .noSign
        ).sha
    }

    /// The exact downstream preservation proof:
    /// 1. `isAncestor(remoteOID, of: localOID)` -> preserved;
    /// 2. Else `mergeTree(ours: localOID, theirs: remoteOID)` must be clean,
    ///    pin `ours == localOID` and `theirs == remoteOID`, and yield a tree
    ///    OID equal to `resolveOID("\(localOID)^{tree}")`.
    private func preservesRemote(
        _ repo: Repository, local localOID: String, remote remoteOID: String
    ) throws -> Bool {
        if try repo.isAncestor(remoteOID, of: localOID) {
            return true
        }
        let result = try repo.mergeTree(ours: localOID, theirs: remoteOID)
        #expect(result.ours == localOID)
        #expect(result.theirs == remoteOID)
        guard let mergedTree = result.cleanTree else { return false }
        let localTree = try repo.resolveOID("\(localOID)^{tree}")
        return mergedTree == localTree
    }

    private struct ConsumerSnapshot: Equatable {
        let head: Data?
        let indexBytes: Data?
        let indexMtime: Date?
        let mergeHeadExists: Bool
        let refs: [String: Data]
        let reflogs: [String: Data]
        let worktree: [String: Data]
        let objects: [String: Data]

        static func capture(dir: URL) throws -> ConsumerSnapshot {
            let fm = FileManager.default
            let gitDir = dir.appendingPathComponent(".git")
            let headURL = gitDir.appendingPathComponent("HEAD")
            let indexURL = gitDir.appendingPathComponent("index")
            let indexBytes = fm.fileExists(atPath: indexURL.path) ? try Data(contentsOf: indexURL) : nil
            let indexMtime = fm.fileExists(atPath: indexURL.path)
                ? (try fm.attributesOfItem(atPath: indexURL.path)[.modificationDate] as? Date) : nil
            return ConsumerSnapshot(
                head: fm.fileExists(atPath: headURL.path) ? try Data(contentsOf: headURL) : nil,
                indexBytes: indexBytes,
                indexMtime: indexMtime,
                mergeHeadExists: fm.fileExists(atPath: gitDir.appendingPathComponent("MERGE_HEAD").path),
                refs: try files(under: gitDir.appendingPathComponent("refs")),
                reflogs: try files(under: gitDir.appendingPathComponent("logs")),
                worktree: try files(under: dir, skip: ".git"),
                objects: try files(under: gitDir.appendingPathComponent("objects")))
        }

        private static func files(under root: URL, skip: String? = nil) throws -> [String: Data] {
            let fm = FileManager.default
            guard fm.fileExists(atPath: root.path) else { return [:] }
            let base = root.standardizedFileURL.path
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
                return [:]
            }
            var out: [String: Data] = [:]
            for case let file as URL in enumerator {
                let full = file.standardizedFileURL.path
                let rel = full.hasPrefix(base + "/") ? String(full.dropFirst(base.count + 1)) : file.lastPathComponent
                if let skip, rel == skip || rel.hasPrefix("\(skip)/") {
                    enumerator.skipDescendants()
                    continue
                }
                if (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
                    out[rel] = try Data(contentsOf: file)
                }
            }
            return out
        }
    }

    @Test("binary difference rejects divergent blobs and accepts identical preserved blobs without mutating state")
    func binaryPreservationCheck() throws {
        defer { cleanUp() }
        let (dir, repo) = try initRepo()

        _ = try commit(repo, in: dir, files: ["img.bin": Data([0, 1, 2, 3])], message: "base")
        try repo.checkoutNewBranch(name: "remote-branch")
        let remoteOID = try commit(repo, in: dir, files: ["img.bin": Data([0, 1, 2, 9])], message: "remote bin")

        try repo.checkout(ref: "main")
        let divergentLocal = try commit(repo, in: dir, files: ["img.bin": Data([0, 1, 2, 8])], message: "local bin")

        try repo.checkout(ref: "main")
        try repo.checkoutNewBranch(name: "preserving")
        let preservingLocal = try commit(
            repo, in: dir,
            files: ["img.bin": Data([0, 1, 2, 9]), "extra.txt": Data("new\n".utf8)],
            message: "preserving bin")

        let before = try ConsumerSnapshot.capture(dir: dir)
        #expect(try preservesRemote(repo, local: divergentLocal, remote: remoteOID) == false)
        #expect(try preservesRemote(repo, local: preservingLocal, remote: remoteOID) == true)
        #expect(try ConsumerSnapshot.capture(dir: dir) == before)
    }

    @Test("repeated identical text blocks produce exact independently built tree OID")
    func repeatedIdenticalBlocksTreeOID() throws {
        defer { cleanUp() }
        let (dir, repo) = try initRepo()

        let blk = "row-a\nrow-b\nrow-c\nrow-d\n"
        func doc(_ a: String, _ b: String, _ c: String, _ d: String) -> Data {
            Data([a, b, c, d].joined(separator: "===\n").utf8)
        }
        let edited2 = "row-a\nrow-b-local\nrow-c\nrow-d\n"
        let edited4 = "row-a\nrow-b\nrow-c\nrow-d-remote\n"

        _ = try commit(repo, in: dir, files: ["blocks.txt": doc(blk, blk, blk, blk)], message: "base")
        try repo.checkoutNewBranch(name: "remote")
        let remoteOID = try commit(repo, in: dir, files: ["blocks.txt": doc(blk, blk, blk, edited4)], message: "remote")

        try repo.checkout(ref: "main")
        try repo.checkoutNewBranch(name: "expected-branch")
        let expectedCommit = try commit(
            repo, in: dir, files: ["blocks.txt": doc(blk, edited2, blk, edited4)], message: "expected")
        let expectedTreeOID = try repo.resolveOID("\(expectedCommit)^{tree}")

        try repo.checkout(ref: "main")
        let localOID = try commit(repo, in: dir, files: ["blocks.txt": doc(blk, edited2, blk, blk)], message: "local")

        let before = try ConsumerSnapshot.capture(dir: dir)
        let merged = try repo.mergeTree(ours: localOID, theirs: remoteOID)
        #expect(merged.ours == localOID)
        #expect(merged.theirs == remoteOID)
        #expect(merged.cleanTree == expectedTreeOID)
        // local does NOT yet contain remote's edit to block 4, so preservation must be false.
        #expect(try preservesRemote(repo, local: localOID, remote: remoteOID) == false)
        // expectedCommit contains both edits, so merging it with remote equals expectedTreeOID.
        #expect(try preservesRemote(repo, local: expectedCommit, remote: remoteOID) == true)
        #expect(try ConsumerSnapshot.capture(dir: dir) == before)
    }

    @Test("divergent merge resolutions fail preservation; nearby-context clean rebase and unchanged trees pass")
    func mergeResolutionsNearbyRebaseAndUnchanged() throws {
        defer { cleanUp() }
        let (dir, repo) = try initRepo()

        // 1. Nearby-context clean rebase & unchanged trees.
        let baseLines = "l1\nl2\nl3\nl4\nl5\nl6\nl7\n"
        let upstreamLines = "l1\nl2-up\nl3\nl4\nl5\nl6\nl7\n"
        let remoteLines = "l1\nl2\nl3\nl4\nl5\nl6-rem\nl7\n"
        let rebasedLines = "l1\nl2-up\nl3\nl4\nl5\nl6-rem\nl7\n"

        _ = try commit(repo, in: dir, files: ["code.txt": Data(baseLines.utf8)], message: "base")
        try repo.checkoutNewBranch(name: "remote-work")
        let remoteWork = try commit(repo, in: dir, files: ["code.txt": Data(remoteLines.utf8)], message: "remote")

        try repo.checkout(ref: "main")
        _ = try commit(repo, in: dir, files: ["code.txt": Data(upstreamLines.utf8)], message: "upstream")
        try repo.checkoutNewBranch(name: "rebased-local")
        let rebasedLocal = try commit(repo, in: dir, files: ["code.txt": Data(rebasedLines.utf8)], message: "rebased")

        // 2. Divergent merge resolutions on the same two branches.
        try repo.checkout(ref: "main")
        try repo.checkoutNewBranch(name: "conflict-base")
        _ = try commit(repo, in: dir, files: ["res.txt": Data("orig\n".utf8)], message: "cbase")
        try repo.checkoutNewBranch(name: "branch-b")
        _ = try commit(repo, in: dir, files: ["res.txt": Data("B\n".utf8)], message: "B")
        try repo.checkout(ref: "conflict-base")
        _ = try commit(repo, in: dir, files: ["res.txt": Data("A\n".utf8)], message: "A")

        try repo.checkoutNewBranch(name: "res-remote")
        _ = try repo.merge(ref: "branch-b")
        try write(Data("resolved-remote\n".utf8), to: "res.txt", in: dir)
        try repo.add(paths: ["res.txt"])
        let remoteMerge = try repo.mergeContinue(message: "merge remote", author: Self.author, env: [:], sign: .noSign)

        try repo.checkout(ref: "conflict-base")
        try repo.checkoutNewBranch(name: "res-local")
        _ = try repo.merge(ref: "branch-b")
        try write(Data("resolved-local\n".utf8), to: "res.txt", in: dir)
        try repo.add(paths: ["res.txt"])
        let localMerge = try repo.mergeContinue(message: "merge local", author: Self.author, env: [:], sign: .noSign)

        let before = try ConsumerSnapshot.capture(dir: dir)
        // Nearby-context clean rebase passes preservation and matches local tree OID.
        #expect(try preservesRemote(repo, local: rebasedLocal, remote: remoteWork) == true)
        // Unchanged / equal commits pass via isAncestor and mergeTree.
        #expect(try preservesRemote(repo, local: rebasedLocal, remote: rebasedLocal) == true)
        #expect(try repo.mergeTree(ours: rebasedLocal, theirs: rebasedLocal).cleanTree
            == (try repo.resolveOID("\(rebasedLocal)^{tree}")))
        // Divergent merge resolutions fail preservation.
        #expect(try preservesRemote(repo, local: localMerge.sha, remote: remoteMerge.sha) == false)
        #expect(try ConsumerSnapshot.capture(dir: dir) == before)
    }
}

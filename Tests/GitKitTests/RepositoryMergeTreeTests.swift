import Foundation
import Testing
import CGitKit
@testable import GitKit

@Suite("Repository mergeTree core behaviour", .serialized)
struct RepositoryMergeTreeTests {

    private let fixtures = TemporaryRepositories()

    private func assertPure<T>(
        _ repo: Repository,
        includeObjects: Bool = true,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ body: () throws -> T
    ) throws -> T {
        let before = try RepositoryStateSnapshot.capture(repo: repo, includeObjects: includeObjects)
        let result = try body()
        let after = try RepositoryStateSnapshot.capture(repo: repo, includeObjects: includeObjects)
        #expect(after == before, sourceLocation: sourceLocation)
        return result
    }

    @Test("binary blob changed differently on both sides conflicts with three sides; one-sided change merges cleanly")
    func binaryDifferences() throws {
        defer { fixtures.removeAll() }
        let (_, repo) = try MergeTreeFixture.initRepo(in: fixtures)

        let baseBin = Data([0x00, 0x01, 0x02, 0x03, 0xAA])
        let oursBin = Data([0x00, 0x01, 0x02, 0x03, 0xBB])
        let theirsBin = Data([0x00, 0x01, 0x02, 0x03, 0xCC])

        let base = try MergeTreeFixture.createNativeCommit(
            in: repo, files: ["blob.bin": (baseBin, 0o100644), "note.txt": (Data("base\n".utf8), 0o100644)],
            parents: [], message: "base")
        let ours = try MergeTreeFixture.createNativeCommit(
            in: repo, files: ["blob.bin": (oursBin, 0o100644), "note.txt": (Data("base\n".utf8), 0o100644)],
            parents: [base.commit], message: "ours")
        let theirsDivergent = try MergeTreeFixture.createNativeCommit(
            in: repo, files: ["blob.bin": (theirsBin, 0o100644), "note.txt": (Data("base\n".utf8), 0o100644)],
            parents: [base.commit], message: "theirs-bin")
        let theirsTextOnly = try MergeTreeFixture.createNativeCommit(
            in: repo, files: ["blob.bin": (baseBin, 0o100644), "note.txt": (Data("theirs\n".utf8), 0o100644)],
            parents: [base.commit], message: "theirs-text")
        let expectedOneSided = try MergeTreeFixture.createNativeCommit(
            in: repo, files: ["blob.bin": (oursBin, 0o100644), "note.txt": (Data("theirs\n".utf8), 0o100644)],
            parents: [base.commit], message: "expected")

        let divergent = try assertPure(repo) {
            try repo.mergeTree(ours: ours.commit, theirs: theirsDivergent.commit)
        }
        #expect(divergent.ours == ours.commit)
        #expect(divergent.theirs == theirsDivergent.commit)
        #expect(divergent.mergeBases == [base.commit])
        #expect(divergent.cleanTree == nil)
        guard case .conflicted(let conflicts) = divergent.outcome else {
            Issue.record("expected conflicted outcome for divergent binary blobs")
            return
        }
        #expect(conflicts.count == 1)
        let conflict = try #require(conflicts.first)
        #expect(conflict.path == "blob.bin")
        #expect(conflict.ancestor?.path == "blob.bin")
        #expect(conflict.ours?.path == "blob.bin")
        #expect(conflict.theirs?.path == "blob.bin")
        #expect(conflict.ancestor?.mode == 0o100644)
        #expect(conflict.ours?.oid != conflict.theirs?.oid)

        let oneSided = try assertPure(repo) {
            try repo.mergeTree(ours: ours.commit, theirs: theirsTextOnly.commit)
        }
        #expect(oneSided.outcome == .clean(tree: expectedOneSided.tree))
        #expect(oneSided.cleanTree == expectedOneSided.tree)
    }

    @Test("repeated identical text blocks: edits to 2nd and 4th copies merge cleanly to exact expected tree")
    func repeatedIdenticalTextBlocks() throws {
        defer { fixtures.removeAll() }
        let (_, repo) = try MergeTreeFixture.initRepo(in: fixtures)

        let block = "alpha\nbeta\ngamma\ndelta\n"
        func makeDoc(_ b1: String, _ b2: String, _ b3: String, _ b4: String) -> Data {
            Data(([b1, b2, b3, b4].joined(separator: "---\n")).utf8)
        }
        let b2Edited = "alpha\nbeta-ours\ngamma\ndelta\n"
        let b4Edited = "alpha\nbeta\ngamma\ndelta-theirs\n"

        let base = try MergeTreeFixture.createNativeCommit(
            in: repo, files: ["doc.txt": (makeDoc(block, block, block, block), 0o100644)],
            parents: [], message: "base")
        let ours = try MergeTreeFixture.createNativeCommit(
            in: repo, files: ["doc.txt": (makeDoc(block, b2Edited, block, block), 0o100644)],
            parents: [base.commit], message: "ours")
        let theirs = try MergeTreeFixture.createNativeCommit(
            in: repo, files: ["doc.txt": (makeDoc(block, block, block, b4Edited), 0o100644)],
            parents: [base.commit], message: "theirs")
        let expected = try MergeTreeFixture.createNativeCommit(
            in: repo, files: ["doc.txt": (makeDoc(block, b2Edited, block, b4Edited), 0o100644)],
            parents: [base.commit], message: "expected")

        let result = try assertPure(repo) {
            try repo.mergeTree(ours: ours.commit, theirs: theirs.commit)
        }
        #expect(result.cleanTree == expected.tree)
    }

    @Test("divergent merge resolutions conflict while identical resolutions merge cleanly")
    func mergeResolutions() throws {
        defer { fixtures.removeAll() }
        let (_, repo) = try MergeTreeFixture.initRepo(in: fixtures)

        let base = try MergeTreeFixture.createNativeCommit(
            in: repo, files: ["f.txt": (Data("line\n".utf8), 0o100644)], parents: [], message: "base")
        let sideA = try MergeTreeFixture.createNativeCommit(
            in: repo, files: ["f.txt": (Data("sideA\n".utf8), 0o100644)], parents: [base.commit], message: "A")
        let sideB = try MergeTreeFixture.createNativeCommit(
            in: repo, files: ["f.txt": (Data("sideB\n".utf8), 0o100644)], parents: [base.commit], message: "B")

        let mergeResA = try MergeTreeFixture.createNativeCommit(
            in: repo, files: ["f.txt": (Data("resolved-A\n".utf8), 0o100644)],
            parents: [sideA.commit, sideB.commit], message: "merge A")
        let mergeResB = try MergeTreeFixture.createNativeCommit(
            in: repo, files: ["f.txt": (Data("resolved-B\n".utf8), 0o100644)],
            parents: [sideA.commit, sideB.commit], message: "merge B")
        let mergeResSame = try MergeTreeFixture.createNativeCommit(
            in: repo, files: ["f.txt": (Data("resolved-A\n".utf8), 0o100644)],
            parents: [sideA.commit, sideB.commit], message: "merge A copy", timestamp: 1_700_000_005)

        let divergent = try assertPure(repo) {
            try repo.mergeTree(ours: mergeResA.commit, theirs: mergeResB.commit)
        }
        if case .conflicted(let conflicts) = divergent.outcome {
            #expect(conflicts.map(\.path) == ["f.txt"])
        } else {
            Issue.record("expected conflict for divergent merge resolutions")
        }

        let identical = try assertPure(repo) {
            try repo.mergeTree(ours: mergeResA.commit, theirs: mergeResSame.commit)
        }
        #expect(identical.cleanTree == mergeResA.tree)
    }

    @Test("nearby-context clean rebase preserves remote content and equals local tree")
    func nearbyContextCleanRebase() throws {
        defer { fixtures.removeAll() }
        let (_, repo) = try MergeTreeFixture.initRepo(in: fixtures)

        let baseText = "1\n2\n3\n4\n5\n6\n7\n"
        let upstreamText = "1\n2-upstream\n3\n4\n5\n6\n7\n"
        let remoteText = "1\n2\n3\n4\n5\n6-feature\n7\n"
        let rebasedLocalText = "1\n2-upstream\n3\n4\n5\n6-feature\n7\n"

        let base = try MergeTreeFixture.createNativeCommit(
            in: repo, files: ["file.txt": (Data(baseText.utf8), 0o100644)], parents: [], message: "base")
        let upstream = try MergeTreeFixture.createNativeCommit(
            in: repo, files: ["file.txt": (Data(upstreamText.utf8), 0o100644)],
            parents: [base.commit], message: "upstream")
        let remote = try MergeTreeFixture.createNativeCommit(
            in: repo, files: ["file.txt": (Data(remoteText.utf8), 0o100644)],
            parents: [base.commit], message: "remote")
        let localRebased = try MergeTreeFixture.createNativeCommit(
            in: repo, files: ["file.txt": (Data(rebasedLocalText.utf8), 0o100644)],
            parents: [upstream.commit], message: "local rebased")

        #expect(try repo.isAncestor(remote.commit, of: localRebased.commit) == false)
        let result = try assertPure(repo) {
            try repo.mergeTree(ours: localRebased.commit, theirs: remote.commit)
        }
        #expect(result.cleanTree == localRebased.tree)
        #expect(result.cleanTree == (try repo.resolveOID("\(localRebased.commit)^{tree}")))
    }

    @Test("unchanged trees, equal commits, ancestor checks and non-commit rejection")
    func unchangedEqualAndIsAncestor() throws {
        defer { fixtures.removeAll() }
        let (dir, repo) = try MergeTreeFixture.initRepo(in: fixtures)

        let c1 = try MergeTreeFixture.commitText(repo, in: dir, files: ["a.txt": "1\n"], message: "c1")
        let c2 = try MergeTreeFixture.commitText(repo, in: dir, files: ["a.txt": "2\n"], message: "c2")
        _ = try repo.tagCreateAnnotated(
            name: "v1", target: c1, message: "tag v1",
            tagger: MergeTreeFixture.author, env: [:], sign: .noSign)

        let c2Tree = try repo.resolveOID("\(c2)^{tree}")
        let blobOID = try repo.resolveOID("\(c1):a.txt")

        #expect(try assertPure(repo) { try repo.isAncestor(c1, of: c2) } == true)
        #expect(try assertPure(repo) { try repo.isAncestor("v1", of: c2) } == true)
        #expect(try assertPure(repo) { try repo.isAncestor(c2, of: c2) } == true)
        #expect(try assertPure(repo) { try repo.isAncestor(c2, of: c1) } == false)

        #expect(throws: MergeTreeError.notACommit(c2Tree)) {
            try repo.isAncestor(c2Tree, of: c2)
        }
        #expect(throws: MergeTreeError.notACommit(blobOID)) {
            try repo.mergeTree(ours: blobOID, theirs: c2)
        }

        let equalResult = try assertPure(repo) { try repo.mergeTree(ours: c2, theirs: c2) }
        #expect(equalResult.cleanTree == c2Tree)
        let ancResult = try assertPure(repo) { try repo.mergeTree(ours: c2, theirs: c1) }
        #expect(ancResult.cleanTree == c2Tree)
    }

    @Test("rename on one side plus edit on the other merges cleanly with renames on, conflicts when off")
    func renamePlusEdit() throws {
        defer { fixtures.removeAll() }
        let (_, repo) = try MergeTreeFixture.initRepo(in: fixtures)

        let body = (1...20).map { "line \($0)\n" }.joined()
        let editedBody = "line 1-edited\n" + (2...20).map { "line \($0)\n" }.joined()

        let base = try MergeTreeFixture.createNativeCommit(
            in: repo, files: ["old.txt": (Data(body.utf8), 0o100644)], parents: [], message: "base")
        let oursRenamed = try MergeTreeFixture.createNativeCommit(
            in: repo, files: ["new.txt": (Data(body.utf8), 0o100644)], parents: [base.commit], message: "rename")
        let theirsEdited = try MergeTreeFixture.createNativeCommit(
            in: repo, files: ["old.txt": (Data(editedBody.utf8), 0o100644)], parents: [base.commit], message: "edit")
        let expected = try MergeTreeFixture.createNativeCommit(
            in: repo, files: ["new.txt": (Data(editedBody.utf8), 0o100644)], parents: [base.commit], message: "exp")

        let detected = try assertPure(repo) {
            try repo.mergeTree(ours: oursRenamed.commit, theirs: theirsEdited.commit)
        }
        #expect(detected.cleanTree == expected.tree)

        let disabled = try assertPure(repo) {
            try repo.mergeTree(
                ours: oursRenamed.commit, theirs: theirsEdited.commit,
                options: MergeTreeOptions(renames: .off))
        }
        #expect(disabled.cleanTree == nil)
        if case .conflicted(let conflicts) = disabled.outcome {
            #expect(conflicts.map(\.path) == ["old.txt"])
        } else {
            Issue.record("expected conflict when rename detection is disabled")
        }
    }

    @Test("filemode: one-sided executable change merges cleanly; conflicting modes conflict")
    func filemodeHandling() throws {
        defer { fixtures.removeAll() }
        let (_, repo) = try MergeTreeFixture.initRepo(in: fixtures)

        let script = Data("#!/bin/sh\necho hi\n".utf8)
        let base = try MergeTreeFixture.createNativeCommit(
            in: repo, files: ["run.sh": (script, 0o100644), "doc.txt": (Data("a\n".utf8), 0o100644)],
            parents: [], message: "base")
        let oursExec = try MergeTreeFixture.createNativeCommit(
            in: repo, files: ["run.sh": (script, 0o100755), "doc.txt": (Data("a\n".utf8), 0o100644)],
            parents: [base.commit], message: "chmod +x")
        let theirsDoc = try MergeTreeFixture.createNativeCommit(
            in: repo, files: ["run.sh": (script, 0o100644), "doc.txt": (Data("b\n".utf8), 0o100644)],
            parents: [base.commit], message: "doc edit")
        let expected = try MergeTreeFixture.createNativeCommit(
            in: repo, files: ["run.sh": (script, 0o100755), "doc.txt": (Data("b\n".utf8), 0o100644)],
            parents: [base.commit], message: "expected")

        let clean = try assertPure(repo) {
            try repo.mergeTree(ours: oursExec.commit, theirs: theirsDoc.commit)
        }
        #expect(clean.cleanTree == expected.tree)

        // Conflicting mode: regular vs symlink on same path.
        let theirsLink = try MergeTreeFixture.createNativeCommit(
            in: repo, files: ["run.sh": (Data("target".utf8), 0o120000), "doc.txt": (Data("a\n".utf8), 0o100644)],
            parents: [base.commit], message: "symlink")
        let conflicted = try assertPure(repo) {
            try repo.mergeTree(ours: oursExec.commit, theirs: theirsLink.commit)
        }
        if case .conflicted(let conflicts) = conflicted.outcome {
            #expect(conflicts.map(\.path) == ["run.sh"])
            #expect(conflicts.first?.ours?.mode == 0o100755)
            #expect(conflicts.first?.theirs?.mode == 0o120000)
        } else {
            Issue.record("expected mode conflict between executable file and symlink")
        }
    }

    @Test("criss-cross history with 2 merge bases: recursive vs non-recursive diverge")
    func crissCrossMergeBases() throws {
        defer { fixtures.removeAll() }
        let (_, repo) = try MergeTreeFixture.initRepo(in: fixtures)

        let base0 = try MergeTreeFixture.createNativeCommit(
            in: repo,
            files: ["a.txt": (Data("0\n".utf8), 0o100644), "b.txt": (Data("0\n".utf8), 0o100644)],
            parents: [], message: "base0")
        let b1 = try MergeTreeFixture.createNativeCommit(
            in: repo,
            files: ["a.txt": (Data("1\n".utf8), 0o100644), "b.txt": (Data("0\n".utf8), 0o100644)],
            parents: [base0.commit], message: "b1")
        let b2 = try MergeTreeFixture.createNativeCommit(
            in: repo,
            files: ["a.txt": (Data("0\n".utf8), 0o100644), "b.txt": (Data("2\n".utf8), 0o100644)],
            parents: [base0.commit], message: "b2")

        // Criss-cross merges:
        // m1 merges b1 & b2 and further edits a.txt -> "1-final"
        // m2 merges b2 & b1 and further edits b.txt -> "2-final"
        let m1 = try MergeTreeFixture.createNativeCommit(
            in: repo,
            files: ["a.txt": (Data("1-final\n".utf8), 0o100644), "b.txt": (Data("2\n".utf8), 0o100644)],
            parents: [b1.commit, b2.commit], message: "m1")
        let m2 = try MergeTreeFixture.createNativeCommit(
            in: repo,
            files: ["a.txt": (Data("1\n".utf8), 0o100644), "b.txt": (Data("2-final\n".utf8), 0o100644)],
            parents: [b2.commit, b1.commit], message: "m2")
        let expected = try MergeTreeFixture.createNativeCommit(
            in: repo,
            files: ["a.txt": (Data("1-final\n".utf8), 0o100644), "b.txt": (Data("2-final\n".utf8), 0o100644)],
            parents: [m1.commit, m2.commit], message: "expected")

        let recursive = try assertPure(repo) {
            try repo.mergeTree(ours: m1.commit, theirs: m2.commit)
        }
        #expect(recursive.mergeBases.count == 2)
        #expect(Set(recursive.mergeBases) == Set([b1.commit, b2.commit]))
        #expect(recursive.cleanTree == expected.tree)

        // Without recursive base merging, picking a single base (either b1 or b2)
        // sees both m1 and m2 changing the other side's file differently -> conflict!
        let nonRecursive = try assertPure(repo) {
            try repo.mergeTree(
                ours: m1.commit, theirs: m2.commit,
                options: MergeTreeOptions(recursiveBases: false))
        }
        #expect(nonRecursive.mergeBases.count == 2)
        #expect(nonRecursive.cleanTree == nil)
    }

    @Test("explicit tree form: nil base uses add/add semantics and non-tree specs throw notATree")
    func treeFormAndNilBase() throws {
        defer { fixtures.removeAll() }
        let (_, repo) = try MergeTreeFixture.initRepo(in: fixtures)

        let left = try MergeTreeFixture.createNativeCommit(
            in: repo,
            files: ["only-left.txt": (Data("L\n".utf8), 0o100644), "shared.txt": (Data("1\n".utf8), 0o100644)],
            parents: [], message: "left")
        let rightClean = try MergeTreeFixture.createNativeCommit(
            in: repo,
            files: ["only-right.txt": (Data("R\n".utf8), 0o100644), "shared.txt": (Data("1\n".utf8), 0o100644)],
            parents: [], message: "right-clean")
        let rightConflict = try MergeTreeFixture.createNativeCommit(
            in: repo, files: ["shared.txt": (Data("2\n".utf8), 0o100644)],
            parents: [], message: "right-conflict")
        let expected = try MergeTreeFixture.createNativeCommit(
            in: repo,
            files: [
                "only-left.txt": (Data("L\n".utf8), 0o100644),
                "only-right.txt": (Data("R\n".utf8), 0o100644),
                "shared.txt": (Data("1\n".utf8), 0o100644)
            ],
            parents: [], message: "expected")

        let clean = try assertPure(repo) {
            try repo.mergeTree(base: nil, ours: left.tree, theirs: rightClean.tree)
        }
        #expect(clean.ours == left.tree)
        #expect(clean.theirs == rightClean.tree)
        #expect(clean.mergeBases.isEmpty)
        #expect(clean.cleanTree == expected.tree)

        let conflicted = try assertPure(repo) {
            try repo.mergeTree(base: nil, ours: left.commit, theirs: rightConflict.commit)
        }
        #expect(conflicted.ours == left.tree)
        #expect(conflicted.theirs == rightConflict.tree)
        guard case .conflicted(let conflicts) = conflicted.outcome else {
            Issue.record("expected add/add conflict")
            return
        }
        #expect(conflicts.count == 1)
        #expect(conflicts[0].path == "shared.txt")
        #expect(conflicts[0].ancestor == nil)
        #expect(conflicts[0].ours?.path == "shared.txt")
        #expect(conflicts[0].theirs?.path == "shared.txt")

        let blobOID = try repo.resolveOID("\(left.commit):shared.txt")
        #expect(throws: MergeTreeError.notATree(blobOID)) {
            try repo.mergeTree(base: blobOID, ours: left.tree, theirs: rightClean.tree)
        }
    }
}

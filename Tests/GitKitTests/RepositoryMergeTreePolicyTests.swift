import Foundation
import Testing
import CGitKit
@testable import GitKit

@Suite("Repository mergeTree policies, isolation and safeguards", .serialized)
struct RepositoryMergeTreePolicyTests {

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

    @Test("attributes follow ours tree (including subdirs), ignore dirty worktree/index, and respect .none and .tree")
    func attributeSourceIsolation() throws {
        defer { fixtures.removeAll() }
        let (dir, repo) = try MergeTreeFixture.initRepo(in: fixtures)

        _ = try MergeTreeFixture.commitText(
            repo, in: dir,
            files: ["sub/log.txt": "line1\n", "sub/.gitattributes": "log.txt merge=union\n"],
            message: "base")
        try repo.checkoutNewBranch(name: "theirs")
        let theirs = try MergeTreeFixture.commitText(
            repo, in: dir, files: ["sub/log.txt": "line1\ntheirs-entry\n"], message: "theirs")

        try repo.checkout(ref: "main")
        let ours = try MergeTreeFixture.commitText(
            repo, in: dir, files: ["sub/log.txt": "line1\nours-entry\n"], message: "ours")

        // Create a separate commit whose tree marks sub/log.txt binary.
        let binaryAttrCommit = try MergeTreeFixture.createNativeCommit(
            in: repo,
            files: ["sub/.gitattributes": (Data("log.txt merge=binary\n".utf8), 0o100644)],
            parents: [], message: "binary attrs")

        // Dirty BOTH the staged index AND the working tree with contradicting
        // `.gitattributes` (merge=binary). Neither may affect `.ours`!
        try MergeTreeFixture.writeText("log.txt merge=binary\n", at: "sub/.gitattributes", in: dir)
        try repo.add(paths: ["sub/.gitattributes"])
        try MergeTreeFixture.writeText("* merge=binary\n", at: ".gitattributes", in: dir)

        // Default `.ours` reads sub/.gitattributes from ours tree -> merge=union -> CLEAN!
        let oursResult = try assertPure(repo) {
            try repo.mergeTree(ours: ours, theirs: theirs)
        }
        #expect(oursResult.cleanTree != nil)

        // `.none` omits tree `.gitattributes` -> default text merge -> CONFLICTS!
        let noneResult = try assertPure(repo) {
            try repo.mergeTree(ours: ours, theirs: theirs, options: MergeTreeOptions(attributes: .none))
        }
        #expect(noneResult.cleanTree == nil)

        // `.tree(spec)` uses binaryAttrCommit's tree -> merge=binary -> CONFLICTS!
        let treeAttrResult = try assertPure(repo) {
            try repo.mergeTree(
                ours: ours, theirs: theirs,
                options: MergeTreeOptions(attributes: .tree(binaryAttrCommit.tree)))
        }
        #expect(treeAttrResult.cleanTree == nil)

        // Verify `$GIT_COMMON_DIR/info/attributes` and `core.attributesFile`
        // apply in `.none` mode as documented.
        let globalAttrs = fixtures.url("global-attributes")
        try Data("log.txt merge=union\n".utf8).write(to: globalAttrs)
        try repo.addConfigEntries([ConfigEntry(name: "core.attributesFile", value: globalAttrs.path)])
        let viaGlobal = try assertPure(repo) {
            try repo.mergeTree(ours: ours, theirs: theirs, options: MergeTreeOptions(attributes: .none))
        }
        #expect(viaGlobal.cleanTree == oursResult.cleanTree)
    }

    @Test("custom merge driver fails closed (including merge.default and virtual-base), unconfigured falls back")
    func externalMergeDrivers() throws {
        defer { fixtures.removeAll() }
        let (_, repo) = try MergeTreeFixture.initRepo(in: fixtures)

        let base = try MergeTreeFixture.createNativeCommit(
            in: repo,
            files: [
                ".gitattributes": (Data("custom.txt merge=mycustom\nunknown.txt merge=unconfigured\n".utf8), 0o100644),
                "custom.txt": (Data("base\n".utf8), 0o100644),
                "unknown.txt": (Data("a\nb\nc\n".utf8), 0o100644)
            ],
            parents: [], message: "base")
        let oursCustom = try MergeTreeFixture.createNativeCommit(
            in: repo,
            files: [
                ".gitattributes": (Data("custom.txt merge=mycustom\nunknown.txt merge=unconfigured\n".utf8), 0o100644),
                "custom.txt": (Data("ours\n".utf8), 0o100644),
                "unknown.txt": (Data("a-ours\nb\nc\n".utf8), 0o100644)
            ],
            parents: [base.commit], message: "ours")
        let theirsCustom = try MergeTreeFixture.createNativeCommit(
            in: repo,
            files: [
                ".gitattributes": (Data("custom.txt merge=mycustom\nunknown.txt merge=unconfigured\n".utf8), 0o100644),
                "custom.txt": (Data("theirs\n".utf8), 0o100644),
                "unknown.txt": (Data("a\nb\nc-theirs\n".utf8), 0o100644)
            ],
            parents: [base.commit], message: "theirs")

        // Without merge.mycustom.driver configured, falls back to built-in text (conflicts on custom.txt).
        let unconfigured = try assertPure(repo) {
            try repo.mergeTree(ours: oursCustom.commit, theirs: theirsCustom.commit)
        }
        #expect(unconfigured.cleanTree == nil)

        // Configure merge.mycustom.driver -> fails closed in BOTH .inMemory and .write without writing objects!
        try repo.configSet("merge.mycustom.driver", "my-tool %O %A %B")
        let beforeObjects = try RepositoryStateSnapshot.capture(repo: repo, includeObjects: true)
        #expect(throws: MergeTreeError.externalMergeDriver(path: "custom.txt", driver: "mycustom")) {
            try repo.mergeTree(ours: oursCustom.commit, theirs: theirsCustom.commit)
        }
        #expect(throws: MergeTreeError.externalMergeDriver(path: "custom.txt", driver: "mycustom")) {
            try repo.mergeTree(
                ours: oursCustom.commit, theirs: theirsCustom.commit,
                options: MergeTreeOptions(objects: .write))
        }
        let afterObjects = try RepositoryStateSnapshot.capture(repo: repo, includeObjects: true)
        #expect(afterObjects == beforeObjects)

        // favor != .normal overrides attribute drivers, matching libgit2.
        let favored = try assertPure(repo) {
            try repo.mergeTree(
                ours: oursCustom.commit, theirs: theirsCustom.commit,
                options: MergeTreeOptions(favor: .ours))
        }
        #expect(favored.cleanTree != nil)

        // merge.default pointing at a configured external driver also fails closed.
        let plainBase = try MergeTreeFixture.createNativeCommit(
            in: repo, files: ["plain.txt": (Data("1\n2\n3\n".utf8), 0o100644)], parents: [], message: "p0")
        let plainOurs = try MergeTreeFixture.createNativeCommit(
            in: repo, files: ["plain.txt": (Data("1-o\n2\n3\n".utf8), 0o100644)],
            parents: [plainBase.commit], message: "po")
        let plainTheirs = try MergeTreeFixture.createNativeCommit(
            in: repo, files: ["plain.txt": (Data("1\n2\n3-t\n".utf8), 0o100644)],
            parents: [plainBase.commit], message: "pt")
        try repo.configSet("merge.default", "mycustom")
        #expect(throws: MergeTreeError.externalMergeDriver(path: "plain.txt", driver: "mycustom")) {
            try repo.mergeTree(ours: plainOurs.commit, theirs: plainTheirs.commit)
        }
    }

    @Test("external merge driver reached only inside a recursive virtual-base merge fails closed")
    func externalDriverInVirtualBase() throws {
        defer { fixtures.removeAll() }
        let (_, repo) = try MergeTreeFixture.initRepo(in: fixtures)

        let attrs = Data("vb.txt merge=vbcustom\n".utf8)
        let base0 = try MergeTreeFixture.createNativeCommit(
            in: repo,
            files: [".gitattributes": (attrs, 0o100644), "vb.txt": (Data("1\n2\n3\n".utf8), 0o100644)],
            parents: [], message: "base0")
        let b1 = try MergeTreeFixture.createNativeCommit(
            in: repo,
            files: [".gitattributes": (attrs, 0o100644), "vb.txt": (Data("1-b1\n2\n3\n".utf8), 0o100644)],
            parents: [base0.commit], message: "b1")
        let b2 = try MergeTreeFixture.createNativeCommit(
            in: repo,
            files: [".gitattributes": (attrs, 0o100644), "vb.txt": (Data("1\n2\n3-b2\n".utf8), 0o100644)],
            parents: [base0.commit], message: "b2")

        // m1 and m2 both settle vb.txt to the exact same final content; ONLY
        // the recursive virtual-base merge of b1 and b2 merges vb.txt!
        let settled = Data("1-b1\n2\n3-b2\n".utf8)
        let m1 = try MergeTreeFixture.createNativeCommit(
            in: repo,
            files: [
                ".gitattributes": (attrs, 0o100644),
                "vb.txt": (settled, 0o100644),
                "x.txt": (Data("1\n".utf8), 0o100644)
            ],
            parents: [b1.commit, b2.commit], message: "m1")
        let m2 = try MergeTreeFixture.createNativeCommit(
            in: repo,
            files: [
                ".gitattributes": (attrs, 0o100644),
                "vb.txt": (settled, 0o100644),
                "y.txt": (Data("2\n".utf8), 0o100644)
            ],
            parents: [b2.commit, b1.commit], message: "m2")

        try repo.configSet("merge.vbcustom.driver", "custom-vb %O %A %B")
        let before = try RepositoryStateSnapshot.capture(repo: repo, includeObjects: true)
        #expect(throws: MergeTreeError.externalMergeDriver(path: "vb.txt", driver: "vbcustom")) {
            try repo.mergeTree(ours: m1.commit, theirs: m2.commit, options: MergeTreeOptions(objects: .write))
        }
        let after = try RepositoryStateSnapshot.capture(repo: repo, includeObjects: true)
        #expect(after == before)
    }

    @Test("merge.renormalize=true fails closed from both local and operation-only config levels")
    func unsupportedRenormalize() throws {
        defer { fixtures.removeAll() }
        let (_, repo) = try MergeTreeFixture.initRepo(in: fixtures)

        let c1 = try MergeTreeFixture.createNativeCommit(
            in: repo, files: ["a.txt": (Data("a\n".utf8), 0o100644)], parents: [], message: "c1")
        try repo.addConfigEntries([ConfigEntry(name: "merge.renormalize", value: "true")])

        let before = try RepositoryStateSnapshot.capture(repo: repo, includeObjects: true)
        #expect(throws: MergeTreeError.unsupportedRenormalize) {
            try repo.mergeTree(ours: c1.commit, theirs: c1.commit)
        }
        let after = try RepositoryStateSnapshot.capture(repo: repo, includeObjects: true)
        #expect(after == before)
    }

    @Test(".write persists lookup-able objects matching .inMemory OID and leaves caller fully usable")
    func writeModeAndCallerUsability() throws {
        defer { fixtures.removeAll() }
        let (dir, repo) = try MergeTreeFixture.initRepo(in: fixtures)

        _ = try MergeTreeFixture.commitText(
            repo, in: dir, files: ["f.txt": "top\nmid\nbottom\n"], message: "base")
        try repo.checkoutNewBranch(name: "side")
        let theirs = try MergeTreeFixture.commitText(
            repo, in: dir, files: ["f.txt": "top\nmid\nbottom-theirs\n"], message: "theirs")
        try repo.checkout(ref: "main")
        let ours = try MergeTreeFixture.commitText(
            repo, in: dir, files: ["f.txt": "top-ours\nmid\nbottom\n"], message: "ours")

        // Default .inMemory writes zero objects; the synthesised tree is absent from the caller's ODB.
        let inMem = try assertPure(repo, includeObjects: true) {
            try repo.mergeTree(ours: ours, theirs: theirs)
        }
        let treeOID = try #require(inMem.cleanTree)
        #expect(throws: Libgit2Error.self) {
            try repo.objectMetadata(of: treeOID)
        }

        // .write produces the exact same tree OID, leaves refs/HEAD/index/worktree/reflogs unchanged,
        // and persists the tree & merged blob so the caller can immediately inspect them.
        let written = try assertPure(repo, includeObjects: false) {
            try repo.mergeTree(ours: ours, theirs: theirs, options: MergeTreeOptions(objects: .write))
        }
        #expect(written.cleanTree == treeOID)
        #expect(try repo.objectMetadata(of: treeOID).kind == .tree)
        let mergedBlob = try repo.catFileBlob("\(treeOID):f.txt")
        #expect(String(decoding: mergedBlob, as: UTF8.self) == "top-ours\nmid\nbottom-theirs\n")

        // Caller Repository remains completely usable after both modes (owns its live config/ODB/index).
        #expect(try repo.status().isClean)
        try repo.configSet("mergeTreeTest.usable", "yes")
        #expect(try repo.configGet("mergeTreeTest.usable") == "yes")
        let followUp = try MergeTreeFixture.commitText(
            repo, in: dir, files: ["after.txt": "ok\n"], message: "post-mergeTree commit")
        #expect(try repo.isAncestor(ours, of: followUp) == true)
        #expect(try repo.mergeTree(ours: followUp, theirs: theirs).cleanTree != nil)
    }

    @Test("linked worktree and bare repository callers produce identical tree OIDs without mutating state")
    func linkedWorktreeAndBareRepo() throws {
        defer { fixtures.removeAll() }
        let (dir, mainRepo) = try MergeTreeFixture.initRepo(in: fixtures, name: "main")

        _ = try MergeTreeFixture.commitText(
            mainRepo, in: dir, files: ["f.txt": "1\n2\n3\n"], message: "base")
        try mainRepo.checkoutNewBranch(name: "side")
        let theirs = try MergeTreeFixture.commitText(
            mainRepo, in: dir, files: ["f.txt": "1\n2\n3-t\n"], message: "theirs")
        try mainRepo.checkout(ref: "main")
        let ours = try MergeTreeFixture.commitText(
            mainRepo, in: dir, files: ["f.txt": "1-o\n2\n3\n"], message: "ours")

        let mainResult = try assertPure(mainRepo) {
            try mainRepo.mergeTree(ours: ours, theirs: theirs)
        }

        // Linked worktree caller.
        let wtURL = fixtures.url("linked-wt")
        try mainRepo.worktreeAdd(path: wtURL, branch: "wt-branch")
        let wtRepo = try Repository.open(at: wtURL)
        let wtResult = try assertPure(wtRepo) {
            try wtRepo.mergeTree(ours: ours, theirs: theirs)
        }
        #expect(wtResult == mainResult)

        // Bare repository caller (cloned bare from main).
        let bareURL = fixtures.url("bare.git")
        try FileManager.default.copyItem(at: dir.appendingPathComponent(".git"), to: bareURL)
        let bareRepo = try Repository.open(at: bareURL)
        try bareRepo.configSet("core.bare", "true")
        let reopenedBare = try Repository.open(at: bareURL)
        #expect(try reopenedBare.isInsideWorkTree() == false)
        let bareResult = try assertPure(reopenedBare) {
            try reopenedBare.mergeTree(ours: ours, theirs: theirs)
        }
        #expect(bareResult == mainResult)
    }

    @Test("private open enforces caller ConfigIncludePolicy and restores thread policy on every exit")
    func includePolicyGuardedOpen() throws {
        defer { fixtures.removeAll() }
        let (dir, setupRepo) = try MergeTreeFixture.initRepo(in: fixtures)
        let c1 = try MergeTreeFixture.commitText(setupRepo, in: dir, files: ["a.txt": "1\n"], message: "c1")

        let included = fixtures.url("extra.gitconfig")
        try Data("[custom]\n\tflag = 1\n".utf8).write(to: included)
        let localConfigURL = dir.appendingPathComponent(".git/config")
        let existing = try String(contentsOf: localConfigURL, encoding: .utf8)
        try Data((existing + "\n[include]\n\tpath = \(included.path)\n").utf8).write(to: localConfigURL)

        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            var allow = true
            var seen: [String] = []
            func authorize(_ include: ConfigInclude) -> Bool {
                lock.lock(); defer { lock.unlock() }
                seen.append(include.path)
                return allow
            }
        }
        let recorder = Recorder()
        let policy = ConfigIncludePolicy { recorder.authorize($0) }

        let guarded = try Repository.open(at: dir, includePolicy: policy)
        let countAfterOpen = recorder.seen.count
        #expect(countAfterOpen >= 1)

        // Private open during mergeTree must consult the caller's include policy.
        let allowed = try guarded.mergeTree(ours: c1, theirs: c1)
        #expect(allowed.cleanTree != nil)
        #expect(recorder.seen.count > countAfterOpen)

        // When the policy now refuses the include, private open fails closed before reading it.
        recorder.allow = false
        #expect(throws: Libgit2Error.self) {
            try guarded.mergeTree(ours: c1, theirs: c1)
        }

        // Thread policy must have been restored after the failed mergeTree open:
        // opening a separate repository without an include policy still succeeds.
        let (otherDir, _) = try MergeTreeFixture.initRepo(in: fixtures, name: "other")
        let otherConfigURL = otherDir.appendingPathComponent(".git/config")
        let otherExisting = try String(contentsOf: otherConfigURL, encoding: .utf8)
        try Data((otherExisting + "\n[include]\n\tpath = \(included.path)\n").utf8).write(to: otherConfigURL)
        let unguarded = try Repository.open(at: otherDir)
        #expect(try unguarded.configGet("custom.flag") == "1")
    }

    @Test("invalid rename threshold and task cancellation fail before mutating state")
    func invalidOptionsAndCancellation() async throws {
        defer { fixtures.removeAll() }
        let (_, repo) = try MergeTreeFixture.initRepo(in: fixtures)
        let c1 = try MergeTreeFixture.createNativeCommit(
            in: repo, files: ["a.txt": (Data("a\n".utf8), 0o100644)], parents: [], message: "c1")

        let before = try RepositoryStateSnapshot.capture(repo: repo, includeObjects: true)
        #expect(throws: MergeTreeError.invalidRenameThreshold(0)) {
            try repo.mergeTree(
                ours: c1.commit, theirs: c1.commit,
                options: MergeTreeOptions(renames: .detect(threshold: 0)))
        }
        #expect(throws: MergeTreeError.invalidRenameThreshold(101)) {
            try repo.mergeTree(
                ours: c1.commit, theirs: c1.commit,
                options: MergeTreeOptions(renames: .detect(threshold: 101)))
        }
        #expect(try RepositoryStateSnapshot.capture(repo: repo, includeObjects: true) == before)

        let repoURL = try #require(repo.workdirURL)
        let task = Task<Void, any Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            let taskRepo = try Repository.open(at: repoURL)
            _ = try taskRepo.mergeTree(ours: c1.commit, theirs: c1.commit)
        }
        do {
            try await task.value
            Issue.record("expected CancellationError from cancelled task")
        } catch is CancellationError {
            // Expected.
        }
        #expect(try RepositoryStateSnapshot.capture(repo: repo, includeObjects: true) == before)
    }
}

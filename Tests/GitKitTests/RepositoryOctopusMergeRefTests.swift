// `Repository.octopusMerge` where HEAD's branch moves or goes away while
// the merge is made: git's update_ref refuses, and the merge is left
// staged. Forks `git`, so non-Windows only, as `RepositoryOctopusMergeTests`.
#if os(macOS) || os(Linux)
import Foundation
import Testing
import CGitKit
@testable import GitKit

extension RepositoryOctopusMergeTests {

    @Test("a branch moved on while the merge was made stays, the merge staged, as git's update_ref leaves it")
    func branchMovedMeanwhile() throws {
        let dir = try makeRepository()
        func oid(_ name: String) throws -> git_oid {
            var oid = git_oid()
            _ = try git(["rev-parse", name], in: dir).stdout.withCString { git_oid_fromstr(&oid, $0) }
            return oid
        }
        let start = try oid("HEAD"), tree = try oid("HEAD^{tree}"), heads = [try oid("a"), try oid("b")]
        // Something else moves the branch after the merge began.
        try git(["update-ref", "refs/heads/main", "b"], in: dir)
        let moved = try git(["rev-parse", "b"], in: dir).stdout
        let repository = try Repository.open(at: dir)
        let outcome = try repository.conclude(head: start, headTree: tree, mergedTree: tree, oids: heads,
                                              noFastForward: true, message: "Merge", author: nil, env: Self.identity)
        #expect(outcome == .headMoved(expected: try git(["rev-parse", "HEAD@{1}"], in: dir).stdout, actual: moved))
        #expect(try git(["rev-parse", "main"], in: dir).stdout == moved)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git/MERGE_HEAD").path))
    }

    @Test("a branch deleted while the merge was made leaves the merge staged, as git's update_ref leaves it")
    func branchDeletedMeanwhile() throws {
        let dir = try makeRepository()
        func oid(_ name: String) throws -> git_oid {
            var oid = git_oid()
            _ = try git(["rev-parse", name], in: dir).stdout.withCString { git_oid_fromstr(&oid, $0) }
            return oid
        }
        let start = try oid("HEAD"), tree = try oid("HEAD^{tree}"), heads = [try oid("a"), try oid("b")]
        try git(["update-ref", "-d", "refs/heads/main"], in: dir)
        let repository = try Repository.open(at: dir)
        let outcome = try repository.conclude(head: start, headTree: tree, mergedTree: tree, oids: heads,
                                              noFastForward: true, message: "Merge", author: nil, env: Self.identity)
        #expect(outcome == .headMissing(ref: "refs/heads/main"))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git/MERGE_HEAD").path))
    }

    @Test("a merge left staged whose merge state can't be written is taken back, index and work tree")
    func stagedMergeStateUnwritable() throws {
        let dir = try makeRepository()
        func oid(_ name: String) throws -> git_oid {
            var oid = git_oid()
            _ = try git(["rev-parse", name], in: dir).stdout.withCString { git_oid_fromstr(&oid, $0) }
            return oid
        }
        let start = try oid("HEAD"), tree = try oid("HEAD^{tree}"), heads = [try oid("a"), try oid("b")]
        let merged = try oid("a^{tree}"), startSHA = try git(["rev-parse", "HEAD"], in: dir).stdout
        try git(["update-ref", "refs/heads/main", "b"], in: dir)
        // MERGE_MSG can't be written where a directory stands.
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git/MERGE_MSG"),
                                                withIntermediateDirectories: false)
        let repository = try Repository.open(at: dir)
        #expect(throws: (any Error).self) {
            try repository.conclude(head: start, headTree: tree, mergedTree: merged, oids: heads,
                                    noFastForward: true, message: "Merge", author: nil, env: Self.identity)
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git/MERGE_HEAD").path))
        #expect(try git(["diff", "--cached", "--name-only", startSHA], in: dir).stdout.isEmpty)
        #expect(try git(["diff", "--name-only", startSHA], in: dir).stdout.isEmpty)
        #expect(try git(["ls-files", "--others", "--exclude-standard"], in: dir).stdout.isEmpty)
    }

    @Test("a merge taken back also takes back what sparsity settled outside the merge's paths")
    func stagedMergeStateUnwritableAfterSparsity() throws {
        let dir = try makeRepository()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("s"), withIntermediateDirectories: true)
        try write("old\n", to: "s/old", in: dir)
        try git(["add", "s/old"], in: dir)
        try git(["commit", "-q", "-m", "s"], in: dir)
        // A file the rules leave out, still in the work tree: sparsity
        // takes it away when the merge settles.
        try git(["config", "core.sparseCheckout", "true"], in: dir)
        try git(["config", "core.sparseCheckoutCone", "false"], in: dir)
        try Data("/*\n!/s/\n".utf8).write(to: dir.appendingPathComponent(".git/info/sparse-checkout"))
        func oid(_ name: String) throws -> git_oid {
            var oid = git_oid()
            _ = try git(["rev-parse", name], in: dir).stdout.withCString { git_oid_fromstr(&oid, $0) }
            return oid
        }
        let start = try oid("HEAD"), tree = try oid("HEAD^{tree}"), heads = [try oid("a"), try oid("b")]
        try git(["update-ref", "refs/heads/main", "b"], in: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git/MERGE_MSG"),
                                                withIntermediateDirectories: false)
        let repository = try Repository.open(at: dir)
        #expect(throws: (any Error).self) {
            try repository.conclude(head: start, headTree: tree, mergedTree: tree, oids: heads,
                                    noFastForward: true, message: "Merge", author: nil, env: Self.identity) {
                try repository.reapplySparsity()
            }
        }
        #expect(try git(["ls-files", "-v", "s"], in: dir).stdout == "H s/old")
        #expect(try String(contentsOf: dir.appendingPathComponent("s/old"), encoding: .utf8) == "old\n")
    }

    @Test("a core.ignorecase that isn't a boolean stops the merge before anything changes, as git dies on it")
    func ignoreCaseNotBoolean() throws {
        let dir = try makeRepository()
        try git(["config", "core.ignorecase", "maybe"], in: dir)
        let files = ["index", "refs/heads/main"].map { dir.appendingPathComponent(".git/" + $0) }
        let before = try files.map { try Data(contentsOf: $0) }
        #expect(throws: Libgit2Error.self) { try merge(["a", "b"], in: dir) }
        #expect(try files.map { try Data(contentsOf: $0) } == before)
        if try gitIsAtLeast(2, 54) {
            #expect(throws: (any Error).self) { try git(["merge", "-q", "a", "b"], in: dir) }
        }
    }
}
#endif

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
}
#endif

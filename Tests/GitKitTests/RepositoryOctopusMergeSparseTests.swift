// `Repository.octopusMerge` in a sparse checkout, against the system
// `git`: what lies outside the sparse checkout stays out of the work tree.
// Forks `git`, so non-Windows only, as `RepositoryOctopusMergeTests`.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

extension RepositoryOctopusMergeTests {

    @Test("in a cone-mode sparse checkout, what the merge brings outside the cone stays out, as git leaves it")
    func sparseCheckoutStaysSparse() throws {
        let dir = try makeRepository()
        let files = ["out/f", "inc/i", "inc/deep/d", "x/y/f", "x/f"]
        for file in files {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(file).deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try write("1\n", to: file, in: dir)
        }
        try git(["add", "-A"], in: dir)
        try git(["commit", "-q", "-m", "tree"], in: dir)
        try git(["checkout", "-q", "-b", "sparse"], in: dir)
        let added = ["out/new", "inc/new", "newroot", "x/n", "x/y/n", "x/q/n"]
        for file in files + added {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(file).deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try write("2\n", to: file, in: dir)
        }
        try git(["add", "-A"], in: dir)
        try git(["commit", "-q", "-m", "sparse"], in: dir)
        try git(["checkout", "-q", "main"], in: dir)
        // init first: git before 2.35 takes `set --cone`'s flag for a pattern.
        try git(["sparse-checkout", "init", "--cone"], in: dir)
        try git(["sparse-checkout", "set", "inc", "x/y"], in: dir)
        // Skip-worktree inside the cone, and missing: the merge writes it.
        try git(["update-index", "--skip-worktree", "inc/i"], in: dir)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("inc/i"))

        let other = try twin(of: dir)
        let result = try merge(["c", "sparse"], in: dir)
        try git(["merge", "-q", "-m", "Merge branches", "c", "sparse"], in: other)
        guard case .mergeCommit = result.outcome else {
            Issue.record("expected a merge commit, got \(result.outcome)"); return
        }
        // Older gits' octopus doesn't keep a sparse checkout so.
        let compare = try gitIsAtLeast(2, 54)
        for url in compare ? [dir, other] : [dir] {
            #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("out").path))
            #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("x/q").path))
            #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("inc/i").path))
        }
        #expect(try git(["ls-files", "-v", "out", "x/q"], in: dir).stdout == "S out/f\nS out/new\nS x/q/n")
        guard compare else { return }
        #expect(try git(["ls-files", "-v"], in: dir).stdout == git(["ls-files", "-v"], in: other).stdout)
        #expect(try state(of: dir) == state(of: other))
    }

    @Test("cone-mode sparse-checkout patterns take what git takes")
    func sparseCone() throws {
        let cone = try #require(Repository.SparseCone("/*\n!/*/\n/x/\n!/x/*/\n/inc/\n/x/y/\n"))
        #expect(cone.includes("top") && cone.includes("x/f") && cone.includes("x/y/z/f") && cone.includes("inc/a/b"))
        #expect(!cone.includes("x/q/f") && !cone.includes("out/f"))
        #expect(Repository.SparseCone("*.c\n") == nil)
    }
}
#endif

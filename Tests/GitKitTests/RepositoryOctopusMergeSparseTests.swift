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
        let folding = try #require(Repository.SparseCone("/*\n!/*/\n/Foo/\n", ignoreCase: true))
        #expect(folding.includes("foo/bar") && folding.includes("FOO/x/y"))
        #expect(!(try #require(Repository.SparseCone("/*\n!/*/\n/Foo/\n"))).includes("foo/bar"))
    }

    @Test("non-cone sparse-checkout patterns keep what the merge brings outside them out, as git does")
    func nonConeSparseCheckout() throws {
        let dir = try makeRepository()
        func put(_ files: [String], _ text: String) throws {
            for file in files {
                let folder = dir.appendingPathComponent(file).deletingLastPathComponent()
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try write(text, to: file, in: dir)
            }
        }
        let files = ["out/f", "out/keep/k", "a.log", "src/a.c", "docs/x.md", "docs/y.txt"]
        try put(files, "1\n")
        try git(["add", "-A"], in: dir)
        try git(["commit", "-q", "-m", "tree"], in: dir)
        try git(["checkout", "-q", "-b", "sparse"], in: dir)
        try put(files + ["out/new", "out/keep/new", "b.log", "src/b.c", "docs/z.md", "docs/w.txt", "deep/out/n"], "2\n")
        try git(["add", "-A"], in: dir)
        try git(["commit", "-q", "-m", "sparse"], in: dir)
        try git(["checkout", "-q", "main"], in: dir)
        try git(["config", "core.sparseCheckout", "true"], in: dir)
        try git(["config", "core.sparseCheckoutCone", "false"], in: dir)
        try "/*\n!/out/\n/out/keep/\n!*.log\n!docs/*.txt\n"
            .write(to: dir.appendingPathComponent(".git/info/sparse-checkout"), atomically: true, encoding: .utf8)
        try git(["read-tree", "-mu", "HEAD"], in: dir)

        let other = try twin(of: dir)
        let result = try merge(["c", "sparse"], in: dir)
        try git(["merge", "-q", "-m", "Merge branches", "c", "sparse"], in: other)
        guard case .mergeCommit = result.outcome else {
            Issue.record("expected a merge commit, got \(result.outcome)"); return
        }
        let skipped = try git(["ls-files", "-v"], in: dir).stdout.split(separator: "\n").filter { $0.hasPrefix("S ") }
        #expect(skipped == ["S a.log", "S b.log", "S docs/w.txt", "S docs/y.txt", "S out/f", "S out/new"])
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("out/new").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("out/keep/new").path))
        guard try gitIsAtLeast(2, 54) else { return }
        #expect(try git(["ls-files", "-v"], in: dir).stdout == git(["ls-files", "-v"], in: other).stdout)
        #expect(try state(of: dir) == state(of: other))
    }

    @Test("non-cone sparse-checkout patterns: the last match decides, directories pass theirs on")
    func sparsePatterns() {
        let patterns = SparsePatterns("# comment\n/*\n!/out/\n/out/keep/\n!*.log\n!docs/*.txt\n")
        #expect(patterns.includes("top") && patterns.includes("docs/a.md") && patterns.includes("deep/out/n"))
        #expect(patterns.includes("out/keep/x/y"))
        #expect(!patterns.includes("out/f") && !patterns.includes("x.log") && !patterns.includes("docs/a.txt"))
        #expect(!SparsePatterns("").includes("anything"))
        #expect(SparsePatterns("A\n", ignoreCase: true).includes("a") && !SparsePatterns("A\n").includes("a"))
    }
}
#endif

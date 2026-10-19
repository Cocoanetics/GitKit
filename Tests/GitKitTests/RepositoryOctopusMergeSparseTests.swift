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
        // A comment that isn't UTF-8 costs the other lines nothing.
        let rules = Data("# caf".utf8) + Data([0xE9, 0x0A]) + Data("/*\n!/out/\n/out/keep/\n!*.log\n!docs/*.txt\n".utf8)
        try rules.write(to: dir.appendingPathComponent(".git/info/sparse-checkout"))
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

    @Test("the merge works skip-worktree out again for paths it doesn't touch, as git does")
    func staleSparseBitsReapplied() throws {
        let dir = try makeRepository()
        for file in ["inc/i", "out/o"] {
            let folder = dir.appendingPathComponent(file).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try write("1\n", to: file, in: dir)
        }
        try git(["add", "-A"], in: dir)
        try git(["commit", "-q", "-m", "tree"], in: dir)
        try git(["sparse-checkout", "init", "--cone"], in: dir)
        try git(["sparse-checkout", "set", "inc"], in: dir)
        // Stale both ways: missing and skipped inside the cone, present
        // and not skipped outside it.
        try git(["update-index", "--skip-worktree", "inc/i"], in: dir)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("inc/i"))
        try git(["update-index", "--no-skip-worktree", "out/o"], in: dir)
        try git(["checkout", "--", "out/o"], in: dir)

        let other = try twin(of: dir)
        let result = try merge(["a", "b"], in: dir)
        try git(["merge", "-q", "-m", "Merge branches", "a", "b"], in: other)
        guard case .mergeCommit = result.outcome else {
            Issue.record("expected a merge commit, got \(result.outcome)"); return
        }
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("inc/i").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("out").path))
        #expect(try git(["ls-files", "-v", "inc", "out"], in: dir).stdout == "H inc/i\nS out/o")
        guard try gitIsAtLeast(2, 54) else { return }
        #expect(try git(["ls-files", "-v"], in: dir).stdout == git(["ls-files", "-v"], in: other).stdout)
        #expect(try state(of: dir) == state(of: other))
    }

    @Test("a changed file outside the sparse patterns stays, assume-unchanged or not, as git leaves it")
    func sparseKeepsChangedFile() throws {
        let dir = try makeRepository()
        for file in ["inc/i", "out/o"] {
            let folder = dir.appendingPathComponent(file).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try write("1\n", to: file, in: dir)
        }
        try git(["add", "-A"], in: dir)
        try git(["commit", "-q", "-m", "tree"], in: dir)
        try git(["sparse-checkout", "init", "--cone"], in: dir)
        try git(["sparse-checkout", "set", "inc"], in: dir)
        try git(["update-index", "--no-skip-worktree", "out/o"], in: dir)
        try git(["checkout", "--", "out/o"], in: dir)
        try git(["update-index", "--assume-unchanged", "out/o"], in: dir)
        try write("edited\n", to: "out/o", in: dir)

        let other = try twin(of: dir)
        let result = try merge(["a", "b"], in: dir)
        _ = try git(["merge", "-q", "-m", "Merge branches", "a", "b"], in: other, check: false)
        guard case .mergeCommit = result.outcome else {
            Issue.record("expected a merge commit, got \(result.outcome)"); return
        }
        let edited = try String(contentsOf: dir.appendingPathComponent("out/o"), encoding: .utf8)
        #expect(edited == "edited\n")
        #expect(try git(["ls-files", "-v", "out"], in: dir).stdout == "h out/o")
        guard try gitIsAtLeast(2, 54) else { return }
        #expect(try git(["ls-files", "-v"], in: dir).stdout == git(["ls-files", "-v"], in: other).stdout)
    }

    @Test("a clean file outside the cone that the merge updates goes, its entry skip-worktree, as git leaves it")
    func sparseMaterializedFileUpdated() throws {
        let dir = try makeRepository()
        for file in ["inc/i", "out/o"] {
            let folder = dir.appendingPathComponent(file).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try write("1\n", to: file, in: dir)
        }
        try git(["add", "-A"], in: dir)
        try git(["commit", "-q", "-m", "tree"], in: dir)
        try git(["checkout", "-q", "-b", "upd"], in: dir)
        try write("2\n", to: "out/o", in: dir)
        try git(["commit", "-q", "-am", "upd"], in: dir)
        try git(["checkout", "-q", "main"], in: dir)
        try git(["sparse-checkout", "init", "--cone"], in: dir)
        try git(["sparse-checkout", "set", "inc"], in: dir)
        try git(["update-index", "--no-skip-worktree", "out/o"], in: dir)
        try git(["checkout", "--", "out/o"], in: dir)

        let other = try twin(of: dir)
        let result = try merge(["c", "upd"], in: dir)
        try git(["merge", "-q", "-m", "Merge branches", "c", "upd"], in: other)
        guard case .mergeCommit = result.outcome else {
            Issue.record("expected a merge commit, got \(result.outcome)"); return
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("out").path))
        #expect(try git(["ls-files", "-v", "out"], in: dir).stdout == "S out/o")
        #expect(try git(["rev-parse", ":out/o"], in: dir).stdout == git(["rev-parse", "upd:out/o"], in: dir).stdout)
        guard try gitIsAtLeast(2, 54) else { return }
        #expect(try state(of: dir) == state(of: other))
    }

    @Test("submodules get skip-worktree worked out again too, as git's merge does")
    func sparseGitlinksReapplied() throws {
        let dir = try makeRepository()
        let inc = dir.appendingPathComponent("inc")
        try FileManager.default.createDirectory(at: inc, withIntermediateDirectories: true)
        try write("1\n", to: "inc/i", in: dir)
        try git(["add", "-A"], in: dir)
        let head = try git(["rev-parse", "HEAD"], in: dir).stdout
        for path in ["out/sub", "inc/sub"] {
            try git(["update-index", "--add", "--cacheinfo", "160000,\(head),\(path)"], in: dir)
        }
        try git(["commit", "-q", "-m", "subs"], in: dir)
        try git(["sparse-checkout", "init", "--cone"], in: dir)
        try git(["sparse-checkout", "set", "inc"], in: dir)
        // Stale both ways.
        try git(["update-index", "--no-skip-worktree", "out/sub"], in: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("out/sub"),
                                                withIntermediateDirectories: true)
        try git(["update-index", "--skip-worktree", "inc/sub"], in: dir)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("inc/sub"))

        let other = try twin(of: dir)
        let result = try merge(["a", "b"], in: dir)
        try git(["merge", "-q", "-m", "Merge branches", "a", "b"], in: other)
        guard case .mergeCommit = result.outcome else {
            Issue.record("expected a merge commit, got \(result.outcome)"); return
        }
        #expect(try git(["ls-files", "-v", "inc/sub", "out/sub"], in: dir).stdout == "H inc/sub\nS out/sub")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("out").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("inc/sub").path))
        guard try gitIsAtLeast(2, 54) else { return }
        #expect(try git(["ls-files", "-v"], in: dir).stdout == git(["ls-files", "-v"], in: other).stdout)
    }

    @Test("an excluded file that can't be removed, or looked at, stops the merge before HEAD moves",
          arguments: [0o555, 0o644])
    func sparseRemovalFailureStops(mode: Int) throws {
        let dir = try makeRepository()
        for file in ["inc/i", "out/o"] {
            let folder = dir.appendingPathComponent(file).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try write("1\n", to: file, in: dir)
        }
        try git(["add", "-A"], in: dir)
        try git(["commit", "-q", "-m", "tree"], in: dir)
        try git(["checkout", "-q", "-b", "upd"], in: dir)
        try write("2\n", to: "out/o", in: dir)
        try write("2\n", to: "inc/i", in: dir)
        try git(["commit", "-q", "-am", "upd"], in: dir)
        try git(["checkout", "-q", "main"], in: dir)
        try git(["sparse-checkout", "init", "--cone"], in: dir)
        try git(["sparse-checkout", "set", "inc"], in: dir)
        try git(["update-index", "--no-skip-worktree", "out/o"], in: dir)
        try git(["checkout", "--", "out/o"], in: dir)
        let out = dir.appendingPathComponent("out").path
        // Read-only, or without search permission.
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: out)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: out) }
        // Where permissions don't hold (root), there's nothing to see.
        guard getuid() != 0 else { return }
        let head = try git(["rev-parse", "HEAD"], in: dir).stdout
        #expect(throws: (any Error).self) { try merge(["c", "upd"], in: dir) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: out)
        #expect(try git(["rev-parse", "HEAD"], in: dir).stdout == head)
        let kept = try String(contentsOf: dir.appendingPathComponent("out/o"), encoding: .utf8)
        #expect(kept == "1\n")
        // Nor is any of the merge left staged or checked out.
        for path in ["out/o", "inc/i"] {
            let staged = try git(["rev-parse", ":" + path], in: dir).stdout
            #expect(try staged == git(["rev-parse", "HEAD:" + path], in: dir).stdout)
        }
        let included = try String(contentsOf: dir.appendingPathComponent("inc/i"), encoding: .utf8)
        #expect(included == "1\n")
    }

    @Test("a submodule outside the cone that the merge makes a file keeps its directory with files")
    func sparseKeepsSubmoduleFiles() throws {
        let dir = try makeRepository()
        let inc = dir.appendingPathComponent("inc")
        try FileManager.default.createDirectory(at: inc, withIntermediateDirectories: true)
        try write("1\n", to: "inc/i", in: dir)
        try git(["add", "-A"], in: dir)
        let head = try git(["rev-parse", "HEAD"], in: dir).stdout
        try git(["update-index", "--add", "--cacheinfo", "160000,\(head),out/sub"], in: dir)
        try git(["commit", "-q", "-m", "sub"], in: dir)
        try git(["checkout", "-q", "-b", "tofile"], in: dir)
        try git(["rm", "-q", "--cached", "out/sub"], in: dir)
        let blob = try git(["hash-object", "-w", "--stdin"], in: dir).stdout
        try git(["update-index", "--add", "--cacheinfo", "100644,\(blob),out/sub"], in: dir)
        try git(["commit", "-q", "-m", "tofile"], in: dir)
        try git(["checkout", "-q", "-f", "main"], in: dir)
        try git(["sparse-checkout", "init", "--cone"], in: dir)
        try git(["sparse-checkout", "set", "inc"], in: dir)
        // The submodule's directory, initialized, with its files.
        try git(["update-index", "--no-skip-worktree", "out/sub"], in: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("out/sub"),
                                                withIntermediateDirectories: true)
        try write("mine\n", to: "out/sub/file", in: dir)

        _ = try merge(["c", "tofile"], in: dir)
        let kept = try String(contentsOf: dir.appendingPathComponent("out/sub/file"), encoding: .utf8)
        #expect(kept == "mine\n")
    }

    @Test("a file standing where a submodule outside the cone is recorded stays, unmarked")
    func sparseKeepsFileAtGitlink() throws {
        let dir = try makeRepository()
        let inc = dir.appendingPathComponent("inc")
        try FileManager.default.createDirectory(at: inc, withIntermediateDirectories: true)
        try write("1\n", to: "inc/i", in: dir)
        try git(["add", "-A"], in: dir)
        let head = try git(["rev-parse", "HEAD"], in: dir).stdout
        try git(["update-index", "--add", "--cacheinfo", "160000,\(head),out/sub"], in: dir)
        try git(["commit", "-q", "-m", "sub"], in: dir)
        try git(["sparse-checkout", "init", "--cone"], in: dir)
        try git(["sparse-checkout", "set", "inc"], in: dir)
        try git(["update-index", "--no-skip-worktree", "out/sub"], in: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("out"),
                                                withIntermediateDirectories: true)
        try write("mine\n", to: "out/sub", in: dir)

        _ = try merge(["a", "b"], in: dir)
        let kept = try String(contentsOf: dir.appendingPathComponent("out/sub"), encoding: .utf8)
        #expect(kept == "mine\n")
        #expect(try git(["ls-files", "-v", "out/sub"], in: dir).stdout == "H out/sub")
    }

    @Test("a sparse rule that isn't UTF-8 stops the merge before anything changes")
    func sparseRuleNotUTF8() throws {
        let dir = try makeRepository()
        try git(["config", "core.sparseCheckout", "true"], in: dir)
        try git(["config", "core.sparseCheckoutCone", "false"], in: dir)
        let rules = Data("/*\n!/x".utf8) + Data([0xFF, 0x0A])
        try rules.write(to: dir.appendingPathComponent(".git/info/sparse-checkout"))
        let before = try state(of: dir)
        let error = #expect(throws: Libgit2Error.self) { try merge(["a", "b"], in: dir) }
        #expect(error?.message.hasSuffix("is not valid UTF-8") == true)
        #expect(try state(of: dir) == before)
    }
}
#endif

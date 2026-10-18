// `Repository.octopusMerge` against the system `git`'s octopus strategy:
// each scenario runs in a repository and in a copy of it, one merged by
// GitKit and one by `git merge`, and the two must agree. Forks `git`, so
// non-Windows only, as `RepositoryMergeTests`.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

@Suite("Repository.octopusMerge")
struct RepositoryOctopusMergeTests {

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static let identity = [
        "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@e.com", "GIT_AUTHOR_DATE": "2020-01-01T00:00:00Z",
        "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@e.com", "GIT_COMMITTER_DATE": "2020-01-01T00:00:00Z",
    ]

    /// `git <args>` in `dir`: its exit status and output.
    @discardableResult
    private func git(_ args: [String], in dir: URL, check: Bool = true) throws -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = dir
        process.environment = ProcessInfo.processInfo.environment.merging(Self.identity) { $1 }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        if check, process.terminationStatus != 0 {
            throw Failure(description: "git \(args.joined(separator: " ")): \(stderr)")
        }
        return (process.terminationStatus, stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func write(_ text: String, to name: String, in dir: URL) throws {
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }

    /// `main` one commit past `base`, and branches off `base`: `a` and
    /// `b` change the first and last line of `f`, `x` the first line as
    /// `a` does, but differently, `c` adds `c`.
    private func makeRepository() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OctopusMergeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: dir)
        try write("1\n2\n3\n4\n5\n6\n7\n", to: "f", in: dir)
        try git(["add", "f"], in: dir)
        try git(["commit", "-q", "-m", "base"], in: dir)
        try git(["tag", "base"], in: dir)
        for (branch, text) in [("a", "1a\n2\n3\n4\n5\n6\n7\n"), ("b", "1\n2\n3\n4\n5\n6\n7b\n"),
                               ("x", "1x\n2\n3\n4\n5\n6\n7\n")] {
            try git(["checkout", "-q", "-b", branch, "base"], in: dir)
            try write(text, to: "f", in: dir)
            try git(["commit", "-q", "-am", branch], in: dir)
        }
        try git(["checkout", "-q", "-b", "c", "base"], in: dir)
        try write("c\n", to: "c", in: dir)
        try git(["add", "c"], in: dir)
        try git(["commit", "-q", "-m", "c"], in: dir)
        try git(["checkout", "-q", "main"], in: dir)
        try write("m\n", to: "m", in: dir)
        try git(["add", "m"], in: dir)
        try git(["commit", "-q", "-m", "m"], in: dir)
        return dir
    }

    private func twin(of dir: URL) throws -> URL {
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("OctopusMergeTwin-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: dir, to: copy)
        return copy
    }

    private func merge(_ heads: [String], in dir: URL, noFastForward: Bool = false) throws -> OctopusMergeResult {
        let repository = try Repository.open(at: dir)
        let reduced = try repository.mergeHeads(reducing: heads)
        return try repository.octopusMerge(
            heads: reduced.heads, noFastForward: noFastForward,
            message: "Merge branches", env: Self.identity)
    }

    /// What a merge leaves to compare: HEAD's tree and parents, the
    /// status, and the merge state files.
    private func state(of dir: URL) throws -> [String] {
        let gitDir = dir.appendingPathComponent(".git")
        var state = [
            try git(["log", "-1", "--format=%T %P"], in: dir).stdout,
            try git(["status", "--porcelain"], in: dir).stdout,
        ]
        for name in ["MERGE_HEAD", "MERGE_MODE"] {
            state.append(name + ": " + ((try? String(contentsOf: gitDir.appendingPathComponent(name), encoding: .utf8)) ?? "-"))
        }
        return state
    }

    @Test("merges each head into a commit with HEAD and them as parents")
    func mergesAllHeads() throws {
        let dir = try makeRepository()
        let other = try twin(of: dir)
        let result = try merge(["a", "b", "c"], in: dir)
        try git(["merge", "-q", "-m", "Merge branches", "a", "b", "c"], in: other)

        #expect(result.steps.map(\.kind) == [.merge, .merge, .merge])
        #expect(result.steps.map(\.head) == ["a", "b", "c"])
        #expect(result.steps[0].automatic == nil)
        #expect(result.steps[1].automatic == [.merged(path: "f")])
        guard case .mergeCommit(let sha, let summary, let added, _) = result.outcome else {
            Issue.record("expected a merge commit, got \(result.outcome)"); return
        }
        #expect(sha == (try git(["rev-parse", "HEAD"], in: dir).stdout))
        #expect(summary.hasSuffix("2 files changed, 3 insertions(+), 2 deletions(-)"))
        #expect(added == [" create mode 100644 c"])
        #expect(try state(of: dir) == state(of: other))
        #expect(try git(["log", "-1", "--format=%P"], in: dir).stdout.split(separator: " ").count == 4)
    }

    @Test("fast-forwards to the first head when HEAD is behind it, leaving HEAD out")
    func fastForwardsFirst() throws {
        let dir = try makeRepository()
        try git(["reset", "-q", "--hard", "base"], in: dir)
        let other = try twin(of: dir)
        let result = try merge(["a", "b"], in: dir)
        try git(["merge", "-q", "-m", "Merge branches", "a", "b"], in: other)

        #expect(result.steps.map(\.kind) == [.fastForward, .merge])
        #expect(try state(of: dir) == state(of: other))
        #expect(try git(["log", "-1", "--format=%P"], in: dir).stdout
                == git(["rev-parse", "a", "b"], in: dir).stdout.replacingOccurrences(of: "\n", with: " "))
    }

    @Test("--no-ff keeps HEAD among the parents")
    func noFastForward() throws {
        let dir = try makeRepository()
        try git(["reset", "-q", "--hard", "base"], in: dir)
        let other = try twin(of: dir)
        _ = try merge(["a", "b"], in: dir, noFastForward: true)
        try git(["merge", "-q", "--no-ff", "-m", "Merge branches", "a", "b"], in: other)
        #expect(try state(of: dir) == state(of: other))
    }

    @Test("leaves the last head's conflicts for the user")
    func conflictsInLastHead() throws {
        let dir = try makeRepository()
        let other = try twin(of: dir)
        let result = try merge(["a", "b", "x"], in: dir)
        #expect(try git(["merge", "-q", "-m", "Merge branches", "a", "b", "x"], in: other, check: false).status == 1)

        #expect(result.outcome == .conflicts(paths: ["f"]))
        #expect(result.steps.last?.automatic == [.conflict(path: "f")])
        #expect(try state(of: dir) == state(of: other))
        let message = try String(contentsOf: dir.appendingPathComponent(".git/MERGE_MSG"), encoding: .utf8)
        #expect(message == "Merge branches\n\n# Conflicts:\n#\tf\n")
        #expect(try git(["rev-parse", "ORIG_HEAD"], in: dir).stdout == git(["rev-parse", "main"], in: dir).stdout)
    }

    @Test("gives up, changing nothing, when an earlier head conflicts")
    func conflictsBeforeLastHead() throws {
        let dir = try makeRepository()
        let other = try twin(of: dir)
        let result = try merge(["a", "x", "b"], in: dir)
        #expect(try git(["merge", "-q", "-m", "Merge branches", "a", "x", "b"], in: other, check: false).status == 2)

        #expect(result.outcome == .failed(.conflictsBeforeLastHead))
        #expect(result.steps.map(\.head) == ["a", "x"])
        #expect(try state(of: dir) == state(of: other))
    }

    @Test("refuses an index that differs from HEAD")
    func refusesLocalChanges() throws {
        let dir = try makeRepository()
        try write("changed\n", to: "m", in: dir)
        try git(["add", "m"], in: dir)
        let other = try twin(of: dir)
        let result = try merge(["a", "b"], in: dir)
        #expect(try git(["merge", "-q", "a", "b"], in: other, check: false).status == 2)

        #expect(result.outcome == .failed(.localChanges(paths: ["m"])))
        #expect(result.steps.isEmpty)
        #expect(try state(of: dir) == state(of: other))
    }

    @Test("refuses to overwrite a change in the working tree, keeping it")
    func refusesDirtyWorkingTree() throws {
        let dir = try makeRepository()
        try write("1\n2\n3\n4\n5\n6\n7\ndirty\n", to: "f", in: dir)
        let other = try twin(of: dir)
        let result = try merge(["a", "b"], in: dir)
        #expect(try git(["merge", "-q", "a", "b"], in: other, check: false).status == 2)

        #expect(result.outcome == .failed(.notUpToDate(path: "f")))
        #expect(result.steps.map(\.kind) == [.merge])
        #expect(try state(of: dir) == state(of: other))
    }

    @Test("keeps a change in the working tree the merge doesn't touch")
    func keepsUntouchedChange() throws {
        let dir = try makeRepository()
        try write("dirty\n", to: "m", in: dir)
        let other = try twin(of: dir)
        _ = try merge(["a", "b"], in: dir)
        try git(["merge", "-q", "-m", "Merge branches", "a", "b"], in: other)
        #expect(try state(of: dir) == state(of: other))
    }

    @Test("reduces heads as git does")
    func reducesHeads() throws {
        let dir = try makeRepository()
        let repository = try Repository.open(at: dir)
        // `base` is in HEAD's history; `a` twice is one head.
        #expect(try repository.mergeHeads(reducing: ["a", "base", "a", "b"])
                == MergeHeads(heads: ["a", "b"], headSubsumed: false))
        // HEAD is in `main`, which is HEAD.
        #expect(try repository.mergeHeads(reducing: ["main"]) == MergeHeads(heads: [], headSubsumed: false))

        try git(["reset", "-q", "--hard", "base"], in: dir)
        #expect(try Repository.open(at: dir).mergeHeads(reducing: ["a", "b"])
                == MergeHeads(heads: ["a", "b"], headSubsumed: true))
        try git(["branch", "a2", "a"], in: dir)
        try git(["checkout", "-q", "a2"], in: dir)
        try write("more\n", to: "more", in: dir)
        try git(["add", "more"], in: dir)
        try git(["commit", "-q", "-m", "more"], in: dir)
        try git(["checkout", "-q", "main"], in: dir)
        // `a` is in `a2`'s history.
        #expect(try Repository.open(at: dir).mergeHeads(reducing: ["a", "a2"])
                == MergeHeads(heads: ["a2"], headSubsumed: true))
    }

    @Test("names heads as git's merge message does")
    func mergeNames() throws {
        let dir = try makeRepository()
        try git(["tag", "t", "b"], in: dir)
        try git(["update-ref", "refs/remotes/origin/a", "a"], in: dir)
        let sha = try git(["rev-parse", "a"], in: dir).stdout
        let repository = try Repository.open(at: dir)
        #expect(repository.mergeName("a") == "branch 'a'")
        #expect(repository.mergeName("refs/heads/a") == "branch 'refs/heads/a'")
        #expect(repository.mergeName("t") == "tag 't'")
        #expect(repository.mergeName("origin/a") == "remote-tracking branch 'origin/a'")
        #expect(repository.mergeName("a~1") == "branch 'a' (early part)")
        #expect(repository.mergeName("a^") == "branch 'a' (early part)")
        #expect(repository.mergeName("a~0") == "branch 'a'")
        #expect(repository.mergeName("a^0") == "commit 'a^0'")
        #expect(repository.mergeName("origin/a~1") == "commit 'origin/a~1'")
        #expect(repository.mergeName(sha) == "commit '\(sha)'")
    }

    @Test("refuses what names no commit, as git does")
    func refusesUnknownHead() throws {
        let dir = try makeRepository()
        #expect(throws: Libgit2Error.self) {
            try Repository.open(at: dir).mergeHeads(reducing: ["a", "nope"])
        }
    }
}
#endif

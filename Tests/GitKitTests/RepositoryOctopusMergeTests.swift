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

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static let identity = [
        "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@e.com", "GIT_AUTHOR_DATE": "2020-01-01T00:00:00Z",
        "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@e.com", "GIT_COMMITTER_DATE": "2020-01-01T00:00:00Z"
    ]

    /// `git <args>` in `dir`: its exit status and output.
    @discardableResult
    func git(
        _ args: [String], in dir: URL, check: Bool = true, date: String? = nil
    ) throws -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = dir
        var environment = ProcessInfo.processInfo.environment.merging(Self.identity) { $1 }
        if let date { environment["GIT_AUTHOR_DATE"] = date; environment["GIT_COMMITTER_DATE"] = date }
        process.environment = environment
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

    func write(_ text: String, to name: String, in dir: URL) throws {
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }

    /// `main` one commit past `base`, and branches off `base`: `a` and
    /// `b` change the first and last line of `f`, `x` the first line as
    /// `a` does, but differently, `c` adds `c`.
    func makeRepository() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OctopusMergeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: dir)
        // No background gc or maintenance racing the copies of the repo.
        try git(["config", "gc.auto", "0"], in: dir)
        try git(["config", "maintenance.auto", "false"], in: dir)
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

    /// After a merge that gave up: `dir` as it was `before`, and, with a
    /// git that restores what a failed octopus touched (2.54; Linux CI
    /// has 2.34), as the system `git` left `other`.
    func expectGaveUp(
        _ dir: URL, before: [String], like other: URL, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        #expect(try state(of: dir) == before, sourceLocation: sourceLocation)
        if try gitIsAtLeast(2, 54) {
            #expect(try state(of: dir) == state(of: other), sourceLocation: sourceLocation)
        }
    }

    /// Whether the system `git` is at least `major.minor`.
    func gitIsAtLeast(_ major: Int, _ minor: Int) throws -> Bool {
        let version = try git(["--version"], in: FileManager.default.temporaryDirectory).stdout
        let numbers = version.split(separator: " ").dropFirst(2).first?
            .split(separator: ".").prefix(2).compactMap { Int($0) } ?? []
        guard numbers.count == 2 else { return false }
        return numbers[0] > major || (numbers[0] == major && numbers[1] >= minor)
    }

    func twin(of dir: URL) throws -> URL {
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("OctopusMergeTwin-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: dir, to: copy)
        return copy
    }

    func merge(_ heads: [String], in dir: URL, noFastForward: Bool = false) throws -> OctopusMergeResult {
        let repository = try Repository.open(at: dir)
        let reduced = try repository.mergeHeads(reducing: heads)
        return try repository.octopusMerge(
            heads: reduced.heads, noFastForward: noFastForward,
            message: "Merge branches", env: Self.identity)
    }

    /// What a merge leaves to compare: HEAD's tree and parents, the
    /// status, and the merge state files.
    func state(of dir: URL) throws -> [String] {
        let gitDir = dir.appendingPathComponent(".git")
        var state = [
            try git(["log", "-1", "--format=%T %P"], in: dir).stdout,
            try git(["status", "--porcelain"], in: dir).stdout
        ]
        for name in ["MERGE_HEAD", "MERGE_MODE"] {
            let text = try? String(contentsOf: gitDir.appendingPathComponent(name), encoding: .utf8)
            state.append(name + ": " + (text ?? "-"))
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
        guard case .mergeCommit(let sha, let summary, let added, _, _) = result.outcome else {
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

    @Test("comments every line of a conflicted path in MERGE_MSG, with git's comment character",
          arguments: [nil, ";"])
    func mergeMessageComments(commentChar: String?) throws {
        let dir = try makeRepository()
        let name = "we\nird"
        try git(["checkout", "-q", "-b", "n1", "base"], in: dir)
        try write("1\n", to: name, in: dir)
        try git(["add", "."], in: dir)
        try git(["commit", "-q", "-m", "n1"], in: dir)
        try git(["checkout", "-q", "-b", "n2", "base"], in: dir)
        try write("2\n", to: name, in: dir)
        try git(["add", "."], in: dir)
        try git(["commit", "-q", "-m", "n2"], in: dir)
        try git(["checkout", "-q", "main"], in: dir)
        if let commentChar { try git(["config", "core.commentChar", commentChar], in: dir) }
        let other = try twin(of: dir)
        _ = try merge(["a", "n1", "n2"], in: dir)
        #expect(try git(["merge", "-q", "-m", "Merge branches", "a", "n1", "n2"], in: other, check: false).status == 1)
        let ours = try String(contentsOf: dir.appendingPathComponent(".git/MERGE_MSG"), encoding: .utf8)
        let theirs = try String(contentsOf: other.appendingPathComponent(".git/MERGE_MSG"), encoding: .utf8)
        #expect(ours == theirs)
        let comment = commentChar ?? "#"
        #expect(ours == "Merge branches\n\n\(comment) Conflicts:\n\(comment)\twe\n\(comment) ird\n")
    }

    @Test("gives up, changing nothing, when an earlier head conflicts")
    func conflictsBeforeLastHead() throws {
        let dir = try makeRepository()
        let other = try twin(of: dir)
        let before = try state(of: dir)
        let result = try merge(["a", "x", "b"], in: dir)
        #expect(try git(["merge", "-q", "-m", "Merge branches", "a", "x", "b"], in: other, check: false).status == 2)

        #expect(result.outcome == .failed(.conflictsBeforeLastHead))
        #expect(result.steps.map(\.head) == ["a", "x"])
        try expectGaveUp(dir, before: before, like: other)
    }

    @Test("refuses an index that differs from HEAD")
    func refusesLocalChanges() throws {
        let dir = try makeRepository()
        try write("changed\n", to: "m", in: dir)
        try git(["add", "m"], in: dir)
        let other = try twin(of: dir)
        let before = try state(of: dir)
        let result = try merge(["a", "b"], in: dir)
        #expect(try git(["merge", "-q", "a", "b"], in: other, check: false).status == 2)

        #expect(result.outcome == .failed(.localChanges(paths: ["m"])))
        #expect(result.steps.isEmpty)
        try expectGaveUp(dir, before: before, like: other)
    }

    @Test("refuses to overwrite a change in the working tree, keeping it")
    func refusesDirtyWorkingTree() throws {
        let dir = try makeRepository()
        try write("1\n2\n3\n4\n5\n6\n7\ndirty\n", to: "f", in: dir)
        let other = try twin(of: dir)
        let before = try state(of: dir)
        let result = try merge(["a", "b"], in: dir)
        #expect(try git(["merge", "-q", "a", "b"], in: other, check: false).status == 2)

        #expect(result.outcome == .failed(.notUpToDate(path: "f")))
        #expect(result.steps.map(\.kind) == [.merge])
        try expectGaveUp(dir, before: before, like: other)
    }

    @Test("refuses untracked files a head's file or directory would replace")
    func refusesDirectoryFileCollisions() throws {
        let dir = try makeRepository()
        try git(["checkout", "-q", "-b", "d", "base"], in: dir)
        try write("d\n", to: "d", in: dir)
        try git(["add", "d"], in: dir)
        try git(["commit", "-q", "-m", "d"], in: dir)
        try git(["checkout", "-q", "-b", "e", "base"], in: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("e"), withIntermediateDirectories: true)
        try write("e\n", to: "e/file", in: dir)
        try git(["add", "e"], in: dir)
        try git(["commit", "-q", "-m", "e"], in: dir)
        try git(["checkout", "-q", "main"], in: dir)

        // Untracked `d/file` where `d` goes: "would lose untracked files in it".
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("d"), withIntermediateDirectories: true)
        try write("x\n", to: "d/file", in: dir)
        var other = try twin(of: dir)
        var before = try state(of: dir)
        var result = try merge(["a", "d"], in: dir)
        #expect(try git(["merge", "-q", "a", "d"], in: other, check: false).status == 2)
        #expect(result.outcome == .failed(.untrackedFilesInDirectory(path: "d")))
        try expectGaveUp(dir, before: before, like: other)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("d"))

        // An untracked file `e` where `e/file` goes.
        try write("x\n", to: "e", in: dir)
        other = try twin(of: dir)
        before = try state(of: dir)
        result = try merge(["a", "e"], in: dir)
        #expect(try git(["merge", "-q", "a", "e"], in: other, check: false).status == 2)
        #expect(result.outcome == .failed(.untrackedWouldBeOverwritten(path: "e")))
        try expectGaveUp(dir, before: before, like: other)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("e"))

        // `d` against `d/file`: git's simple merge fails, and its
        // automatic one reports their side's path.
        let head = try git(["rev-parse", "HEAD"], in: dir).stdout
        try git(["checkout", "-q", "-b", "dd", "base"], in: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("d"), withIntermediateDirectories: true)
        try write("dd\n", to: "d/file", in: dir)
        try write("dd2\n", to: "d/other", in: dir)
        try git(["add", "d"], in: dir)
        try git(["commit", "-q", "-m", "dd"], in: dir)
        try git(["checkout", "-q", "main"], in: dir)
        // The file stays merged, `d/file` unmerged on the side that has it.
        for (heads, theirPath) in [(["a", "d", "dd"], "d/file"), (["a", "dd", "d"], "d")] {
            try git(["reset", "-q", "--hard", head], in: dir)
            try git(["clean", "-qfd"], in: dir)
            other = try twin(of: dir)
            result = try merge(heads, in: dir)
            #expect(try git(["merge", "-q", "-m", "Merge branches"] + heads, in: other, check: false).status == 1)
            // Their file: one `Adding d`, each path below it refused; their
            // paths below our file: one each.
            let expected: [OctopusPathMerge] = theirPath == "d"
                ? [.addedOverDirectory(path: "d", files: ["d/file", "d/other"])]
                : [.addedOverDirectory(path: "d/file", files: ["d/file"]),
                   .addedOverDirectory(path: "d/other", files: ["d/other"])]
            #expect(result.steps.last?.automatic == expected)
            #expect(result.outcome == .conflicts(paths: ["d/file", "d/other"]))
            #expect(try state(of: dir) == state(of: other))
            #expect(try String(contentsOf: dir.appendingPathComponent("d"), encoding: .utf8) == "d\n")
        }
    }

    @Test("leaves symbolic links and submodules both sides changed unmerged, ours in place")
    func symlinksAndSubmodules() throws {
        let dir = try makeRepository()
        let a = try git(["rev-parse", "a"], in: dir).stdout, b = try git(["rev-parse", "b"], in: dir).stdout
        for (branch, link, gitlink) in [("l1", "x", a), ("l2", "y", b)] {
            try git(["checkout", "-q", "-b", branch, "base"], in: dir)
            try FileManager.default.createSymbolicLink(
                atPath: dir.appendingPathComponent("lnk").path, withDestinationPath: link)
            try git(["add", "lnk"], in: dir)
            try git(["update-index", "--add", "--cacheinfo", "160000,\(gitlink),sub"], in: dir)
            try git(["commit", "-q", "-m", branch], in: dir)
            try FileManager.default.removeItem(at: dir.appendingPathComponent("lnk"))
        }
        try git(["checkout", "-q", "-f", "main"], in: dir)
        try git(["clean", "-qfdf"], in: dir)
        let other = try twin(of: dir)
        let result = try merge(["c", "l1", "l2"], in: dir)
        #expect(try git(["merge", "-q", "-m", "Merge branches", "c", "l1", "l2"], in: other, check: false).status == 1)
        #expect(result.steps.last?.automatic == [.symlink(path: "lnk"), .submodule(path: "sub")])
        #expect(result.outcome == .conflicts(paths: ["lnk", "sub"]))
        #expect(try state(of: dir) == state(of: other))
        let link = dir.appendingPathComponent("lnk").path
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == "x")
    }

    @Test("refuses to start while a merge or cherry-pick waits, as git does")
    func refusesWhileAnotherOperationWaits() throws {
        let dir = try makeRepository()
        try git(["merge", "-q", "--no-commit", "--no-ff", "c"], in: dir)
        #expect(throws: Libgit2Error.self) { try merge(["a", "b"], in: dir) }
        try git(["merge", "--abort"], in: dir)
        try git(["rev-parse", "c"], in: dir)
        try Data((try git(["rev-parse", "c"], in: dir).stdout + "\n").utf8)
            .write(to: dir.appendingPathComponent(".git/CHERRY_PICK_HEAD"))
        do {
            _ = try merge(["a", "b"], in: dir)
            Issue.record("expected a refusal")
        } catch let error as Libgit2Error {
            #expect(error.message == "You have not concluded your cherry-pick (CHERRY_PICK_HEAD exists).")
        }
    }

    /// `main` and `side` each merged the other's first commit, `side`
    /// keeping `f` as `base` has it, so they have two best common
    /// ancestors, and each has `f` as one of them has it.
    func makeEachSideAsABase() throws -> URL {
        let dir = try makeRepository()
        try git(["checkout", "-q", "-b", "side", "base"], in: dir)
        try write("s\n", to: "s", in: dir)
        try git(["add", "s"], in: dir)
        try git(["commit", "-q", "-m", "s"], in: dir, date: "2020-01-02T00:00:00Z")
        try git(["checkout", "-q", "main"], in: dir)
        try write("changed\n", to: "f", in: dir)
        try git(["commit", "-q", "-am", "changed"], in: dir, date: "2020-01-03T00:00:00Z")
        try git(["merge", "-q", "--no-edit", "side"], in: dir)
        try git(["checkout", "-q", "side"], in: dir)
        try git(["merge", "-q", "--no-commit", "main~1"], in: dir)
        try git(["checkout", "base", "--", "f"], in: dir)
        try git(["commit", "-q", "--no-edit"], in: dir)
        try git(["checkout", "-q", "main"], in: dir)
        return dir
    }

    @Test("a path each side has as a different base has it is unmerged, as git leaves it")
    func eachSideAsADifferentBase() throws {
        let dir = try makeEachSideAsABase()
        // The last head: an add/add conflict, our content kept.
        var other = try twin(of: dir)
        var result = try merge(["c", "side"], in: dir)
        #expect(try git(["merge", "-q", "-m", "Merge branches", "c", "side"], in: other, check: false).status == 1)
        #expect(result.steps.last?.automatic == [.addedInBoth(path: "f", emptyBlobMissing: true)])
        #expect(result.outcome == .conflicts(paths: ["f"]))
        #expect(try state(of: dir) == state(of: other))
        #expect(try String(contentsOf: dir.appendingPathComponent("f"), encoding: .utf8)
                == String(contentsOf: other.appendingPathComponent("f"), encoding: .utf8))
        try git(["reset", "-q", "--hard", "main"], in: dir)

        // An earlier head: the octopus gives up.
        other = try twin(of: dir)
        var before = try state(of: dir)
        result = try merge(["side", "c"], in: dir)
        #expect(try git(["merge", "-q", "side", "c"], in: other, check: false).status == 2)
        #expect(result.outcome == .failed(.conflictsBeforeLastHead))
        try expectGaveUp(dir, before: before, like: other)

        // A change to `f` in the working tree stops it first.
        try write("dirty\n", to: "f", in: dir)
        other = try twin(of: dir)
        before = try state(of: dir)
        result = try merge(["side", "c"], in: dir)
        #expect(try git(["merge", "-q", "side", "c"], in: other, check: false).status == 2)
        #expect(result.outcome == .failed(.notUpToDate(path: "f")))
        #expect(result.steps.last?.automatic == nil)
        try expectGaveUp(dir, before: before, like: other)
    }

    @Test("takes a criss-cross history's every best common ancestor, as git does", arguments: [false, true])
    func crissCrossBases(sideFirst: Bool) throws {
        let dir = try makeRepository()
        // `changed` and `side` each merged the other's first commit, so
        // they have two best common ancestors: one with `f` changed, one
        // not. libgit2 lists the newer first, so each order is tried.
        let (sideDate, changedDate) = sideFirst
            ? ("2020-01-02T00:00:00Z", "2020-01-03T00:00:00Z") : ("2020-01-03T00:00:00Z", "2020-01-02T00:00:00Z")
        try git(["checkout", "-q", "-b", "side", "base"], in: dir)
        try write("s\n", to: "s", in: dir)
        try git(["add", "s"], in: dir)
        try git(["commit", "-q", "-m", "s"], in: dir, date: sideDate)
        try git(["checkout", "-q", "-b", "changed", "base"], in: dir)
        try write("changed\n", to: "f", in: dir)
        try git(["commit", "-q", "-am", "changed"], in: dir, date: changedDate)
        try git(["checkout", "-q", "changed"], in: dir)
        try git(["merge", "-q", "--no-edit", "side"], in: dir)
        try git(["checkout", "-q", "side"], in: dir)
        try git(["merge", "-q", "--no-edit", "changed~1"], in: dir)
        try git(["checkout", "-q", "changed"], in: dir)
        try write("again\n", to: "f", in: dir)
        try git(["commit", "-q", "-am", "again"], in: dir)
        #expect(try git(["merge-base", "--all", "changed", "side"], in: dir).stdout.split(separator: "\n").count == 2)

        // `side` has `f` as one of the bases has it: the simple merge
        // takes `changed`'s.
        let other = try twin(of: dir)
        let result = try merge(["side", "c"], in: dir)
        try git(["merge", "-q", "-m", "Merge branches", "side", "c"], in: other)
        #expect(result.steps.map(\.automatic) == [nil, nil])
        #expect(try state(of: dir) == state(of: other))
        #expect(try String(contentsOf: dir.appendingPathComponent("f"), encoding: .utf8) == "again\n")
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

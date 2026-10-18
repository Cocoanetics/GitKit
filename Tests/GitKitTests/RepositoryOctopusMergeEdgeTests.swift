// `Repository.octopusMerge` against the system `git` where files and
// directories meet, modes differ, links point nowhere, the work tree
// lacks a file, or the repository is bare or mid-operation. Forks `git`,
// so non-Windows only, as `RepositoryOctopusMergeTests`.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

// Directory/file cases over a file the base has, permissions, and bare
// repositories.
extension RepositoryOctopusMergeTests {

    /// Branches off `base` for directory/file cases over a file the base
    /// has: `modd` changes `f`, `df` replaces it with `f/x`; `m1` and
    /// `m2` add the same `s`, `m2` executable.
    func makeFileOverDirectory() throws -> URL {
        let dir = try makeRepository()
        try git(["checkout", "-q", "-b", "modd", "base"], in: dir)
        try write("changed\n", to: "f", in: dir)
        try git(["commit", "-q", "-am", "modd"], in: dir)
        try git(["checkout", "-q", "-b", "df", "base"], in: dir)
        try git(["rm", "-q", "f"], in: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("f"), withIntermediateDirectories: true)
        try write("x\n", to: "f/x", in: dir)
        try git(["add", "f"], in: dir)
        try git(["commit", "-q", "-m", "df"], in: dir)
        for (branch, executable) in [("m1", false), ("m2", true)] {
            try git(["checkout", "-q", "-b", branch, "base"], in: dir)
            try write("same\n", to: "s", in: dir)
            if executable {
                try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                      ofItemAtPath: dir.appendingPathComponent("s").path)
            }
            try git(["add", "s"], in: dir)
            try git(["commit", "-q", "-m", branch], in: dir)
        }
        try git(["checkout", "-q", "-f", "main"], in: dir)
        try git(["clean", "-qfd"], in: dir)
        return dir
    }

    @Test("a file replaced by a directory, as git-merge-one-file takes it", arguments: [
        (["c", "modd", "df"], [OctopusPathMerge.notHandled(
            path: "f", base: "", ours: "", theirs: ""), .addedOverDirectory(path: "f/x", files: [])]),
        (["df", "c"], [OctopusPathMerge.removed(path: "f")])
    ])
    func fileReplacedByDirectory(heads: [String], last: [OctopusPathMerge]) throws {
        let dir = try makeFileOverDirectory()
        let other = try twin(of: dir)
        let result = try merge(heads, in: dir)
        _ = try git(["merge", "-q", "-m", "Merge branches"] + heads, in: other, check: false)
        // Object names aside, the paths and what became of them.
        let automatic = result.steps.last?.automatic?.map { path -> OctopusPathMerge in
            guard case .notHandled(let path, _, _, _) = path else { return path }
            return .notHandled(path: path, base: "", ours: "", theirs: "")
        }
        #expect(automatic == last)
        #expect(try state(of: dir) == state(of: other))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("f~HEAD").path))
    }

    @Test("the same content added with different modes is a permissions conflict")
    func addedWithDifferentModes() throws {
        let dir = try makeFileOverDirectory()
        let other = try twin(of: dir)
        let result = try merge(["c", "m1", "m2"], in: dir)
        #expect(try git(["merge", "-q", "-m", "Merge branches", "c", "m1", "m2"], in: other, check: false).status == 1)
        #expect(result.steps.last?.automatic == [.addedWithDifferentModes(path: "s", ours: "100644", theirs: "100755")])
        #expect(try state(of: dir) == state(of: other))
    }

    @Test("a file deleted from the work tree is up to date: the merge deletes or writes it",
          arguments: [["c", "df"], ["c", "modd"], ["c", "modd", "df"], ["c", "df", "modd"]])
    func fileDeletedFromWorkTree(heads: [String]) throws {
        let dir = try makeFileOverDirectory()
        try FileManager.default.removeItem(at: dir.appendingPathComponent("f"))
        let other = try twin(of: dir)
        let result = try merge(heads, in: dir)
        _ = try git(["merge", "-q", "-m", "Merge branches"] + heads, in: other, check: false)
        if case .failed = result.outcome { Issue.record("expected the merge to go on, got \(result.outcome)") }
        #expect(try state(of: dir) == state(of: other))
    }

    @Test("merges through a revert or a bisect, as git does", arguments: ["REVERT_HEAD", "BISECT_LOG"])
    func mergesThroughOtherOperations(file: String) throws {
        let dir = try makeRepository()
        try Data((try git(["rev-parse", "c"], in: dir).stdout + "\n").utf8)
            .write(to: dir.appendingPathComponent(".git/" + file))
        let other = try twin(of: dir)
        let result = try merge(["a", "b"], in: dir)
        try git(["merge", "-q", "-m", "Merge branches", "a", "b"], in: other)
        guard case .mergeCommit = result.outcome else {
            Issue.record("expected a merge commit, got \(result.outcome)"); return
        }
        #expect(try state(of: dir) == state(of: other))
    }

    @Test("removes a symbolic link the merge deletes, even one pointing nowhere")
    func removesDanglingSymlink() throws {
        let dir = try makeRepository()
        try git(["checkout", "-q", "-b", "link", "base"], in: dir)
        try FileManager.default.createSymbolicLink(
            atPath: dir.appendingPathComponent("dl").path, withDestinationPath: "nowhere")
        try git(["add", "dl"], in: dir)
        try git(["commit", "-q", "-m", "link"], in: dir)
        try git(["checkout", "-q", "-b", "unlink"], in: dir)
        try git(["rm", "-q", "dl"], in: dir)
        try git(["commit", "-q", "-m", "unlink"], in: dir)
        try git(["checkout", "-q", "link"], in: dir)
        let other = try twin(of: dir)
        _ = try merge(["unlink", "c"], in: dir)
        try git(["merge", "-q", "-m", "Merge branches", "unlink", "c"], in: other)
        #expect(try state(of: dir) == state(of: other))
        let link = dir.appendingPathComponent("dl").path
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == nil)
    }

    @Test("a mode only one side changed fails the content merge, as git-merge-one-file does",
          arguments: [(false, false), (true, false), (false, true)])
    func permissionsConflict(executableOurs: Bool, conflictingContent: Bool) throws {
        let dir = try makeRepository()
        func branch(_ name: String, _ text: String, executable: Bool) throws {
            try git(["checkout", "-q", "-b", name, "base"], in: dir)
            try write(text, to: "f", in: dir)
            try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644],
                                                  ofItemAtPath: dir.appendingPathComponent("f").path)
            try git(["commit", "-q", "-am", name], in: dir)
        }
        try branch("p1", "1p\n2\n3\n4\n5\n6\n7\n", executable: executableOurs)
        try branch("p2", conflictingContent ? "1q\n2\n3\n4\n5\n6\n7\n" : "1\n2\n3\n4\n5\n6\n7p\n",
                   executable: !executableOurs)
        try git(["checkout", "-q", "main"], in: dir)
        let heads = executableOurs ? ["c", "p2", "p1"] : ["c", "p1", "p2"]
        let other = try twin(of: dir)
        let result = try merge(heads, in: dir)
        #expect(try git(["merge", "-q", "-m", "Merge branches"] + heads, in: other, check: false).status == 1)
        guard case .permissionsConflict(let path, _, _, _, let content)? = result.steps.last?.automatic?.first else {
            Issue.record("expected a permissions conflict, got \(String(describing: result.steps.last))"); return
        }
        #expect(path == "f" && content == conflictingContent)
        #expect(try state(of: dir) == state(of: other))
        if !conflictingContent {
            #expect(try String(contentsOf: dir.appendingPathComponent("f"), encoding: .utf8)
                    == String(contentsOf: other.appendingPathComponent("f"), encoding: .utf8))
        }
        let mode = { (url: URL) in
            try FileManager.default.attributesOfItem(atPath: url.appendingPathComponent("f").path)[.posixPermissions]
                as? Int
        }
        #expect(try mode(dir) == mode(other))
    }

    @Test("with the empty blob in the repository, an add/add path gets conflict markers")
    func addedInBothWithEmptyBlob() throws {
        let dir = try makeRepository()
        try write("", to: "empty", in: dir)
        try git(["add", "empty"], in: dir)
        try git(["commit", "-q", "-m", "empty"], in: dir)
        for (branch, text) in [("n1", "one\n"), ("n2", "two\n")] {
            try git(["checkout", "-q", "-b", branch, "base"], in: dir)
            try write(text, to: "n", in: dir)
            try git(["add", "n"], in: dir)
            try git(["commit", "-q", "-m", branch], in: dir)
        }
        try git(["checkout", "-q", "main"], in: dir)
        let other = try twin(of: dir)
        let result = try merge(["c", "n1", "n2"], in: dir)
        #expect(try git(["merge", "-q", "-m", "Merge branches", "c", "n1", "n2"], in: other, check: false).status == 1)
        #expect(result.steps.last?.automatic == [.addedInBoth(path: "n", emptyBlobMissing: false)])
        #expect(try state(of: dir) == state(of: other))
        let text = try String(contentsOf: dir.appendingPathComponent("n"), encoding: .utf8)
        #expect(text.contains("<<<<<<<") && text.contains("one") && text.contains("two"))
    }

    @Test("deleted on one side, its mode changed on the other",
          arguments: [["c", "rm", "chmod"], ["c", "chmod", "rm"]])
    func deletedWithModeChange(heads: [String]) throws {
        let dir = try makeRepository()
        try git(["checkout", "-q", "-b", "rm", "base"], in: dir)
        try git(["rm", "-q", "f"], in: dir)
        try git(["commit", "-q", "-m", "rm"], in: dir)
        try git(["checkout", "-q", "-b", "chmod", "base"], in: dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: dir.appendingPathComponent("f").path)
        try git(["commit", "-q", "-am", "chmod"], in: dir)
        try git(["checkout", "-q", "main"], in: dir)
        let other = try twin(of: dir)
        let result = try merge(heads, in: dir)
        #expect(try git(["merge", "-q", "-m", "Merge branches"] + heads, in: other, check: false).status == 1)
        #expect(result.steps.last?.automatic == [.deletedWithModeChange(path: "f")])
        #expect(try state(of: dir) == state(of: other))
        let path = { (url: URL) in url.appendingPathComponent("f").path }
        let exists = FileManager.default.fileExists(atPath: path(dir))
        #expect(exists == FileManager.default.fileExists(atPath: path(other)))
    }

    @Test("moves a gitlink past a submodule's own local changes, as git does")
    func dirtySubmodule() throws {
        let sub = FileManager.default.temporaryDirectory.appendingPathComponent("OctopusSub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: sub)
        try write("1\n", to: "s", in: sub)
        try git(["add", "s"], in: sub)
        try git(["commit", "-q", "-m", "s1"], in: sub)
        try write("2\n", to: "s", in: sub)
        try git(["commit", "-q", "-am", "s2"], in: sub)

        let dir = try makeRepository()
        try git(["checkout", "-q", "base"], in: dir)
        try git(["-c", "protocol.file.allow=always", "submodule", "-q", "add", sub.path, "sub"], in: dir)
        try git(["-C", "sub", "checkout", "-q", "HEAD~1"], in: dir)
        try git(["add", "sub"], in: dir)
        try git(["commit", "-q", "-m", "sub"], in: dir)
        try git(["branch", "-f", "withsub"], in: dir)
        try git(["checkout", "-q", "-b", "up"], in: dir)
        try git(["-C", "sub", "checkout", "-q", "main"], in: dir)
        try git(["add", "sub"], in: dir)
        try git(["commit", "-q", "-m", "up"], in: dir)
        try git(["-C", "sub", "checkout", "-q", "HEAD~1"], in: dir)
        try git(["checkout", "-q", "-b", "side", "withsub"], in: dir)
        try write("side\n", to: "side", in: dir)
        try git(["add", "side"], in: dir)
        try git(["commit", "-q", "-m", "side"], in: dir)
        try git(["checkout", "-q", "withsub"], in: dir)
        try write("dirty\n", to: "sub/s", in: dir)

        let other = try twin(of: dir)
        let result = try merge(["side", "up"], in: dir)
        try git(["merge", "-q", "-m", "Merge branches", "side", "up"], in: other)
        guard case .mergeCommit = result.outcome else {
            Issue.record("expected a merge commit, got \(result.outcome)"); return
        }
        #expect(try state(of: dir) == state(of: other))
        #expect(try String(contentsOf: dir.appendingPathComponent("sub/s"), encoding: .utf8) == "dirty\n")
    }

    @Test("on a work tree that folds case, an untracked file of another case still collides")
    func untrackedOfAnotherCase() throws {
        let dir = try makeRepository()
        // Only where git found the file system folding case.
        guard try git(["config", "core.ignorecase"], in: dir, check: false).stdout == "true" else { return }
        try git(["checkout", "-q", "-b", "c2", "base"], in: dir)
        try write("c2\n", to: "c2", in: dir)
        try git(["add", "c2"], in: dir)
        try git(["commit", "-q", "-m", "c2"], in: dir)
        try git(["checkout", "-q", "main"], in: dir)
        try write("junk\n", to: "C", in: dir)
        let other = try twin(of: dir)
        let before = try state(of: dir)
        let result = try merge(["c2", "c"], in: dir)
        #expect(try git(["merge", "-q", "c2", "c"], in: other, check: false).status == 2)
        #expect(result.outcome == .failed(.untrackedWouldBeOverwritten(path: "c")))
        try expectGaveUp(dir, before: before, like: other)
    }

    @Test("a criss-cross base that has a path is its ancestor, though the other base lacks it")
    func baseWithThePath() throws {
        let dir = try makeRepository()
        try git(["checkout", "-q", "-b", "py", "base"], in: dir)
        try write("y\n", to: "y", in: dir)
        try git(["add", "y"], in: dir)
        try git(["commit", "-q", "-m", "py"], in: dir, date: "2020-01-02T00:00:00Z")
        try git(["checkout", "-q", "-b", "px", "base"], in: dir)
        try write("1\n2\n3\n4\n5\n6\n7\n", to: "p", in: dir)
        try git(["add", "p"], in: dir)
        try git(["commit", "-q", "-m", "px"], in: dir, date: "2020-01-03T00:00:00Z")
        // `ours` and `side` each merged px and py, then changed `p` apart.
        try git(["checkout", "-q", "-b", "ours", "px"], in: dir)
        try git(["merge", "-q", "--no-edit", "py"], in: dir)
        try write("1m\n2\n3\n4\n5\n6\n7\n", to: "p", in: dir)
        try git(["commit", "-q", "-am", "ours"], in: dir)
        try git(["checkout", "-q", "-b", "side", "py"], in: dir)
        try git(["merge", "-q", "--no-edit", "px"], in: dir)
        try write("1\n2\n3\n4\n5\n6\n7s\n", to: "p", in: dir)
        try git(["commit", "-q", "-am", "side"], in: dir)
        try git(["checkout", "-q", "ours"], in: dir)
        #expect(try git(["merge-base", "--all", "ours", "side"], in: dir).stdout.split(separator: "\n").count == 2)

        let other = try twin(of: dir)
        let result = try merge(["c", "side"], in: dir)
        try git(["merge", "-q", "-m", "Merge branches", "c", "side"], in: other)
        #expect(result.steps.last?.automatic == [.merged(path: "p")])
        #expect(try state(of: dir) == state(of: other))
        #expect(try String(contentsOf: dir.appendingPathComponent("p"), encoding: .utf8) == "1m\n2\n3\n4\n5\n6\n7s\n")
    }

    @Test("a change in the work tree stops a merge whose result for that file is ours")
    func dirtyFileMergedBackToOurs() throws {
        let dir = try makeRepository()
        // Ours changed f's first and last line, `b` only its last, alike.
        try write("1a\n2\n3\n4\n5\n6\n7b\n", to: "f", in: dir)
        try git(["commit", "-q", "-am", "ours"], in: dir)
        try write("dirty\n", to: "f", in: dir)
        let other = try twin(of: dir)
        let before = try state(of: dir)
        let result = try merge(["b", "c"], in: dir)
        #expect(try git(["merge", "-q", "b", "c"], in: other, check: false).status == 2)
        #expect(result.outcome == .failed(.notUpToDate(path: "f")))
        try expectGaveUp(dir, before: before, like: other)
    }

    @Test("a link or an executable over a directory stays what it is", arguments: [true, false])
    func fileOverDirectoryKeepsItsType(link: Bool) throws {
        let dir = try makeRepository()
        try git(["checkout", "-q", "-b", "kind", "base"], in: dir)
        let d = dir.appendingPathComponent("d").path
        if link {
            try FileManager.default.createSymbolicLink(atPath: d, withDestinationPath: "target")
        } else {
            try write("#!/bin/sh\n", to: "d", in: dir)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: d)
        }
        try git(["add", "d"], in: dir)
        try git(["commit", "-q", "-m", "kind"], in: dir)
        try git(["checkout", "-q", "-b", "dir", "base"], in: dir)
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        try write("f\n", to: "d/file", in: dir)
        try git(["add", "d"], in: dir)
        try git(["commit", "-q", "-m", "dir"], in: dir)
        try git(["checkout", "-q", "-f", "main"], in: dir)
        try git(["clean", "-qfd"], in: dir)

        let other = try twin(of: dir)
        _ = try merge(["c", "kind", "dir"], in: dir)
        _ = try git(["merge", "-q", "-m", "Merge branches", "c", "kind", "dir"], in: other, check: false)
        #expect(try state(of: dir) == state(of: other))
        let attributes = { (url: URL) in
            try FileManager.default.attributesOfItem(atPath: url.appendingPathComponent("d").path)
        }
        #expect(try attributes(dir)[.type] as? FileAttributeType == attributes(other)[.type] as? FileAttributeType)
        #expect(try attributes(dir)[.posixPermissions] as? Int == attributes(other)[.posixPermissions] as? Int)
    }

    @Test("a skip-worktree file with local changes stops the merge, as read-tree does")
    func skipWorktreeChanges() throws {
        let dir = try makeRepository()
        try git(["update-index", "--skip-worktree", "f"], in: dir)
        try write("local\n", to: "f", in: dir)
        let other = try twin(of: dir)
        let result = try merge(["a", "b"], in: dir)
        #expect(try git(["merge", "-q", "a", "b"], in: other, check: false).status == 2)
        #expect(result.outcome == .failed(.notUpToDate(path: "f")))
        #expect(try String(contentsOf: dir.appendingPathComponent("f"), encoding: .utf8) == "local\n")
    }

    @Test("a submodule replaced by a directory: its files block the paths the head adds")
    func submoduleReplacedByDirectory() throws {
        let sub = FileManager.default.temporaryDirectory.appendingPathComponent("OctopusSub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: sub)
        try write("1\n", to: "s", in: sub)
        try git(["add", "s"], in: sub)
        try git(["commit", "-q", "-m", "s1"], in: sub)

        let dir = try makeRepository()
        try git(["-c", "protocol.file.allow=always", "submodule", "-q", "add", sub.path, "sub"], in: dir)
        try git(["commit", "-q", "-m", "sub"], in: dir)
        try git(["checkout", "-q", "-b", "flat"], in: dir)
        try git(["rm", "-q", "--cached", "sub", ".gitmodules"], in: dir)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("sub"))
        try FileManager.default.removeItem(at: dir.appendingPathComponent(".gitmodules"))
        let flatSub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: flatSub, withIntermediateDirectories: true)
        try write("tracked\n", to: "sub/s", in: dir)
        try git(["add", "sub"], in: dir)
        try git(["commit", "-q", "-m", "flat"], in: dir)
        try git(["checkout", "-q", "-f", "main"], in: dir)
        try git(["-c", "protocol.file.allow=always", "submodule", "-q", "update", "--init"], in: dir)

        let other = try twin(of: dir)
        let result = try merge(["c", "flat"], in: dir)
        let status = try git(["merge", "-q", "-m", "Merge branches", "c", "flat"], in: other, check: false).status
        #expect(status == 1)
        #expect(result.steps.last?.automatic?.contains(.addedOverUntracked(path: "sub/s")) == true)
        #expect(result.steps.last?.automatic?.contains(.submoduleDirectoryKept(path: "sub")) == true)
        #expect(try state(of: dir) == state(of: other))
        #expect(try String(contentsOf: dir.appendingPathComponent("sub/s"), encoding: .utf8) == "1\n")
    }

    @Test("a file of HEAD's an earlier step deleted is no untracked file for a later step")
    func staleTrackedFile() throws {
        let dir = try makeRepository()
        // HEAD tracks d/f where the base had a file d; `gone` deletes d/f;
        // `back` puts d/f in place of the base's d again.
        try git(["checkout", "-q", "-b", "root", "base"], in: dir)
        try write("d\n", to: "d", in: dir)
        try git(["add", "d"], in: dir)
        try git(["commit", "-q", "-m", "root"], in: dir)
        try git(["checkout", "-q", "-b", "hd"], in: dir)
        try git(["rm", "-q", "d"], in: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("d"), withIntermediateDirectories: true)
        try write("f\n", to: "d/f", in: dir)
        try git(["add", "d"], in: dir)
        try git(["commit", "-q", "-m", "head"], in: dir)
        try git(["checkout", "-q", "-b", "gone"], in: dir)
        try git(["rm", "-q", "d/f"], in: dir)
        try git(["commit", "-q", "-m", "gone"], in: dir)
        try git(["checkout", "-q", "-b", "other", "root"], in: dir)
        try write("o\n", to: "o", in: dir)
        try git(["add", "o"], in: dir)
        try git(["commit", "-q", "-m", "other"], in: dir)
        try git(["checkout", "-q", "-b", "back", "root"], in: dir)
        try git(["rm", "-q", "d"], in: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("d"), withIntermediateDirectories: true)
        try write("back\n", to: "d/f", in: dir)
        try git(["add", "d"], in: dir)
        try git(["commit", "-q", "-m", "back"], in: dir)
        try git(["checkout", "-q", "hd"], in: dir)

        let other = try twin(of: dir)
        let result = try merge(["gone", "other", "back"], in: dir)
        _ = try git(["merge", "-q", "-m", "Merge branches", "gone", "other", "back"], in: other, check: false)
        #expect(!(result.steps.last?.automatic?.contains(.addedOverUntracked(path: "d/f")) ?? false))
        #expect(try state(of: dir) == state(of: other))
    }

    @Test("a skip-worktree symbolic link pointing elsewhere stops the merge", arguments: [false, true])
    func skipWorktreeSymlink(changed: Bool) throws {
        let dir = try makeRepository()
        try git(["checkout", "-q", "-b", "link", "base"], in: dir)
        try FileManager.default.createSymbolicLink(
            atPath: dir.appendingPathComponent("lnk").path, withDestinationPath: "x")
        try git(["add", "lnk"], in: dir)
        try git(["commit", "-q", "-m", "link"], in: dir)
        try git(["checkout", "-q", "-b", "relink"], in: dir)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("lnk"))
        try FileManager.default.createSymbolicLink(
            atPath: dir.appendingPathComponent("lnk").path, withDestinationPath: "z")
        try git(["commit", "-q", "-am", "relink"], in: dir)
        try git(["checkout", "-q", "link"], in: dir)
        try git(["update-index", "--skip-worktree", "lnk"], in: dir)
        if changed {
            try FileManager.default.removeItem(at: dir.appendingPathComponent("lnk"))
            try FileManager.default.createSymbolicLink(
                atPath: dir.appendingPathComponent("lnk").path, withDestinationPath: "y")
        } else {
            // As git does in place (a copy's new file times make git's
            // skip-worktree check refuse, so no twin here).
            let result = try merge(["relink", "c"], in: dir)
            guard case .mergeCommit = result.outcome else {
                Issue.record("expected a merge commit, got \(result.outcome)"); return
            }
            return
        }
        let other = try twin(of: dir)
        let result = try merge(["relink", "c"], in: dir)
        #expect(try git(["merge", "-q", "-m", "Merge branches", "relink", "c"], in: other, check: false).status == 2)
        #expect(result.outcome == .failed(.notUpToDate(path: "lnk")))
        #expect(try state(of: dir) == state(of: other))
    }

    @Test("an assume-unchanged or skip-worktree file edited, or made executable, stops the merge",
          arguments: [("--assume-unchanged", false), ("--assume-unchanged", true), ("--skip-worktree", true)])
    func hiddenLocalChanges(flag: String, chmod: Bool) throws {
        let dir = try makeRepository()
        try git(["update-index", flag, "f"], in: dir)
        let f = dir.appendingPathComponent("f").path
        if chmod {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f)
        } else {
            try write("local\n", to: "f", in: dir)
        }
        let result = try merge(["a", "b"], in: dir)
        #expect(result.outcome == .failed(.notUpToDate(path: "f")))
    }

    @Test("a skip-worktree gitlink moves, keeping its bit, as git does")
    func skipWorktreeGitlink() throws {
        let sub = FileManager.default.temporaryDirectory.appendingPathComponent("OctopusSub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: sub)
        try write("1\n", to: "s", in: sub)
        try git(["add", "s"], in: sub)
        try git(["commit", "-q", "-m", "s1"], in: sub)
        try write("2\n", to: "s", in: sub)
        try git(["commit", "-q", "-am", "s2"], in: sub)
        let dir = try makeRepository()
        try git(["-c", "protocol.file.allow=always", "submodule", "-q", "add", sub.path, "sub"], in: dir)
        try git(["-C", "sub", "checkout", "-q", "HEAD~1"], in: dir)
        try git(["add", "sub"], in: dir)
        try git(["commit", "-q", "-m", "sub"], in: dir)
        try git(["checkout", "-q", "-b", "up"], in: dir)
        try git(["-C", "sub", "checkout", "-q", "main"], in: dir)
        try git(["add", "sub"], in: dir)
        try git(["commit", "-q", "-m", "up"], in: dir)
        try git(["checkout", "-q", "main"], in: dir)
        try git(["-C", "sub", "checkout", "-q", "HEAD~1"], in: dir)
        try git(["update-index", "--skip-worktree", "sub"], in: dir)

        let other = try twin(of: dir)
        let result = try merge(["c", "up"], in: dir)
        try git(["merge", "-q", "-m", "Merge branches", "c", "up"], in: other)
        guard case .mergeCommit = result.outcome else {
            Issue.record("expected a merge commit, got \(result.outcome)"); return
        }
        #expect(try state(of: dir) == state(of: other))
        #expect(try git(["ls-files", "-v", "sub"], in: dir).stdout == git(["ls-files", "-v", "sub"], in: other).stdout)
    }

    @Test("refuses a bare repository before anything changes")
    func refusesBare() throws {
        let dir = try makeRepository()
        let bare = FileManager.default.temporaryDirectory.appendingPathComponent("OctopusBare-\(UUID().uuidString)")
        try git(["clone", "-q", "--bare", dir.path, bare.path], in: dir)
        let repository = try Repository.open(at: bare)
        #expect(throws: Libgit2Error.self) {
            try repository.octopusMerge(heads: ["a", "b"], message: "Merge", env: Self.identity)
        }
        #expect(!FileManager.default.fileExists(atPath: bare.appendingPathComponent("ORIG_HEAD").path))
    }
}
#endif

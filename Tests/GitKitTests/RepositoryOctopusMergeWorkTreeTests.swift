// `Repository.octopusMerge` against the system `git` for what it writes
// itself: files through checkout filters and with their modes, symbolic
// links byte for byte, and the merge's diffstat summary. Forks `git`, so
// non-Windows only, as `RepositoryOctopusMergeTests`.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

extension RepositoryOctopusMergeTests {

    @Test("a file GitKit restores itself goes through the checkout filters, its mode as created")
    func restoredFileThroughFilters() throws {
        let dir = try makeRepository()
        try write("f text eol=crlf\n", to: ".gitattributes", in: dir)
        try git(["add", ".gitattributes"], in: dir)
        try git(["commit", "-q", "-m", "attributes"], in: dir)
        try git(["tag", "-f", "withattributes"], in: dir)
        try git(["checkout", "-q", "-b", "rm", "withattributes"], in: dir)
        try git(["rm", "-q", "f"], in: dir)
        try git(["commit", "-q", "-m", "rm"], in: dir)
        try git(["checkout", "-q", "-b", "chmod", "withattributes"], in: dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: dir.appendingPathComponent("f").path)
        try git(["commit", "-q", "-am", "chmod"], in: dir)
        try git(["checkout", "-q", "main"], in: dir)
        try git(["merge", "-q", "--no-edit", "withattributes"], in: dir)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("f"))
        try git(["checkout", "-q", "--", "f"], in: dir)

        let other = try twin(of: dir)
        _ = try merge(["chmod", "rm"], in: dir)
        _ = try git(["merge", "-q", "-m", "Merge branches", "chmod", "rm"], in: other, check: false)
        #expect(try state(of: dir) == state(of: other))
        let bytes = { (url: URL) in try Data(contentsOf: url.appendingPathComponent("f")) }
        #expect(try bytes(dir) == bytes(other))
        // New files' modes as the kernel gives them under the umask.
        let modes = Repository.creationModes(in: dir.path)
        #expect(modes.executable & 0o111 != 0 && modes.plain & 0o111 == 0)
        #expect(modes.executable & 0o666 == modes.plain)
    }

    @Test("the merge's diffstat finds renames and mode changes, as git's does")
    func renamesInSummary() throws {
        let dir = try makeRepository()
        try git(["checkout", "-q", "-b", "mv", "base"], in: dir)
        try git(["mv", "f", "g"], in: dir)
        try git(["commit", "-q", "-m", "mv"], in: dir)
        try git(["checkout", "-q", "-b", "chm", "base"], in: dir)
        try write("z\n", to: "zz", in: dir)
        try git(["add", "zz"], in: dir)
        try git(["commit", "-q", "-m", "zz"], in: dir)
        try git(["checkout", "-q", "main"], in: dir)
        try git(["merge", "-q", "--no-edit", "chm"], in: dir)
        try git(["checkout", "-q", "-b", "chm2", "chm"], in: dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: dir.appendingPathComponent("zz").path)
        try git(["commit", "-q", "-am", "chmod"], in: dir)
        try git(["checkout", "-q", "main"], in: dir)

        let other = try twin(of: dir)
        let result = try merge(["mv", "chm2", "c"], in: dir)
        let output = try git(["merge", "-m", "Merge branches", "mv", "chm2", "c"], in: other).stdout
        guard case .mergeCommit(_, let summary, _, _, let lines) = result.outcome else {
            Issue.record("expected a merge commit, got \(result.outcome)"); return
        }
        let gitLines = output.split(separator: "\n").map(String.init)
        let gitSummary = gitLines.filter { $0.hasPrefix(" create") || $0.hasPrefix(" delete")
            || $0.hasPrefix(" rename") || $0.hasPrefix(" mode change") }
        #expect(lines == gitSummary)
        #expect(summary.contains("f => g"))
        #expect(output.contains(summary))
    }

    @Test("paths git quotes are quoted in the merge's summary, as git's are")
    func quotedPathsInSummary() throws {
        let dir = try makeRepository()
        try git(["checkout", "-q", "-b", "odd", "base"], in: dir)
        for name in ["we\nird", "tab\t\"q\"", "\u{fc}mlaut", "back\\slash"] {
            try write("\(name)\n", to: name, in: dir)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: dir.appendingPathComponent("\u{fc}mlaut").path)
        try git(["add", "-A"], in: dir)
        try git(["commit", "-q", "-m", "odd"], in: dir)
        try git(["checkout", "-q", "-b", "mvodd", "base"], in: dir)
        try git(["mv", "f", "f\tg"], in: dir)
        try git(["commit", "-q", "-m", "mv"], in: dir)
        try git(["checkout", "-q", "main"], in: dir)
        let other = try twin(of: dir)
        let result = try merge(["odd", "mvodd", "c"], in: dir)
        let output = try git(["merge", "-m", "Merge branches", "odd", "mvodd", "c"], in: other).stdout
        guard case .mergeCommit(_, _, let added, let deleted, let lines) = result.outcome else {
            Issue.record("expected a merge commit, got \(result.outcome)"); return
        }
        let gitLines = output.split(separator: "\n").map(String.init)
        let gitSummary = gitLines.filter { $0.hasPrefix(" create") || $0.hasPrefix(" delete")
            || $0.hasPrefix(" rename") || $0.hasPrefix(" mode change") }
        #expect(lines == gitSummary)
        #expect(lines.contains(" rename f => \"f\\tg\" (100%)"))
        #expect(added.contains(" create mode 100755 \"\\303\\274mlaut\""))
        #expect(added.contains(" create mode 100644 \"we\\nird\""))
        #expect(added.allSatisfy { !$0.contains("\n") } && deleted.isEmpty)
        if case .mergeCommit(_, let summary, _, _, _) = result.outcome { #expect(output.contains(summary + "\n")) }
        #expect(Repository.quotedPath(Array("\u{fc}\u{1}".utf8), quotePath: false) == "\"\u{fc}\\001\"")
    }

    @Test("the diffstat scales its graph, names binary files and shortens long names, as git's does")
    func diffstatWidths() throws {
        let dir = try makeRepository()
        try git(["checkout", "-q", "-b", "big", "base"], in: dir)
        try write((1...150).map { "line \($0)" }.joined(separator: "\n") + "\n", to: "f", in: dir)
        let deep = "a-rather-long-directory-name/with-another-long-subdirectory/and-yet-one-more-level"
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(deep), withIntermediateDirectories: true)
        try write("x\ny\n", to: deep + "/file-with-a-long-name.txt", in: dir)
        try Data([0, 1, 2, 0, 255]).write(to: dir.appendingPathComponent("blob.bin"))
        try git(["add", "-A"], in: dir)
        try git(["commit", "-q", "-m", "big"], in: dir)
        try git(["checkout", "-q", "main"], in: dir)
        let other = try twin(of: dir)
        let result = try merge(["big", "c"], in: dir)
        let output = try git(["merge", "-m", "Merge branches", "big", "c"], in: other).stdout
        guard case .mergeCommit(_, let summary, _, _, _) = result.outcome else {
            Issue.record("expected a merge commit, got \(result.outcome)"); return
        }
        #expect(output.contains(summary + "\n"))
        #expect(summary.contains("Bin 0 -> 5 bytes") && summary.contains(".../"))
    }

    @Test("with core.quotePath off, wide and combining characters take git's columns in the diffstat")
    func diffstatDisplayWidths() throws {
        let dir = try makeRepository()
        try git(["config", "core.quotePath", "false"], in: dir)
        try git(["checkout", "-q", "-b", "wide", "base"], in: dir)
        for name in ["aa", "\u{754C}", "x\u{301}", "\u{1F389}"] { try write("1\n", to: name, in: dir) }
        try git(["add", "-A"], in: dir)
        try git(["commit", "-q", "-m", "wide"], in: dir)
        try git(["checkout", "-q", "main"], in: dir)
        let other = try twin(of: dir)
        let result = try merge(["wide", "c"], in: dir)
        let output = try git(["merge", "-m", "Merge branches", "wide", "c"], in: other).stdout
        guard case .mergeCommit(_, let summary, _, _, let lines) = result.outcome else {
            Issue.record("expected a merge commit, got \(result.outcome)"); return
        }
        // Older gits' width tables count emoji as one column.
        if try gitIsAtLeast(2, 54) { #expect(output.contains(summary + "\n")) }
        #expect(summary.contains(" \u{754C} | 1 +") && summary.contains(" x\u{301}  | 1 +"))
        #expect(lines == output.split(separator: "\n").map(String.init).filter { $0.hasPrefix(" create") })
        #expect(Repository.displayWidth("\u{754C}x\u{301}\u{AD}".unicodeScalars) == 4)
    }

    @Test("renames read as git's diff summary writes them")
    func renameText() {
        #expect(Repository.renameText("a/b/c", "a/z/c") == "a/{b => z}/c")
        #expect(Repository.renameText("top", "deep/top") == "top => deep/top")
        #expect(Repository.renameText("dir/a", "dir/b") == "dir/{a => b}")
        #expect(Repository.renameText("x/f", "y/f") == "{x => y}/f")
        #expect(Repository.renameText("old", "new") == "old => new")
    }

    @Test("our symbolic link kept in a conflict keeps its target's bytes, UTF-8 or not")
    func nonUTF8SymlinkTarget() throws {
        let dir = try makeRepository()
        for (branch, target) in [("l1", [UInt8]("tg".utf8) + [0xff]), ("l2", [UInt8]("other".utf8))] {
            try git(["checkout", "-q", "-b", branch, "base"], in: dir)
            let blob = dir.appendingPathComponent("blob")
            try Data(target).write(to: blob)
            let oid = try git(["hash-object", "-w", "blob"], in: dir).stdout
            try FileManager.default.removeItem(at: blob)
            try git(["update-index", "--add", "--cacheinfo", "120000,\(oid),lnk"], in: dir)
            try git(["commit", "-q", "-m", branch], in: dir)
        }
        try git(["checkout", "-q", "-f", "l1"], in: dir)
        let other = try twin(of: dir)
        _ = try merge(["c", "l2"], in: dir)
        _ = try git(["merge", "-q", "-m", "Merge branches", "c", "l2"], in: other, check: false)
        func linkBytes(_ url: URL) -> [UInt8] {
            var buffer = [CChar](repeating: 0, count: 256)
            let count = readlink(url.appendingPathComponent("lnk").path, &buffer, buffer.count)
            return buffer.prefix(max(count, 0)).map { UInt8(bitPattern: $0) }
        }
        #expect(linkBytes(dir) == [UInt8]("tg".utf8) + [0xff])
        #expect(linkBytes(dir) == linkBytes(other))
        #expect(try state(of: dir) == state(of: other))
    }

    @Test("an unchanged skip-worktree link whose target isn't UTF-8 is up to date")
    func hiddenNonUTF8Symlink() throws {
        let dir = try makeRepository()
        func linkBlob(_ bytes: [UInt8]) throws -> String {
            let blob = dir.appendingPathComponent("blob")
            try Data(bytes).write(to: blob)
            defer { try? FileManager.default.removeItem(at: blob) }
            return try git(["hash-object", "-w", "blob"], in: dir).stdout
        }
        try git(["checkout", "-q", "-b", "linked", "base"], in: dir)
        try git(["update-index", "--add", "--cacheinfo", "120000,\(try linkBlob([UInt8]("tg".utf8) + [0xff])),lnk"],
                in: dir)
        try git(["commit", "-q", "-m", "linked"], in: dir)
        try git(["checkout", "-q", "-f", "linked"], in: dir)
        try git(["checkout", "-q", "-b", "relinked"], in: dir)
        try git(["update-index", "--cacheinfo", "120000,\(try linkBlob([UInt8]("other".utf8))),lnk"], in: dir)
        try git(["commit", "-q", "-m", "relinked"], in: dir)
        try git(["checkout", "-q", "-f", "linked"], in: dir)
        try git(["update-index", "--skip-worktree", "lnk"], in: dir)
        let result = try merge(["c", "relinked"], in: dir)
        guard case .mergeCommit = result.outcome else {
            Issue.record("expected a merge commit, got \(result.outcome)"); return
        }
    }

    @Test("with core.symlinks=false, links are files holding their targets, kept and checked so",
          arguments: [false, true])
    func linksAsFiles(hidden: Bool) throws {
        let dir = try makeRepository()
        try git(["config", "core.symlinks", "false"], in: dir)
        func linkBlob(_ target: String) throws -> String {
            try write(target, to: "blob", in: dir)
            defer { try? FileManager.default.removeItem(at: dir.appendingPathComponent("blob")) }
            return try git(["hash-object", "-w", "blob"], in: dir).stdout
        }
        try git(["checkout", "-q", "-b", "linked", "base"], in: dir)
        try git(["update-index", "--add", "--cacheinfo", "120000,\(try linkBlob("x")),lnk"], in: dir)
        try git(["commit", "-q", "-m", "linked"], in: dir)
        try git(["checkout", "-q", "-f", "linked"], in: dir)
        for (branch, target) in [("relinked", "y"), ("relinked2", "z")] {
            try git(["checkout", "-q", "-f", "-b", branch, "linked"], in: dir)
            try git(["update-index", "--cacheinfo", "120000,\(try linkBlob(target)),lnk"], in: dir)
            try git(["commit", "-q", "-m", branch], in: dir)
        }
        try git(["checkout", "-q", "-f", "linked"], in: dir)
        if hidden {
            // Unchanged, as the file git checked out: up to date.
            try git(["update-index", "--skip-worktree", "lnk"], in: dir)
            let result = try merge(["c", "relinked"], in: dir)
            guard case .mergeCommit = result.outcome else {
                Issue.record("expected a merge commit, got \(result.outcome)"); return
            }
            return
        }
        // Both sides changed it: our side stays, as a file.
        try git(["checkout", "-q", "-f", "-b", "ours", "relinked2"], in: dir)
        let other = try twin(of: dir)
        _ = try merge(["c", "relinked"], in: dir)
        _ = try git(["merge", "-q", "-m", "Merge branches", "c", "relinked"], in: other, check: false)
        #expect(try state(of: dir) == state(of: other))
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("lnk").path)
        #expect(attributes[.type] as? FileAttributeType == .typeRegular)
        #expect(try String(contentsOf: dir.appendingPathComponent("lnk"), encoding: .utf8) == "z")
    }
}
#endif

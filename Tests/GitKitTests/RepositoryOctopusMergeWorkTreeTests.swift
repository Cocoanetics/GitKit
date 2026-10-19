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
}
#endif

// `[include]` handling of the config backend — gated to Apple/Linux like the
// other suites that lay out repositories on disk.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

@Suite("Config includes")
struct ConfigIncludeTests {

    /// A repository whose `.git/config` includes `.git/extra`, which
    /// repeats `test.k`.
    private func makeRepo(
        config: String = "[test]\n\tk = a\n[include]\n\tpath = extra\n",
        extra: String = "[test]\n\tk = b\n\tonly = included\n"
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigIncludeTests-\(UUID().uuidString)")
        try Repository.initialize(at: dir)
        let git = dir.appendingPathComponent(".git")
        let url = git.appendingPathComponent("config")
        let existing = try String(contentsOf: url, encoding: .utf8)
        try (existing + config).write(to: url, atomically: true, encoding: .utf8)
        try extra.write(to: git.appendingPathComponent("extra"), atomically: true, encoding: .utf8)
        return dir
    }

    private func read(_ dir: URL, _ name: String) throws -> String {
        try String(contentsOf: dir.appendingPathComponent(".git/\(name)"), encoding: .utf8)
    }

    @Test("configSet of a key an included file repeats changes only the target file")
    func setKeyRepeatedByInclude() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let extra = try read(dir, "extra")

        let repo = try Repository.open(at: dir)
        try repo.configSet("test.k", "c")

        #expect(try read(dir, "config").contains("k = c"))
        #expect(try !read(dir, "config").contains("k = a"))
        #expect(try read(dir, "extra") == extra)
    }

    @Test("configSet to the value the included file holds still writes the target file")
    func setValueMatchingInclude() throws {
        let dir = try makeRepo(config: "[include]\n\tpath = extra\n")
        defer { try? FileManager.default.removeItem(at: dir) }

        let repo = try Repository.open(at: dir)
        try repo.configSet("test.k", "b")

        #expect(try read(dir, "config").contains("k = b"))
    }

    @Test("configUnset of a key an included file repeats removes only the target file's line")
    func unsetKeyRepeatedByInclude() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let extra = try read(dir, "extra")

        let repo = try Repository.open(at: dir)
        #expect(try repo.configUnset("test.k"))

        #expect(try !read(dir, "config").contains("k = a"))
        #expect(try read(dir, "extra") == extra)
    }

    @Test("a key only the included file holds: set appends to the target, unset finds nothing")
    func keyOnlyInInclude() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let extra = try read(dir, "extra")

        let repo = try Repository.open(at: dir)
        #expect(try !repo.configUnset("test.only"))
        try repo.configSet("test.only", "local")

        #expect(try read(dir, "config").contains("only = local"))
        #expect(try read(dir, "extra") == extra)
    }

    @Test("a key repeated within the target file is still a multivar error")
    func multivarInTargetFile() throws {
        let dir = try makeRepo(config: "[test]\n\tk = a\n\tk = b\n[include]\n\tpath = extra\n")
        defer { try? FileManager.default.removeItem(at: dir) }

        let repo = try Repository.open(at: dir)
        #expect(throws: Libgit2Error.self) { try repo.configSet("test.k", "c") }
        #expect(throws: Libgit2Error.self) { try repo.configUnset("test.k") }
    }
}
#endif

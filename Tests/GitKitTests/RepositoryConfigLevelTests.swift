// Operation-only config levels added to one open repository — gated to
// Apple/Linux like the other suites that lay out repositories on disk.
#if os(macOS) || os(Linux)
import Foundation
import Testing
import CGitKit
@testable import GitKit

/// `addConfigFile(at:level:)` and `addConfigEntries(_:level:name:)`, checked
/// against libgit2's own view of the repository's live config.
@Suite("Repository config levels", .serialized)
struct RepositoryConfigLevelTests {

    private let fixtures = TemporaryRepositories()

    private static let lf = Data("a\nb\n".utf8)
    private static let crlf = Data("a\r\nb\r\n".utf8)

    private func makeRepository(_ name: String = "repo") throws -> (URL, Repository) {
        let dir = try fixtures.directory(name)
        let repo = try Repository.initialize(at: dir, initialBranch: "main")
        try repo.configSet("t.both", "local")
        return (dir, repo)
    }

    private func write(_ text: String, to name: String) throws -> URL {
        let url = fixtures.url(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// The live config entry for `name`, as libgit2 resolves a single read.
    private static func entry(_ name: String, in repo: Repository)
        throws -> (value: String?, level: git_config_level_t, backend: String?)? {
        var config: OpaquePointer?
        try check(git_repository_config(&config, repo.repo))
        defer { git_config_free(config) }
        var entry: UnsafeMutablePointer<git_config_entry>?
        let rc = git_config_get_entry(&entry, config, name)
        if rc == GIT_ENOTFOUND.rawValue { return nil }
        try check(rc)
        defer { git_config_entry_free(entry) }
        let e = try #require(entry).pointee
        return (e.value.map { String(cString: $0) }, e.level, e.backend_type.map { String(cString: $0) })
    }

    private static func multivar(_ name: String, in repo: Repository) throws -> [String?] {
        var config: OpaquePointer?
        try check(git_repository_config(&config, repo.repo))
        defer { git_config_free(config) }
        var iter: UnsafeMutablePointer<git_config_iterator>?
        try check(git_config_multivar_iterator_new(&iter, config, name, nil))
        defer { git_config_iterator_free(iter) }
        var values: [String?] = []
        var entry: UnsafeMutablePointer<git_config_entry>?
        while git_config_next(&entry, iter) == 0 {
            values.append(entry?.pointee.value.map { String(cString: $0) })
        }
        return values
    }

    private static func bool(_ name: String, in repo: Repository) throws -> Bool {
        var config: OpaquePointer?
        try check(git_repository_config(&config, repo.repo))
        defer { git_config_free(config) }
        var out: Int32 = 0
        try check(git_config_get_bool(&out, config, name))
        return out != 0
    }

    // MARK: Precedence and replacement

    @Test("levels read in libgit2's order: app, local, global, system")
    func precedence() throws {
        defer { fixtures.removeAll() }
        let (_, repo) = try makeRepository()
        let global = try write("[t]\n\tboth = global\n\tgs = global\n\tonlyGlobal = g\n", to: "global")
        let system = try write("[t]\n\tboth = system\n\tgs = system\n\tonlySystem = s\n", to: "system")

        try repo.addConfigFile(at: global, level: .global)
        try repo.addConfigFile(at: system, level: .system)
        #expect(try repo.configGet("t.both") == "local")
        #expect(try repo.configGet("t.gs") == "global")
        #expect(try repo.configGet("t.onlyglobal") == "g")
        #expect(try repo.configGet("t.onlysystem") == "s")

        try repo.addConfigEntries([ConfigEntry(name: "t.both", value: "app")])
        #expect(try repo.configGet("t.both") == "app")
        #expect(try Self.entry("t.both", in: repo)?.level == GIT_CONFIG_LEVEL_APP)
    }

    @Test("a second add at a level replaces the first")
    func replacement() throws {
        defer { fixtures.removeAll() }
        let (_, repo) = try makeRepository()
        try repo.addConfigFile(at: try write("[t]\n\tfirst = 1\n", to: "one"), level: .global)
        try repo.addConfigFile(at: try write("[t]\n\tsecond = 2\n", to: "two"), level: .global)
        #expect(try repo.configGet("t.first") == nil)
        #expect(try repo.configGet("t.second") == "2")

        try repo.addConfigEntries([ConfigEntry(name: "t.a", value: "1")])
        try repo.addConfigEntries([ConfigEntry(name: "t.b", value: "2")])
        #expect(try repo.configGet("t.a") == nil)
        #expect(try repo.configGet("t.b") == "2")

        // Entries may stand in for a file level, and an empty list empties it.
        try repo.addConfigEntries([], level: .global)
        #expect(try repo.configGet("t.second") == nil)
    }

    @Test("a level belongs to the Repository it was added to")
    func scope() throws {
        defer { fixtures.removeAll() }
        let (dir, repo) = try makeRepository()
        try repo.addConfigEntries([ConfigEntry(name: "t.op", value: "1")])
        let other = try Repository.open(at: dir)
        #expect(try repo.configGet("t.op") == "1")
        #expect(try other.configGet("t.op") == nil)
    }

    // MARK: Write target

    @Test("merged-config writes keep going to the repository's own file")
    func writesStayLocal() throws {
        defer { fixtures.removeAll() }
        let (dir, repo) = try makeRepository()
        let globalText = "[t]\n\tg = 1\n"
        let systemText = "[t]\n\ts = 1\n"
        let global = try write(globalText, to: "global")
        let system = try write(systemText, to: "system")
        try repo.addConfigFile(at: global, level: .global)
        try repo.addConfigFile(at: system, level: .system)
        try repo.addConfigEntries([ConfigEntry(name: "t.app", value: "1")])

        try repo.addRemote(name: "extra", remote: "/nowhere")
        var config: OpaquePointer?
        try check(git_repository_config(&config, repo.repo))
        defer { git_config_free(config) }
        try check(git_config_set_string(config, "t.merged", "v"))

        let local = try String(contentsOf: dir.appendingPathComponent(".git/config"), encoding: .utf8)
        #expect(local.contains("[remote \"extra\"]"))
        #expect(local.contains("merged = v"))
        #expect(try String(contentsOf: global, encoding: .utf8) == globalText)
        #expect(try String(contentsOf: system, encoding: .utf8) == systemText)
        #expect(try repo.configGet("t.merged") == "v")
    }

    @Test("an explicit scope writes the level's file; the in-memory level is read-only")
    func explicitScopeWrites() throws {
        defer { fixtures.removeAll() }
        let (_, repo) = try makeRepository()
        let system = try write("[t]\n\ts = 1\n", to: "system")
        try repo.addConfigFile(at: system, level: .system)
        try repo.configSet("t.added", "yes", scope: .system)
        #expect(try String(contentsOf: system, encoding: .utf8).contains("added = yes"))

        try repo.addConfigEntries([ConfigEntry(name: "t.app", value: "1")])
        var config: OpaquePointer?
        try check(git_repository_config(&config, repo.repo))
        defer { git_config_free(config) }
        var app: OpaquePointer?
        try check(git_config_open_level(&app, config, GIT_CONFIG_LEVEL_APP))
        defer { git_config_free(app) }
        #expect(git_config_set_string(app, "t.app", "2") < 0)
        #expect(try repo.configGet("t.app") == "1")
    }

    // MARK: Caches

    @Test("a core value read before the add follows the added level")
    func coreCacheFollowsAddedLevel() throws {
        defer { fixtures.removeAll() }
        let (dir, repo) = try makeRepository()
        try repo.configSet("core.autocrlf", "false")
        try repo.configSet("user.name", "T")
        try repo.configSet("user.email", "t@example.com")
        let file = dir.appendingPathComponent("text.txt")
        try Self.lf.write(to: file)
        try repo.add(paths: ["text.txt"])
        _ = try repo.commitDetailed(
            message: "initial", author: Signature(name: "T", email: "t@example.com"),
            allowEmpty: false, env: [:], sign: .noSign)

        // The checkout's CRLF filter reads, and libgit2 caches, core.autocrlf.
        try FileManager.default.removeItem(at: file)
        try repo.checkoutPaths(["text.txt"])
        #expect(try Data(contentsOf: file) == Self.lf)

        try repo.addConfigEntries([ConfigEntry(name: "core.autocrlf", value: "true")])
        try FileManager.default.removeItem(at: file)
        try repo.checkoutPaths(["text.txt"])
        #expect(try Data(contentsOf: file) == Self.crlf)
    }

    @Test("core.excludesFile from an added level applies after the attribute cache was built")
    func attributeCacheFollowsAddedLevel() throws {
        defer { fixtures.removeAll() }
        let (dir, repo) = try makeRepository()
        try Data("x\n".utf8).write(to: dir.appendingPathComponent("build.log"))
        let excludes = try write("*.log\n", to: "excludes")
        let global = try write("[core]\n\texcludesFile = \(excludes.path)\n", to: "global")

        #expect(try !repo.isIgnored("build.log"))
        try repo.addConfigFile(at: global, level: .global)
        #expect(try repo.isIgnored("build.log"))
    }

    // MARK: Entry fidelity

    @Test("duplicates keep their order; a single read returns the last")
    func orderedDuplicates() throws {
        defer { fixtures.removeAll() }
        let (_, repo) = try makeRepository()
        try repo.addConfigEntries([
            ConfigEntry(name: "x.y", value: "1"),
            ConfigEntry(name: "a.b", value: "z"),
            ConfigEntry(name: "x.y", value: "2")
        ])
        #expect(try repo.configGet("x.y") == "2")
        #expect(try Self.multivar("x.y", in: repo) == ["1", "2"])
        let app = try repo.configList().filter { ["x.y", "a.b"].contains($0.name) }
        #expect(app.map(\.value) == ["1", "z", "2"])
    }

    @Test("a valueless entry stays distinct from an empty value")
    func valuelessVersusEmpty() throws {
        defer { fixtures.removeAll() }
        let (_, repo) = try makeRepository()
        try repo.addConfigEntries([
            ConfigEntry(name: "t.valueless", value: nil),
            ConfigEntry(name: "t.empty", value: ""),
            ConfigEntry(name: "t.multi", value: nil),
            ConfigEntry(name: "t.multi", value: "")
        ])
        #expect(try Self.entry("t.valueless", in: repo)?.value == nil)
        #expect(try Self.entry("t.empty", in: repo)?.value == "")
        #expect(try Self.bool("t.valueless", in: repo))
        #expect(try !Self.bool("t.empty", in: repo))
        #expect(try Self.multivar("t.multi", in: repo) == [nil, ""])
    }

    @Test("values come back byte for byte")
    func valueFidelity() throws {
        defer { fixtures.removeAll() }
        let (_, repo) = try makeRepository()
        let values = [
            "  padded  ", "#hash", "; semi", "a # b ; c", "\"quoted\"", "say \"hi\"",
            "back\\slash", "ends\\", "\\\"", "\\n literal", "line\nbreak", "tab\there",
            "\u{08}bs", "cr\rlf", "trailing\r", "\n", "é ünï 漢字 🙂", "[core]", "x = y",
            "=", "\u{01}\u{1F}\u{7F}", "multi\\\nline"
        ]
        try repo.addConfigEntries(values.enumerated().map {
            ConfigEntry(name: "v.k\($0.offset)", value: $0.element)
        })
        for (index, value) in values.enumerated() {
            #expect(try Self.entry("v.k\(index)", in: repo)?.value == value, "value \(index)")
        }
    }

    @Test("section and variable read back lowercased; the subsection exactly")
    func names() throws {
        defer { fixtures.removeAll() }
        let (_, repo) = try makeRepository()
        let subsection = "HTTPS://Example.com/?a=b&c=\"d\"\\e.f]g #h;i é"
        try repo.addConfigEntries([
            ConfigEntry(name: "Core.AutoCRLF", value: "input"),
            ConfigEntry(name: "URL.\(subsection).insteadOf", value: "alias:"),
            ConfigEntry(name: "a-b.c-d", value: "1")
        ], name: "command line")

        #expect(try repo.configGet("core.autocrlf") == "input")
        let entry = try #require(try Self.entry("url.\(subsection).insteadof", in: repo))
        #expect(entry.value == "alias:")
        #expect(entry.backend == "command line")
        #expect(entry.level == GIT_CONFIG_LEVEL_APP)
        #expect(try repo.configGet("url.https://example.com/?a=b&c=\"d\"\\e.f]g #h;i é.insteadof") == nil)
        #expect(try repo.configList().contains { $0.name == "url.\(subsection).insteadof" })
        #expect(try repo.configGet("a-b.c-d") == "1")
    }

    @Test("an invalid entry is refused and the level stays as it was")
    func invalidEntries() throws {
        defer { fixtures.removeAll() }
        let (_, repo) = try makeRepository()
        try repo.addConfigEntries([ConfigEntry(name: "t.kept", value: "1")])
        let names = ["", "nosection", ".b", "a.", "-a.b", "a.-b", "a b.c", "a.b c", "é.b",
                     "a.sub\nsection.b", "a\0.b", "a.b\0"]
        for name in names {
            let error = #expect(throws: Libgit2Error.self, "name \(name.debugDescription)") {
                try repo.addConfigEntries([ConfigEntry(name: "t.new", value: "1"),
                                           ConfigEntry(name: name, value: "1")])
            }
            #expect(error?.code == GIT_EINVALIDSPEC.rawValue)
            #expect(error?.klass == Int32(GIT_ERROR_CONFIG.rawValue))
        }
        #expect(throws: Libgit2Error.self) {
            try repo.addConfigEntries([ConfigEntry(name: "t.new", value: "a\0b")])
        }
        #expect(throws: Libgit2Error.self) {
            try repo.addConfigEntries([ConfigEntry(name: "t.new", value: "1")], name: "bad\0name")
        }
        #expect(try repo.configGet("t.kept") == "1")
        #expect(try repo.configGet("t.new") == nil)
    }

    // MARK: Includes and failures

    @Test("an added file's includes go through the repository's policy")
    func includesUseRepositoryPolicy() throws {
        defer { fixtures.removeAll() }
        let (_, repo) = try makeRepository()
        let included = try write("[t]\n\tincluded = yes\n", to: "included")
        let conditional = try write("[t]\n\tconditional = yes\n", to: "conditional")
        let global = try write("""
            [include]
            \tpath = \(included.path)
            [includeIf "gitdir:**/repo/"]
            \tpath = \(conditional.path)
            """, to: "global")
        try repo.addConfigFile(at: try write("[t]\n\tfirst = 1\n", to: "first"), level: .global)

        try repo.setIncludePolicy(ConfigIncludePolicy { _ in false })
        #expect(throws: Libgit2Error.self) { try repo.addConfigFile(at: global, level: .global) }
        #expect(try repo.configGet("t.first") == "1")
        #expect(try repo.configGet("t.included") == nil)

        let asked = ConfigIncludePolicyTests.Recorder()
        try repo.setIncludePolicy(ConfigIncludePolicy { asked.record($0); return true })
        try repo.addConfigFile(at: global, level: .global)
        #expect(try repo.configGet("t.first") == nil)
        #expect(try repo.configGet("t.included") == "yes")
        #expect(try repo.configGet("t.conditional") == "yes")
        #expect(asked.includes.map(\.depth) == [1, 1])
        #expect(asked.includes.allSatisfy { $0.includedFrom == global.path })
        // Another repository's gitdir does not match the condition.
        let (_, other) = try makeRepository("other")
        try other.addConfigFile(at: global, level: .global)
        #expect(try other.configGet("t.conditional") == nil)
    }

    @Test("an include.path entry is stored, not followed")
    func entriesDoNotFollowIncludes() throws {
        defer { fixtures.removeAll() }
        let (_, repo) = try makeRepository()
        let included = try write("[t]\n\tincluded = yes\n", to: "included")
        let asked = ConfigIncludePolicyTests.Recorder()
        try repo.setIncludePolicy(ConfigIncludePolicy { asked.record($0); return true })
        try repo.addConfigEntries([ConfigEntry(name: "include.path", value: included.path)])
        #expect(try repo.configGet("include.path") == included.path)
        #expect(try repo.configGet("t.included") == nil)
        #expect(asked.includes.isEmpty)
    }

    @Test("a missing file reads as empty; an unreadable one is refused")
    func missingAndBrokenFiles() throws {
        defer { fixtures.removeAll() }
        let (_, repo) = try makeRepository()
        try repo.addConfigFile(at: try write("[t]\n\tfirst = 1\n", to: "first"), level: .system)
        try repo.addConfigFile(at: try write("[t]\n\tg = 1\n", to: "global"), level: .global)

        let malformed = try write("[t\n\tbroken\n", to: "malformed")
        #expect(throws: Libgit2Error.self) { try repo.addConfigFile(at: malformed, level: .system) }
        let directory = try fixtures.directory("a-directory")
        #expect(throws: Libgit2Error.self) { try repo.addConfigFile(at: directory, level: .system) }
        #expect(try repo.configGet("t.first") == "1")

        try repo.addConfigFile(at: fixtures.url("missing"), level: .system)
        #expect(try repo.configGet("t.first") == nil)
        #expect(try repo.configGet("t.g") == "1")

        // A failed add left the write target alone too.
        try repo.addRemote(name: "after", remote: "/nowhere")
        let global = try String(contentsOf: fixtures.url("global"), encoding: .utf8)
        #expect(global == "[t]\n\tg = 1\n")
    }
}
#endif

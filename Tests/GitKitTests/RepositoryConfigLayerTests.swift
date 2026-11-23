// Ordered command-line config layers added to one open repository — gated
// to Apple/Linux like the other suites that lay out repositories on disk.
#if os(macOS) || os(Linux)
import Foundation
import Testing
import CGitKit
@testable import GitKit

/// `addConfigLayers(_:)`, git's `-c a -c include.path=<file> -c b`, checked
/// against libgit2's own view of the repository's live config and, where
/// the order matters, against the system `git`.
@Suite("Repository config layers", .serialized)
struct RepositoryConfigLayerTests {

    private let fixtures = TemporaryRepositories()

    private static let lf = Data("a\nb\n".utf8)
    private static let crlf = Data("a\r\nb\r\n".utf8)

    private func makeRepository(_ name: String = "repo") throws -> (URL, Repository) {
        let dir = try fixtures.directory(name)
        let repo = try Repository.initialize(at: dir, initialBranch: "main")
        try repo.configSet("t.local", "local")
        return (dir, repo)
    }

    private func write(_ text: String, to name: String) throws -> URL {
        let url = fixtures.url(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private static func entries(_ pairs: [(String, String?)], name: String = "command line") -> ConfigLayer {
        .entries(pairs.map { ConfigEntry(name: $0.0, value: $0.1) }, name: name)
    }

    private struct Entry {
        let value: String?
        let level: git_config_level_t
        let backend: String?
        let origin: String?
        let depth: UInt32
    }

    /// The live config entry for `name`, as libgit2 resolves a single read.
    private static func entry(_ name: String, in repo: Repository) throws -> Entry? {
        var config: OpaquePointer?
        try check(git_repository_config(&config, repo.repo))
        defer { git_config_free(config) }
        var entry: UnsafeMutablePointer<git_config_entry>?
        let rc = git_config_get_entry(&entry, config, name)
        if rc == GIT_ENOTFOUND.rawValue { return nil }
        try check(rc)
        defer { git_config_entry_free(entry) }
        let e = try #require(entry).pointee
        return Entry(value: e.value.map { String(cString: $0) }, level: e.level,
                     backend: e.backend_type.map { String(cString: $0) },
                     origin: e.origin_path.map { String(cString: $0) }, depth: e.include_depth)
    }

    /// Whether the live config has a level at `level`.
    private static func hasLevel(_ level: git_config_level_t, in repo: Repository) throws -> Bool {
        var config: OpaquePointer?
        try check(git_repository_config(&config, repo.repo))
        defer { git_config_free(config) }
        var found: OpaquePointer?
        let rc = git_config_open_level(&found, config, level)
        git_config_free(found)
        if rc == GIT_ENOTFOUND.rawValue { return false }
        try check(rc)
        return true
    }

    private static func gitGet(_ args: [String], in dir: URL) throws -> String {
        try AmendFixture.git(args, in: dir).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Precedence

    @Test("an included file sits between the entries before and after it, as git reads it")
    func precedenceMatchesGit() throws {
        defer { fixtures.removeAll() }
        let (dir, repo) = try makeRepository()
        let inc = try write("[user]\n\tname = Included\n", to: "inc.cfg")

        // git -c user.name=Before -c include.path=inc -c user.email=a@b
        try repo.addConfigLayers([
            Self.entries([("user.name", "Before"), ("include.path", inc.path)]),
            .file(inc),
            Self.entries([("user.email", "a@b")])
        ])
        #expect(try repo.configGet("user.name") == "Included")
        #expect(try repo.configGet("user.email") == "a@b")
        #expect(try repo.configGet("include.path") == inc.path)
        #expect(try Self.entry("user.email", in: repo)?.level.rawValue == GIT_CONFIG_LEVEL_APP.rawValue + 2)
        #expect(try Self.gitGet(["-c", "user.name=Before", "-c", "include.path=\(inc.path)",
                                 "-c", "user.email=a@b", "config", "--get", "user.name"], in: dir) == "Included")
        // Iteration sees the layers in order, as `git config --list` does;
        // the host's own files are left out of it.
        for level in [ConfigLevel.system, .xdg, .global] { try repo.addConfigEntries([], level: level) }
        let listed = try repo.configEntries().filter { ["user.name", "include.path"].contains($0.name) }
        #expect(listed.map(\.value) == ["Before", inc.path, "Included"])

        // git -c include.path=inc -c user.name=After
        try repo.addConfigLayers([
            Self.entries([("include.path", inc.path)]),
            .file(inc),
            Self.entries([("user.name", "After")])
        ])
        #expect(try repo.configGet("user.name") == "After")
        #expect(try repo.configGet("user.email") == nil)
        #expect(try Self.gitGet(["-c", "include.path=\(inc.path)", "-c", "user.name=After",
                                 "config", "--get", "user.name"], in: dir) == "After")
        // Every layer is read over the repository's own config.
        try repo.configSet("user.name", "Local")
        #expect(try repo.configGet("user.name") == "After")
    }

    @Test("a single layer is the app level")
    func singleLayerIsApp() throws {
        defer { fixtures.removeAll() }
        let (_, repo) = try makeRepository()
        try repo.addConfigLayers([Self.entries([("t.local", "app")], name: "cli")])
        let entry = try #require(try Self.entry("t.local", in: repo))
        #expect(entry.value == "app")
        #expect(entry.level == GIT_CONFIG_LEVEL_APP)
        #expect(entry.backend == "cli")
        #expect(repo.addedConfigLevels == [.app])
    }

    // MARK: Origin and includes

    @Test("a layer file is the origin of its entries; its includes go through the policy")
    func originAndIncludes() throws {
        defer { fixtures.removeAll() }
        let (_, repo) = try makeRepository()
        let nested = try write("[t]\n\tnested = yes\n", to: "nested.cfg")
        let inc = try write("[user]\n\tname = Included\n[include]\n\tpath = nested.cfg\n", to: "inc.cfg")
        let asked = ConfigIncludePolicyTests.Recorder()
        try repo.setIncludePolicy(ConfigIncludePolicy { asked.record($0); return true })

        try repo.addConfigLayers([Self.entries([("include.path", inc.path)]), .file(inc)])
        let name = try #require(try Self.entry("user.name", in: repo))
        #expect(name.origin == inc.path)
        #expect(name.backend == "file")
        #expect(name.depth == 0)
        #expect(name.level.rawValue == GIT_CONFIG_LEVEL_APP.rawValue + 1)
        // A relative include resolves against the included file's directory.
        let nestedEntry = try #require(try Self.entry("t.nested", in: repo))
        #expect(nestedEntry.value == "yes")
        #expect(nestedEntry.origin == nested.path)
        #expect(nestedEntry.depth == 1)
        // Only the file's own include is offered; the layer file is not.
        #expect(asked.includes.map(\.path) == [nested.path])
        #expect(asked.includes.first?.includedFrom == inc.path)

        // A refused include fails the whole set and leaves the old one.
        try repo.setIncludePolicy(ConfigIncludePolicy { _ in false })
        #expect(throws: Libgit2Error.self) {
            try repo.addConfigLayers([Self.entries([("t.replaced", "1")]), .file(inc)])
        }
        #expect(try repo.configGet("t.replaced") == nil)
        #expect(try repo.configGet("user.name") == "Included")
        #expect(try repo.configGet("t.nested") == "yes")
    }

    // MARK: Writes

    @Test("merged-config writes keep going to the repository's own file, not a layer file")
    func writesStayLocal() throws {
        defer { fixtures.removeAll() }
        let (dir, repo) = try makeRepository()
        let incText = "[user]\n\tname = Included\n"
        let inc = try write(incText, to: "inc.cfg")
        try repo.addConfigLayers([.file(inc), Self.entries([("t.after", "1")])])

        try repo.configSet("user.name", "Written", scope: .local)
        try repo.addRemote(name: "extra", remote: "/nowhere")
        var config: OpaquePointer?
        try check(git_repository_config(&config, repo.repo))
        defer { git_config_free(config) }
        try check(git_config_set_string(config, "t.merged", "v"))

        let local = try String(contentsOf: dir.appendingPathComponent(".git/config"), encoding: .utf8)
        #expect(local.contains("[remote \"extra\"]"))
        #expect(local.contains("name = Written"))
        #expect(local.contains("merged = v"))
        #expect(try String(contentsOf: inc, encoding: .utf8) == incText)
        // The layer still wins the read.
        #expect(try repo.configGet("user.name") == "Included")
    }

    // MARK: Replacement

    @Test("a new set replaces every layer; a single app add or no layers clear them")
    func replacement() throws {
        defer { fixtures.removeAll() }
        let (_, repo) = try makeRepository()
        let level = { (offset: Int) in ConfigLayer.level(offset) }
        let global = try write("[t]\n\tglobal = 1\n", to: "global")
        try repo.addConfigFile(at: global, level: .global)

        try repo.addConfigLayers([
            Self.entries([("t.a", "1")]), Self.entries([("t.b", "2")]), Self.entries([("t.c", "3")])
        ])
        #expect(try Self.hasLevel(level(2), in: repo))
        // Another level's add leaves the layers alone.
        try repo.addConfigEntries([], level: .system)
        #expect(try repo.configGet("t.c") == "3")

        try repo.addConfigLayers([Self.entries([("t.d", "4")])])
        #expect(try !Self.hasLevel(level(1), in: repo))
        #expect(try !Self.hasLevel(level(2), in: repo))
        #expect(try repo.configGet("t.a") == nil)
        #expect(try repo.configGet("t.c") == nil)
        #expect(try repo.configGet("t.d") == "4")
        #expect(try repo.configGet("t.global") == "1")

        try repo.addConfigLayers([Self.entries([("t.a", "1")]), Self.entries([("t.b", "2")])])
        try repo.addConfigEntries([ConfigEntry(name: "t.e", value: "5")])
        #expect(try !Self.hasLevel(level(1), in: repo))
        #expect(try repo.configGet("t.b") == nil)
        #expect(try repo.configGet("t.e") == "5")

        try repo.addConfigLayers([Self.entries([("t.a", "1")]), Self.entries([("t.b", "2")])])
        try repo.addConfigFile(at: fixtures.url("missing"), level: .app)
        #expect(try !Self.hasLevel(level(1), in: repo))
        #expect(try repo.configGet("t.a") == nil)

        try repo.addConfigLayers([])
        #expect(try !Self.hasLevel(GIT_CONFIG_LEVEL_APP, in: repo))
        #expect(try repo.configGet("t.local") == "local")
        #expect(try repo.configGet("t.global") == "1")
    }

    @Test("an invalid layer is refused before anything is replaced")
    func invalidLayers() throws {
        defer { fixtures.removeAll() }
        let (_, repo) = try makeRepository()
        try repo.addConfigLayers([Self.entries([("t.kept", "1")]), Self.entries([("t.also", "2")])])

        let web = try #require(URL(string: "https://example.com/inc.cfg"))
        let notFile = #expect(throws: Libgit2Error.self) {
            try repo.addConfigLayers([Self.entries([("t.new", "1")]), .file(web)])
        }
        #expect(notFile?.code == GIT_EINVALIDSPEC.rawValue)
        let badName = #expect(throws: Libgit2Error.self) {
            try repo.addConfigLayers([Self.entries([("t.new", "1")]), Self.entries([("nosection", "1")])])
        }
        #expect(badName?.code == GIT_EINVALIDSPEC.rawValue)
        let malformed = try write("[t\n\tbroken\n", to: "malformed")
        #expect(throws: Libgit2Error.self) {
            try repo.addConfigLayers([Self.entries([("t.new", "1")]), .file(malformed)])
        }
        #expect(try repo.configGet("t.new") == nil)
        #expect(try repo.configGet("t.kept") == "1")
        #expect(try repo.configGet("t.also") == "2")
    }

    @Test("a missing layer file reads as empty; an unreadable one is refused",
          .enabled(if: geteuid() != 0, "root reads a file whatever its mode"))
    func missingAndUnreadableFiles() throws {
        defer { fixtures.removeAll() }
        let (_, repo) = try makeRepository()
        try repo.addConfigLayers([.file(fixtures.url("missing")), Self.entries([("t.after", "1")])])
        #expect(try repo.configGet("t.after") == "1")

        let unreadable = try write("[t]\n\tsecret = 1\n", to: "unreadable")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }
        let error = #expect(throws: Libgit2Error.self) {
            try repo.addConfigLayers([Self.entries([("t.new", "1")]), .file(unreadable)])
        }
        let reason = String(cString: strerror(EACCES))
        #expect(error?.message == "failed to read config file '\(unreadable.path)': \(reason)")
        #expect(throws: Libgit2Error.self) { try repo.addConfigFile(at: unreadable, level: .app) }
        #expect(try repo.configGet("t.new") == nil)
        #expect(try repo.configGet("t.after") == "1")
    }

    // MARK: Caches

    @Test("a core value set by a layer file takes effect on the next checkout")
    func coreCacheFollowsLayers() throws {
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

        try FileManager.default.removeItem(at: file)
        try repo.checkoutPaths(["text.txt"])
        #expect(try Data(contentsOf: file) == Self.lf)

        let inc = try write("[core]\n\tautocrlf = true\n", to: "inc.cfg")
        try repo.addConfigLayers([Self.entries([("include.path", inc.path)]), .file(inc)])
        try FileManager.default.removeItem(at: file)
        try repo.checkoutPaths(["text.txt"])
        #expect(try Data(contentsOf: file) == Self.crlf)
    }
}
#endif

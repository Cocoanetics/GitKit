// Command-line config layers installed into libgit2 configs a host owns —
// gated to Apple/Linux like the other suites that lay out files on disk.
#if os(macOS) || os(Linux)
import Foundation
import Testing
import CGitKit
@testable import GitKit

/// `ConfigLayer.install(_:into:repository:)`, on configs GitKit does not own:
/// a `git_config_new` with synthetic system and global files standing in for
/// `git_config_open_default` (no search path, `HOME` or default policy is
/// changed in this process), and a repository opened with
/// `git_repository_open_ext`.
@Suite("Config layers installed into a host's config")
struct ConfigLayerInstallTests {

    private let fixtures = TemporaryRepositories()

    private func write(_ text: String, to name: String) throws -> URL {
        let url = fixtures.url(name)
        try FileManager.default.createDirectory(at: fixtures.root, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func read(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    private static func entries(_ pairs: [(String, String?)], name: String = "command line") -> ConfigLayer {
        .entries(pairs.map { ConfigEntry(name: $0.0, value: $0.1) }, name: name)
    }

    private static let refuseAll = ConfigIncludePolicy { _ in false }

    /// A config shaped like `git_config_open_default`'s: a system and a
    /// global file, written to by the highest level, as libgit2 orders them.
    private func makeDefaultShaped() throws -> (OpaquePointer, system: URL, global: URL) {
        let system = try write("[t]\n\tsystem = 1\n", to: "system.cfg")
        let global = try write("[t]\n\tglobal = 1\n", to: "global.cfg")
        Libgit2.ensureInitialized()
        var config: OpaquePointer?
        try check(git_config_new(&config))
        let made = try #require(config)
        try check(git_config_add_file_ondisk(made, system.path, GIT_CONFIG_LEVEL_SYSTEM, nil, 0))
        try check(git_config_add_file_ondisk(made, global.path, GIT_CONFIG_LEVEL_GLOBAL, nil, 0))
        return (made, system, global)
    }

    /// A repository created by GitKit, opened again the way a host opens one.
    private func openExt() throws -> (URL, OpaquePointer) {
        let dir = try fixtures.directory("repo")
        _ = try Repository.initialize(at: dir, initialBranch: "main")
        var repo: OpaquePointer?
        try check(git_repository_open_ext(&repo, dir.path, 0, nil))
        return (dir, try #require(repo))
    }

    private struct Entry: Equatable {
        let name: String
        let value: String?
        let level: Int32
        let backend: String?
        let origin: String?
        let depth: UInt32
    }

    /// Every entry of `config`, in the order `git config --list` shows them.
    private static func list(_ config: OpaquePointer) throws -> [Entry] {
        final class Box { var entries: [Entry] = [] }
        let box = Box()
        try check(git_config_foreach(config, { entry, payload in
            let e = entry!.pointee
            Unmanaged<Box>.fromOpaque(payload!).takeUnretainedValue().entries.append(Entry(
                name: String(cString: e.name), value: e.value.map { String(cString: $0) },
                level: e.level.rawValue, backend: e.backend_type.map { String(cString: $0) },
                origin: e.origin_path.map { String(cString: $0) }, depth: e.include_depth))
            return 0
        }, Unmanaged.passUnretained(box).toOpaque()))
        return box.entries
    }

    /// The value a single read of `name` returns, `nil` when there is none.
    private static func get(_ name: String, in config: OpaquePointer) throws -> String? {
        var entry: UnsafeMutablePointer<git_config_entry>?
        let rc = git_config_get_entry(&entry, config, name)
        if rc == GIT_ENOTFOUND.rawValue { return nil }
        try check(rc)
        defer { git_config_entry_free(entry) }
        return try #require(entry).pointee.value.map { String(cString: $0) }
    }

    private static func level(_ index: Int32) -> Int32 { GIT_CONFIG_LEVEL_APP.rawValue + index }

    // MARK: Order and origin

    @Test("layers read in order above the host's levels, with their origin")
    func orderAndOrigin() throws {
        defer { fixtures.removeAll() }
        let (config, _, global) = try makeDefaultShaped()
        defer { git_config_free(config) }
        let inc = try write("[a]\n\tv = 2\n[t]\n\tv = file\n", to: "inc.cfg")

        try ConfigLayer.install([
            Self.entries([("a.v", "1"), ("include.path", inc.path)]),
            .file(inc),
            Self.entries([("a.v", "3")])
        ], into: config)

        #expect(try Self.get("a.v", in: config) == "3")
        #expect(try Self.get("t.global", in: config) == "1")
        let listed = try Self.list(config)
        #expect(listed.map(\.name) == ["t.system", "t.global", "a.v", "include.path", "a.v", "t.v", "a.v"])
        let layers = Array(listed.dropFirst(2))
        #expect(layers.map(\.value) == ["1", inc.path, "2", "file", "3"])
        #expect(layers.map(\.level) == [0, 0, 1, 1, 2].map(Self.level))
        #expect(layers.map(\.backend) == ["command line", "command line", "file", "file", "command line"])
        #expect(layers[2].origin == inc.path)
        #expect(layers.allSatisfy { $0.depth == 0 })
        #expect(listed[1].origin == global.path)
    }

    // MARK: Files

    @Test("a missing layer file reads as empty; an unreadable one is refused",
          .enabled(if: geteuid() != 0, "root reads a file whatever its mode"))
    func missingAndUnreadableFiles() throws {
        defer { fixtures.removeAll() }
        let (config, _, _) = try makeDefaultShaped()
        defer { git_config_free(config) }
        try ConfigLayer.install([.file(fixtures.url("missing")), Self.entries([("t.after", "1")])], into: config)
        #expect(try Self.get("t.after", in: config) == "1")

        let unreadable = try write("[t]\n\tsecret = 1\n", to: "unreadable")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }
        let error = #expect(throws: Libgit2Error.self) {
            try ConfigLayer.install([Self.entries([("t.new", "1")]), .file(unreadable)], into: config)
        }
        let reason = String(cString: strerror(EACCES))
        #expect(error?.message == "failed to read config file '\(unreadable.path)': \(reason)")
        #expect(try Self.get("t.new", in: config) == nil)
        #expect(try Self.get("t.after", in: config) == "1")
    }

    // MARK: All or nothing

    @Test("a layer that is invalid, unreadable or refused leaves the config as it was")
    func allOrNothing() throws {
        defer { fixtures.removeAll() }
        let (config, _, _) = try makeDefaultShaped()
        defer { git_config_free(config) }
        try ConfigLayer.install([Self.entries([("x.v", "1")])], into: config)
        let before = try Self.list(config)

        let web = try #require(URL(string: "https://example.com/inc.cfg"))
        let malformed = try write("[t\n\tbroken\n", to: "malformed")
        let target = try write("[t]\n\tincluded = 1\n", to: "target.cfg")
        let including = try write("[t]\n\tlayer = 1\n[include]\n\tpath = \(target.path)\n", to: "including.cfg")

        let notFile = #expect(throws: Libgit2Error.self) {
            try ConfigLayer.install([Self.entries([("t.new", "1")]), .file(web)], into: config)
        }
        #expect(notFile?.code == GIT_EINVALIDSPEC.rawValue)
        let badName = #expect(throws: Libgit2Error.self) {
            try ConfigLayer.install([Self.entries([("t.new", "1")]), Self.entries([("nosection", "1")])], into: config)
        }
        #expect(badName?.code == GIT_EINVALIDSPEC.rawValue)
        let nul = #expect(throws: Libgit2Error.self) {
            try ConfigLayer.install([Self.entries([("t.new", "a\u{0}b")])], into: config)
        }
        #expect(nul?.code == GIT_EINVALIDSPEC.rawValue)
        #expect(throws: Libgit2Error.self) {
            try ConfigLayer.install([Self.entries([("t.new", "1")]), .file(malformed)], into: config)
        }
        let refused = #expect(throws: Libgit2Error.self) {
            try Repository.withOperationConfiguration(.init(levels: [], includePolicy: Self.refuseAll)) {
                try ConfigLayer.install([Self.entries([("t.new", "1")]), .file(including)], into: config)
            }
        }
        #expect(refused?.message.contains("include of '\(target.path)' is not authorised") == true)

        #expect(try Self.list(config) == before)
    }

    // MARK: Replacement

    @Test("an install replaces every earlier layer; no layers remove them")
    func replacement() throws {
        defer { fixtures.removeAll() }
        let (config, _, _) = try makeDefaultShaped()
        defer { git_config_free(config) }
        try ConfigLayer.install(
            [Self.entries([("t.one", "1")]), Self.entries([("t.two", "2")]), Self.entries([("t.three", "3")])],
            into: config)
        try ConfigLayer.install([Self.entries([("t.four", "4")])], into: config)
        #expect(try Self.list(config).map(\.name) == ["t.system", "t.global", "t.four"])
        try ConfigLayer.install([], into: config)
        #expect(try Self.list(config).map(\.name) == ["t.system", "t.global"])
    }

    // MARK: Writes

    @Test("writes keep going to the global file, never to a layer file")
    func writesStayGlobal() throws {
        defer { fixtures.removeAll() }
        let (config, system, global) = try makeDefaultShaped()
        defer { git_config_free(config) }
        let layer = try write("[t]\n\tlayer = 1\n", to: "layer.cfg")
        let layerBytes = try read(layer)
        let systemBytes = try read(system)

        try ConfigLayer.install([.file(layer), Self.entries([("t.after", "1")])], into: config)
        try check(git_config_set_string(config, "x.y", "1"))
        #expect(try read(global).contains("[x]"))
        #expect(try read(layer) == layerBytes)
        #expect(try read(system) == systemBytes)
    }

    @Test("the old replace helper still leaves the moved levels writable")
    func oldHelperContract() throws {
        defer { fixtures.removeAll() }
        for readonly in [false, true] {
            let (config, _, global) = try makeDefaultShaped()
            defer { git_config_free(config) }
            let layer = try write("[t]\n\tlayer = 1\n", to: "layer.cfg")
            let staged = try ConfigBackends.newConfig()
            defer { git_config_free(staged) }
            try ConfigBackends.addFile(layer, to: staged, at: GIT_CONFIG_LEVEL_APP, repository: nil)
            if readonly {
                try check(gitkit_config_replace_levels_readonly_from(config, staged, GIT_CONFIG_LEVEL_APP))
            } else {
                try check(gitkit_config_replace_levels_from(config, staged, GIT_CONFIG_LEVEL_APP))
            }
            try check(git_config_set_string(config, "x.y", "1"))
            #expect(try read(layer).contains("[x]") == !readonly)
            #expect(try read(global).contains("[x]") == readonly)
        }
    }

    // MARK: A repository the host opened

    @Test("a repository opened with open_ext keeps its own write target and include context")
    func openExtRepository() throws {
        defer { fixtures.removeAll() }
        let (dir, repo) = try openExt()
        defer { git_repository_free(repo) }
        var config: OpaquePointer?
        try check(git_repository_config(&config, repo))
        defer { git_config_free(config) }
        let live = try #require(config)

        // libgit2 matches the git directory without its trailing slash.
        let gitdir = String(String(cString: git_repository_path(repo)).dropLast())
        let conditional = try write("[t]\n\tconditional = 1\n", to: "conditional.cfg")
        let layer = try write(
            "[t]\n\tlayer = 1\n[includeIf \"gitdir:\(gitdir)\"]\n\tpath = \(conditional.path)\n", to: "layer.cfg")
        let layerBytes = try read(layer)
        let layers = [Self.entries([("core.bare", "false"), ("include.path", layer.path)]), .file(layer)]

        try ConfigLayer.install(layers, into: live, repository: repo)
        let bare = try #require(try Self.list(live).first { $0.name == "core.bare" && $0.level >= Self.level(0) })
        #expect(bare.value == "false")
        #expect(bare.backend == "command line")
        #expect(try Self.get("t.layer", in: live) == "1")
        #expect(try Self.get("t.conditional", in: live) == "1")

        try check(git_config_set_string(live, "x.y", "1"))
        #expect(try read(dir.appendingPathComponent(".git/config")).contains("[x]"))
        #expect(try read(layer) == layerBytes)

        // With no repository, a gitdir: condition never matches.
        try ConfigLayer.install(layers, into: live)
        #expect(try Self.get("t.layer", in: live) == "1")
        #expect(try Self.get("t.conditional", in: live) == nil)
    }

    // MARK: Lifetime

    @Test("a snapshot outlives the config and the repository it was installed with")
    func snapshotOutlivesHandles() throws {
        defer { fixtures.removeAll() }
        let (_, repo) = try openExt()
        let layer = try write("[t]\n\tlayer = 1\n", to: "layer.cfg")
        var config: OpaquePointer?
        try check(git_repository_config(&config, repo))
        try ConfigLayer.install([.file(layer), Self.entries([("t.after", "1")])], into: #require(config), repository: repo)
        var snapshot: OpaquePointer?
        try check(git_config_snapshot(&snapshot, config))
        defer { git_config_free(snapshot) }
        git_config_free(config)
        git_repository_free(repo)

        let kept = try #require(snapshot)
        #expect(try Self.get("t.layer", in: kept) == "1")
        #expect(try Self.get("t.after", in: kept) == "1")
    }

    @Test("a re-read asks the policy in force for it; GitKit registers none for the host's handle")
    func policyAcrossReloads() throws {
        defer { fixtures.removeAll() }
        let (_, repo) = try openExt()
        defer { git_repository_free(repo) }
        var config: OpaquePointer?
        try check(git_repository_config(&config, repo))
        defer { git_config_free(config) }
        let live = try #require(config)
        let target = try write("[t]\n\tincluded = 1\n", to: "target.cfg")
        let layer = try write("[t]\n\tlayer = 1\n", to: "layer.cfg")
        try ConfigLayer.install([.file(layer)], into: live, repository: repo)

        var generation = 0
        func addInclude() throws {
            generation += 1
            _ = try write("[t]\n\tlayer = \(String(repeating: "x", count: generation))\n" +
                          "[include]\n\tpath = \(target.path)\n", to: "layer.cfg")
        }

        // The thread's policy refuses the re-read inside its scope ...
        try addInclude()
        let refused = #expect(throws: Libgit2Error.self) {
            try Repository.withOperationConfiguration(.init(levels: [], includePolicy: Self.refuseAll)) {
                _ = try Self.get("t.layer", in: live)
            }
        }
        #expect(refused?.message.contains("is not authorised") == true)
        // ... and nothing registered for the handle refuses it outside.
        try addInclude()
        #expect(try Self.get("t.included", in: live) == "1")

        // A registration for the handle governs every later re-read.
        #expect(ConfigIncludePolicyBox.register(Self.refuseAll, forRepository: repo) == 0)
        defer { _ = ConfigIncludePolicyBox.register(nil, forRepository: repo) }
        try addInclude()
        #expect(throws: Libgit2Error.self) { try Self.get("t.layer", in: live) }
    }

    @Test("a layer file installed with no repository re-reads with none")
    func reloadWithoutRepository() throws {
        defer { fixtures.removeAll() }
        let (config, _, _) = try makeDefaultShaped()
        defer { git_config_free(config) }
        let layer = try write("[t]\n\tlayer = 1\n", to: "layer.cfg")
        try ConfigLayer.install([.file(layer)], into: config)
        _ = try write("[t]\n\tlayer = changed\n", to: "layer.cfg")
        #expect(try Self.get("t.layer", in: config) == "changed")
    }

    // MARK: Snapshots

    @Test("a snapshot keeps the layers it was taken with")
    func snapshotsAndLiveConfig() throws {
        defer { fixtures.removeAll() }
        let (config, _, _) = try makeDefaultShaped()
        defer { git_config_free(config) }
        var before: OpaquePointer?
        try check(git_config_snapshot(&before, config))
        defer { git_config_free(before) }
        try ConfigLayer.install([Self.entries([("t.layer", "1")])], into: config)
        var after: OpaquePointer?
        try check(git_config_snapshot(&after, config))
        defer { git_config_free(after) }
        try ConfigLayer.install([], into: config)

        #expect(try Self.get("t.layer", in: #require(before)) == nil)
        #expect(try Self.get("t.layer", in: #require(after)) == "1")
        #expect(try Self.get("t.layer", in: config) == nil)
    }

    @Test("a repository's config snapshot taken before addConfigLayers is unaffected")
    func repositorySnapshotBeforeLayers() throws {
        defer { fixtures.removeAll() }
        let repo = try Repository.initialize(at: fixtures.directory("repo"), initialBranch: "main")
        var snapshot: OpaquePointer?
        try check(git_repository_config_snapshot(&snapshot, repo.repo))
        defer { git_config_free(snapshot) }
        try repo.addConfigLayers([Self.entries([("t.layer", "1")])])
        #expect(try Self.get("t.layer", in: #require(snapshot)) == nil)
        #expect(try repo.configGet("t.layer") == "1")
    }

    // MARK: The real default config

    @Test("layers installed into git_config_open_default, in a process of its own")
    func realDefaultConfig() async throws {
        // The child changes HOME before libgit2 reads it; this process owns
        // the fixtures and removes them.
        defer { fixtures.removeAll() }
        let root = try fixtures.directory("home").path
        await #expect(processExitsWith: .success) { [root = root as String] in
            let home = URL(fileURLWithPath: root, isDirectory: true)
            setenv("HOME", home.path, 1)
            setenv("XDG_CONFIG_HOME", home.appendingPathComponent("xdg").path, 1)
            let global = home.appendingPathComponent(".gitconfig")
            try Data("[t]\n\tglobal = 1\n".utf8).write(to: global)
            let target = home.appendingPathComponent("target.cfg")
            try Data("[t]\n\tincluded = 1\n".utf8).write(to: target)
            let layer = home.appendingPathComponent("layer.cfg")
            try Data("[t]\n\tlayer = 1\n".utf8).write(to: layer)

            Libgit2.ensureInitialized()
            var config: OpaquePointer?
            guard git_config_open_default(&config) == 0, let config else { exit(10) }
            defer { git_config_free(config) }
            try ConfigLayer.install([Self.entries([("t.layer", "0")]), .file(layer)], into: config)
            guard try Self.get("t.global", in: config) == "1",
                  try Self.get("t.layer", in: config) == "1" else { exit(11) }
            try check(git_config_set_string(config, "x.y", "1"))
            guard String(decoding: try Data(contentsOf: global), as: UTF8.self).contains("[x]"),
                  !String(decoding: try Data(contentsOf: layer), as: UTF8.self).contains("[x]") else { exit(12) }

            ConfigIncludePolicy.setDefault(ConfigIncludePolicy { _ in false })
            try Data("[t]\n\tlayer = 2\n[include]\n\tpath = \(target.path)\n".utf8).write(to: layer)
            guard (try? Self.get("t.layer", in: config)) == nil else { exit(13) }
        }
    }
}
#endif

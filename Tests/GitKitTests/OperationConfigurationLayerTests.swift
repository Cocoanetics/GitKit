// Command-line config layers in an operation's scope, reaching the
// repositories libgit2 opens for itself — gated to Apple/Linux like the
// suite it extends.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

/// `OperationConfiguration.Level.layers(_:)`: git's
/// `-c a -c include.path=<file> -c b` for every repository opened in scope.
extension OperationConfigurationTests {

    @Test("a submodule libgit2 opens itself reads the command-line layers in order")
    func hiddenSubmoduleHandlesReadLayers() throws {
        defer { fixtures.removeAll() }
        let fixture = try makeFixture()
        let inc = try write("[core]\n\tautocrlf = true\n", to: "inc.cfg")
        let before = try configBytes(fixture, plus: [inc])
        let outer = try Repository.open(at: fixture.outer)
        let include = ConfigEntry(name: "include.path", value: inc.path)
        let autocrlfFalse = ConfigEntry(name: "core.autocrlf", value: "false")
        func status(_ levels: [OperationConfiguration.Level]) throws -> [String] {
            try Repository.withOperationConfiguration(OperationConfiguration(levels: levels)) {
                try outer.status().entries.map(\.path)
            }
        }

        // git -c include.path=inc -c t.after=1: the file is read in its place.
        #expect(try status([.layers([.entries([include]), .file(inc),
                                     .entries([ConfigEntry(name: "t.after", value: "1")])])]) == [])
        // Control: as two .app levels, the later one replaces the file.
        #expect(try status([.file(inc, .app), .entries([ConfigEntry(name: "t.after", value: "1")])])
            == ["middle-sub"])
        // The order decides: entries after the file win over it, before it lose.
        #expect(try status([.layers([.entries([autocrlfFalse, include]), .file(inc)])]) == [])
        #expect(try status([.layers([.entries([include]), .file(inc), .entries([autocrlfFalse])])])
            == ["middle-sub"])
        #expect(try configBytes(fixture, plus: [inc]) == before)
    }

    @Test("a repository opened in the scope gets the layers at consecutive levels")
    func openedRepositoryReadsLayers() throws {
        defer { fixtures.removeAll() }
        let dir = try fixtures.directory("repo")
        _ = try Repository.initialize(at: dir, initialBranch: "main")
        let inc = try write("[user]\n\tname = Included\n", to: "inc.cfg")
        let configuration = OperationConfiguration(levels: [.layers([
            .entries([ConfigEntry(name: "user.name", value: "Before"),
                      ConfigEntry(name: "include.path", value: inc.path)]),
            .file(inc),
            .entries([ConfigEntry(name: "user.email", value: "a@b")])
        ])])
        let repo = try Repository.withOperationConfiguration(configuration) {
            try Repository.open(at: dir)
        }
        #expect(try repo.configGet("user.name") == "Included")
        #expect(try repo.configGet("user.email") == "a@b")
        #expect(repo.addedConfigLevels == [.app])
        try repo.configSet("t.local", "1")
        #expect(try String(contentsOf: inc, encoding: .utf8) == "[user]\n\tname = Included\n")

        // No layers: no command-line config; they replace an earlier .app.
        let none = try Repository.withOperationConfiguration(OperationConfiguration(levels: [
            .entries([ConfigEntry(name: "user.name", value: "App")]), .layers([])
        ])) { try Repository.open(at: dir).configGet("user.name") }
        #expect(none != "App")
    }

    @Test("a nested .layers or .app replaces the outer scope's whole command-line set")
    func nestedLayersReplaceOuterSet() throws {
        defer { fixtures.removeAll() }
        let dir = try fixtures.directory("repo")
        _ = try Repository.initialize(at: dir, initialBranch: "main")
        let global = try write("[t]\n\thost = outer\n", to: "global")
        func probe(_ name: String) throws -> String? { try Repository.open(at: dir).configGet(name) }
        func layer(_ name: String) -> ConfigLayer { .entries([ConfigEntry(name: "t.\(name)", value: "1")]) }

        let outer = OperationConfiguration(levels: Self.hostIsolated + [
            .file(global, .global), .layers([layer("a"), layer("b"), layer("c")])
        ])
        try Repository.withOperationConfiguration(outer) { () throws in
            #expect(try probe("t.c") == "1")
            // A scope that names no command-line level keeps the outer set.
            try Repository.withOperationConfiguration(OperationConfiguration(levels: [
                .entries([], .system, name: "inner")
            ])) { () throws in
                #expect(try probe("t.b") == "1")
            }
            try Repository.withOperationConfiguration(OperationConfiguration(levels: [.layers([layer("d")])])) {
                () throws in
                #expect(try probe("t.a") == nil)
                #expect(try probe("t.c") == nil)
                #expect(try probe("t.d") == "1")
                #expect(try probe("t.host") == "outer")
            }
            try Repository.withOperationConfiguration(OperationConfiguration(levels: [
                .entries([ConfigEntry(name: "t.e", value: "1")])
            ])) { () throws in
                #expect(try probe("t.b") == nil)
                #expect(try probe("t.e") == "1")
            }
            #expect(try probe("t.a") == "1")
        }
    }

    @Test("a layer file and its includes cannot change a repository's format or layout")
    func layerFilesSkipRepositoryOnlySettings() throws {
        defer { fixtures.removeAll() }
        let dir = try fixtures.directory("repo")
        _ = try Repository.initialize(at: dir, initialBranch: "main")
        let nested = try write("[core]\n\tbare = true\n[t]\n\tnested = yes\n", to: "nested.cfg")
        let inc = try write(
            "[core]\n\tbare = true\n[extensions]\n\tgitkitbogus = yes\n"
                + "[include]\n\tpath = \(nested.path)\n[t]\n\tlayer = yes\n",
            to: "inc.cfg")
        let configuration = OperationConfiguration(
            levels: [.layers([.entries([]), .file(inc)])], includePolicy: ConfigIncludePolicy { _ in true })
        try Repository.withOperationConfiguration(configuration) { () throws in
            let repo = try Repository.open(at: dir)
            #expect(repo.workdirURL != nil)
            #expect(try repo.configGet("core.bare") == "false")
            #expect(try repo.configGet("extensions.gitkitbogus") == nil)
            #expect(try repo.configGet("t.layer") == "yes")
            #expect(try repo.configGet("t.nested") == "yes")
        }
        let refused = OperationConfiguration(levels: [
            .layers([.entries([ConfigEntry(name: "core.bare", value: "true")])])
        ])
        let error = #expect(throws: Libgit2Error.self) { try Repository.withOperationConfiguration(refused) {} }
        #expect(error?.code == GIT_EINVALIDSPEC.rawValue)
    }

    @Test("an include refused in a layer file during a submodule open is thrown after the body")
    func refusedLayerIncludeIsThrown() throws {
        defer { fixtures.removeAll() }
        let fixture = try makeFixture()
        let nested = try write("[core]\n\tautocrlf = true\n", to: "nested.cfg")
        let inc = try write("[include]\n\tpath = \(nested.path)\n", to: "inc.cfg")
        let outer = try Repository.open(at: fixture.outer)
        func configuration(allowing: Bool) -> OperationConfiguration {
            OperationConfiguration(
                levels: Self.noGlobal.levels + [.layers([.file(inc)])],
                includePolicy: ConfigIncludePolicy { allowing || $0.path != nested.path })
        }

        #expect(try Repository.withOperationConfiguration(configuration(allowing: true)) {
            try outer.status().isClean
        })
        var reported = false
        let error = #expect(throws: Libgit2Error.self) {
            try Repository.withOperationConfiguration(configuration(allowing: false)) {
                _ = try outer.status()
                reported = true
            }
        }
        #expect(reported)
        #expect(error?.message == "include of '\(nested.path)' is not authorised")
    }

    @Test("an unreadable layer file is refused before the body",
          .enabled(if: geteuid() != 0, "root reads a file whatever its mode"))
    func unreadableLayerFileIsRefused() throws {
        defer { fixtures.removeAll() }
        _ = try fixtures.directory("repo")
        let inc = try write("[t]\n\tx = 1\n", to: "inc.cfg")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: inc.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: inc.path) }
        var ran = false
        let error = #expect(throws: Libgit2Error.self) {
            try Repository.withOperationConfiguration(OperationConfiguration(levels: [
                .layers([.entries([]), .file(inc)])
            ])) { ran = true }
        }
        #expect(!ran)
        #expect(error?.message == "failed to read config file '\(inc.path)': \(String(cString: strerror(EACCES)))")
    }
}
#endif

#if os(macOS) || os(Linux)
import Foundation
import Testing
import GitKit

@Suite("Conditional config refresh through public APIs")
struct ConditionalConfigRefreshConsumerTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("GitKitTests-\(UUID().uuidString)")

    private func write(_ text: String, _ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: file, options: .atomic)
        return file
    }

    private func get(_ key: String, _ config: OpaquePointer) throws -> String? {
        var entry: UnsafeMutablePointer<git_config_entry>?
        let result = git_config_get_entry(&entry, config, key)
        if result == GIT_ENOTFOUND.rawValue { return nil }
        #expect(result == 0)
        defer { git_config_entry_free(entry) }
        return try #require(entry).pointee.value.map { String(cString: $0) }
    }

    @Test("URL changes re-evaluate command and file conditions regardless of lookup order",
          arguments: [false, true], [false, true])
    func sourceChanges(fileCondition: Bool, initiallyMatched: Bool) throws {
        defer { try? FileManager.default.removeItem(at: root) }
        Libgit2.ensureInitialized()
        let target = try write("[test]\nvalue = Included\n", "included")
        func source(_ matched: Bool) -> String {
            "[remote \"origin\"]\nurl = https://\(matched ? "match" : "other").example/repo\n"
        }
        let urls = try write(source(initiallyMatched), "urls")
        let conditional = try write(
            "[includeIf \"hasconfig:remote.*.url:https://match.example/**\"]\npath = \(target.path)\n", "conditional")
        var pointer: OpaquePointer?
        #expect(git_config_new(&pointer) == 0)
        let config = try #require(pointer)
        defer { git_config_free(config) }
        #expect(git_config_add_file_ondisk(config, urls.path, GIT_CONFIG_LEVEL_LOCAL, nil, 0) == 0)
        if fileCondition {
            #expect(git_config_add_file_ondisk(config, conditional.path, GIT_CONFIG_LEVEL_GLOBAL, nil, 0) == 0)
            try CommandLineConfig([]).install(into: config)
        } else {
            try CommandLineConfig([
                .includeIf(condition: "hasconfig:remote.*.url:https://match.example/**", path: target.path)
            ]).install(into: config)
        }
        #expect(try get("test.value", config) == (initiallyMatched ? "Included" : nil))

        _ = try write(source(!initiallyMatched), "urls")
        // The dependent backend must notice even before the URL backend is read.
        #expect(try get("test.value", config) == (initiallyMatched ? nil : "Included"))
        #expect(try get("remote.origin.url", config)?.contains(initiallyMatched ? "other" : "match") == true)

        _ = try write(source(initiallyMatched), "urls")
        // Also cover an ordinary URL-backend refresh invalidating its dependents.
        _ = try get("remote.origin.url", config)
        #expect(try get("test.value", config) == (initiallyMatched ? "Included" : nil))
    }

    @Test("multiple dependents refresh when a nested URL source is created or removed")
    func allDependents() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        Libgit2.ensureInitialized()
        let one = try write("[test]\none = yes\n", "one")
        let two = try write("[test]\ntwo = yes\n", "two")
        let nested = root.appendingPathComponent("nested")
        let urls = try write("[include]\npath = \(nested.path)\n", "urls")
        var pointer: OpaquePointer?
        #expect(git_config_new(&pointer) == 0)
        let config = try #require(pointer)
        defer { git_config_free(config) }
        #expect(git_config_add_file_ondisk(config, urls.path, GIT_CONFIG_LEVEL_LOCAL, nil, 0) == 0)
        try CommandLineConfig([
            .includeIf(condition: "hasconfig:remote.*.url:https://match.example/**", path: one.path),
            .includeIf(condition: "hasconfig:remote.*.url:https://match.example/**", path: two.path)
        ]).install(into: config)
        #expect(try get("test.one", config) == nil)
        #expect(try get("test.two", config) == nil)

        _ = try write("[remote \"origin\"]\nurl = https://match.example/repo\n", "nested")
        #expect(try get("test.one", config) == "yes")
        #expect(try get("test.two", config) == "yes")
        var snapshot: OpaquePointer?
        #expect(git_config_snapshot(&snapshot, config) == 0)
        let frozen = try #require(snapshot)
        defer { git_config_free(frozen) }

        try FileManager.default.removeItem(at: nested)
        #expect(try get("test.two", config) == nil)
        #expect(try get("test.one", config) == nil)
        #expect(try get("test.one", frozen) == "yes")
        #expect(try get("test.two", frozen) == "yes")
    }

    @Test("a changed URL source still enforces include denial and can retry")
    func refreshDenial() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try write("[test]\nvalue = Included\n", "included")
        let urls = try write("[remote \"origin\"]\nurl = https://other.example/repo\n", "urls")
        let repository = try Repository.initialize(at: root.appendingPathComponent("repo"), initialBranch: "main")
        try repository.addConfigFile(at: urls, level: .global)
        try repository.setCommandLineConfig(CommandLineConfig([
            .includeIf(condition: "hasconfig:remote.*.url:https://match.example/**", path: target.path)]))
        #expect(try repository.configGet("test.value") == nil)

        _ = try write("[remote \"origin\"]\nurl = https://match.example/repo\n", "urls")
        try repository.setIncludePolicy(ConfigIncludePolicy { $0.path != target.path })
        let error = #expect(throws: Libgit2Error.self) { try repository.configGet("test.value") }
        #expect(error?.message == "include of '\(target.path)' is not authorised")
        try repository.setIncludePolicy(nil)
        #expect(try repository.configGet("test.value") == "Included")
    }

    @Test("direct installs store repository-only entries while operation scopes reject them",
          arguments: ["core.bare", "core.worktree", "core.repositoryformatversion", "extensions.worktreeConfig"])
    func directRepositoryEntries(_ name: String) throws {
        defer { try? FileManager.default.removeItem(at: root) }
        Libgit2.ensureInitialized()
        let directory = root.appendingPathComponent("repo")
        let repository = try Repository.initialize(at: directory, initialBranch: "main")
        let value = name == "core.worktree" ? root.appendingPathComponent("unused").path :
            (name == "core.repositoryformatversion" ? "1" : "true")
        let command = CommandLineConfig([.entries([ConfigEntry(name: name, value: value)])])
        var pointer: OpaquePointer?
        #expect(git_config_new(&pointer) == 0)
        let config = try #require(pointer)
        defer { git_config_free(config) }

        try command.install(into: config)
        #expect(try get(name.lowercased(), config) == value)
        try repository.setCommandLineConfig(command)
        #expect(try repository.configGet(name) == value)
        #expect(repository.workdirURL?.standardizedFileURL.path == directory.standardizedFileURL.path)

        var ran = false
        #expect(throws: Libgit2Error.self) {
            try Repository.withOperationConfiguration(OperationConfiguration(commandLine: command)) { ran = true }
        }
        #expect(!ran)
    }
}
#endif

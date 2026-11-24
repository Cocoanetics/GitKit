#if os(macOS) || os(Linux)
import Foundation
import Testing
import GitKit

@Suite("Conditional configuration through the public API")
struct ConditionalConfigConsumerTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("GitKitTests-\(UUID().uuidString)")

    private func write(_ text: String, _ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func cleanUp() { try? FileManager.default.removeItem(at: root) }

    private final class Records: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [ConfigInclude] = []
        private var messages: [[ConfigDiagnostic]] = []
        func include(_ value: ConfigInclude) { lock.lock(); defer { lock.unlock() }; stored.append(value) }
        func diagnose(_ value: [ConfigDiagnostic]) { lock.lock(); defer { lock.unlock() }; messages.append(value) }
        var includes: [ConfigInclude] { lock.lock(); defer { lock.unlock() }; return stored }
        var diagnostics: [[ConfigDiagnostic]] { lock.lock(); defer { lock.unlock() }; return messages }
    }

    private func newConfig() throws -> OpaquePointer {
        var config: OpaquePointer?
        #expect(git_config_new(&config) == 0)
        return try #require(config)
    }

    private func get(_ name: String, _ config: OpaquePointer) throws -> String? {
        var entry: UnsafeMutablePointer<git_config_entry>?
        let result = git_config_get_entry(&entry, config, name)
        if result == GIT_ENOTFOUND.rawValue { return nil }
        #expect(result == 0)
        defer { git_config_entry_free(entry) }
        return try #require(entry).pointee.value.map { String(cString: $0) }
    }

    @Test("file hasconfig sees later command entries, live and scoped")
    func prospectiveURLs() throws {
        defer { cleanUp() }
        let included = try write("[test]\nvalue = Included\n", "included")
        let conditional = try write(
            "[includeIf \"hasconfig:remote.*.url:https://example.com/**\"]\npath = \(included.path)\n", "conditional")
        let directory = root.appendingPathComponent("repo")
        let repository = try Repository.initialize(at: directory, initialBranch: "main")
        let layers: [ConfigLayer] = [
            .file(conditional), .entries([ConfigEntry(name: "remote.origin.url", value: "https://example.com/repo")])
        ]
        try repository.addConfigLayers(layers)
        #expect(try repository.configGet("test.value") == "Included")
        let opened = try Repository.withOperationConfiguration(OperationConfiguration(layers: layers)) {
            try Repository.open(at: directory)
        }
        #expect(try opened.configGet("test.value") == "Included")
    }

    @Test("a nonmatching hasconfig target cannot define a remote URL")
    func forbiddenURL() throws {
        defer { cleanUp() }
        let included = try write("[remote \"hidden\"]\nurl = https://example.com/hidden\n", "included")
        let conditional = try write(
            "[includeIf \"hasconfig:remote.*.url:never\"]\npath = \(included.path)\n", "conditional")
        let repository = try Repository.initialize(at: root.appendingPathComponent("repo"), initialBranch: "main")
        try repository.addConfigEntries([ConfigEntry(name: "test.old", value: "kept")])
        #expect(throws: Libgit2Error.self) { try repository.addConfigLayers([.file(conditional)]) }
        #expect(try repository.configGet("test.old") == "kept")
    }

    @Test("command gitdir diagnostics depend on repository context")
    func relativeCondition() throws {
        defer { cleanUp() }
        let included = try write("[test]\nvalue = Included\n", "included")
        let directory = root.appendingPathComponent("repo")
        let repository = try Repository.initialize(at: directory, initialBranch: "main")
        let command = CommandLineConfig([.includeIf(condition: "gitdir:./x/", path: included.path)])
        let diagnostics = try repository.setCommandLineConfig(command)
        #expect(try repository.configGet("test.value") == "Included")
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.condition == "gitdir:./x/")
        #expect(diagnostics.first?.gitDirectory?.lastPathComponent == ".git")
        let config = try newConfig()
        defer { git_config_free(config) }
        let records = Records()
        try Repository.withOperationConfiguration(OperationConfiguration(
            levels: [], includePolicy: ConfigIncludePolicy { records.include($0); return false })) { () throws in
            #expect(try command.install(into: config).isEmpty)
        }
        #expect(records.includes.isEmpty)
        #expect(try get("test.value", config) == nil)

        let configuration = OperationConfiguration(commandLine: command, onDiagnostic: { records.diagnose($0) })
        let opened = try Repository.withOperationConfiguration(configuration) { try Repository.open(at: directory) }
        #expect(try opened.configGet("test.value") == "Included")
        #expect(records.diagnostics.count == 1)
        #expect(records.diagnostics.first?.count == 1)
    }

    @Test("conditions match per handle, including unborn branches",
          arguments: ["onbranch:main", "gitdir:**/.git", "gitdir/i:**/.GIT"])
    func supportedConditions(_ condition: String) throws {
        defer { cleanUp() }
        let included = try write("[test]\nvalue = Included\n", "included")
        let directory = root.appendingPathComponent("repo")
        let repository = try Repository.initialize(at: directory, initialBranch: "main")
        let command = CommandLineConfig([.includeIf(condition: condition, path: included.path)])
        #expect(try repository.setCommandLineConfig(command).isEmpty)
        #expect(try repository.configGet("test.value") == "Included")
        let opened = try Repository.withOperationConfiguration(OperationConfiguration(commandLine: command)) {
            try Repository.open(at: directory)
        }
        #expect(try opened.configGet("test.value") == "Included")
    }

    @Test("a relative target fails only for a true condition")
    func relativeTarget() throws {
        defer { cleanUp() }
        let repository = try Repository.initialize(at: root.appendingPathComponent("repo"), initialBranch: "main")
        try repository.setCommandLineConfig(CommandLineConfig([
            .includeIf(condition: "onbranch:other", path: "relative")]))
        #expect(throws: Libgit2Error.self) {
            try repository.setCommandLineConfig(CommandLineConfig([
                .includeIf(condition: "onbranch:main", path: "relative")]))
        }
        let config = try newConfig()
        defer { git_config_free(config) }
        #expect(try CommandLineConfig([.includeIf(condition: "onbranch:main", path: "relative")])
            .install(into: config).isEmpty)
    }

    @Test("hasconfig works outside a repository and sees later command entries")
    func noRepositoryHasconfig() throws {
        defer { cleanUp() }
        let included = try write("[test]\nvalue = Included\n", "included")
        let config = try newConfig()
        defer { git_config_free(config) }
        try CommandLineConfig([
            .includeIf(condition: "hasconfig:remote.*.url:https://example.com/**", path: included.path),
            .entries([ConfigEntry(name: "remote.origin.url", value: "https://example.com/repo")])
        ]).install(into: config)
        #expect(try get("test.value", config) == "Included")
    }

    @Test("false non-hasconfig targets are never offered or accessed")
    func falseTargets() throws {
        defer { cleanUp() }
        let repository = try Repository.initialize(at: root.appendingPathComponent("repo"), initialBranch: "main")
        let records = Records()
        try repository.setIncludePolicy(ConfigIncludePolicy { records.include($0); return false })
        try repository.setCommandLineConfig(CommandLineConfig([
            .includeIf(condition: "gitdir:/impossible/", path: "/not/accessible"),
            .includeIf(condition: "onbranch:other", path: "/not/accessible"),
            .includeIf(condition: "unknown:anything", path: "/not/accessible")
        ]))
        #expect(records.includes.isEmpty)
    }

    @Test("the hasconfig scan authorizes nonmatching targets and denial is atomic")
    func scanPolicy() throws {
        defer { cleanUp() }
        let included = try write("[test]\nvalue = Included\n", "included")
        let repository = try Repository.initialize(at: root.appendingPathComponent("repo"), initialBranch: "main")
        try repository.setCommandLineConfig(CommandLineConfig([
            .entries([ConfigEntry(name: "test.old", value: "kept")])]))
        let records = Records()
        try repository.setIncludePolicy(ConfigIncludePolicy { records.include($0); return false })
        #expect(throws: Libgit2Error.self) {
            try repository.setCommandLineConfig(CommandLineConfig([
                .includeIf(condition: "hasconfig:remote.*.url:never", path: included.path)
            ]))
        }
        #expect(records.includes.map(\.path) == [included.path])
        #expect(records.includes.first?.includedFrom == nil)
        #expect(records.includes.first?.depth == 1)
        #expect(try repository.configGet("test.old") == "kept")
    }

    @Test("file hasconfig in LOCAL sees future global and command sources")
    func localProspectiveURLs() throws {
        defer { cleanUp() }
        let included = try write("[test]\nvalue = Included\n", "included")
        let directory = root.appendingPathComponent("repo")
        let repository = try Repository.initialize(at: directory, initialBranch: "main")
        let local = directory.appendingPathComponent(".git/config")
        try (String(contentsOf: local, encoding: .utf8)
            + "[includeIf \"hasconfig:remote.*.url:https://example.com/**\"]\npath = \(included.path)\n")
            .write(to: local, atomically: true, encoding: .utf8)
        let url = ConfigEntry(name: "remote.origin.url", value: "https://example.com/repo")
        try repository.setCommandLineConfig(CommandLineConfig([.entries([url])]))
        #expect(try repository.configGet("test.value") == "Included")
        try repository.setCommandLineConfig(CommandLineConfig([]))
        #expect(try repository.configGet("test.value") == nil)
        let opened = try Repository.withOperationConfiguration(OperationConfiguration(
            levels: [.entries([url], .global)], commandLine: CommandLineConfig([]))) {
            try Repository.open(at: directory)
        }
        #expect(try opened.configGet("test.value") == "Included")
    }

    @Test("included entries keep their order, level, origin and depth; writes stay LOCAL")
    func metadataAndWrites() throws {
        defer { cleanUp() }
        let nested = try write("[test]\nnested = yes\n", "nested")
        let included = try write("[test]\nvalue = Included\n[include]\npath = \(nested.path)\n", "included")
        let original = try Data(contentsOf: included)
        let directory = root.appendingPathComponent("repo")
        let repository = try Repository.initialize(at: directory, initialBranch: "main")
        var raw: OpaquePointer?
        #expect(git_repository_open_ext(&raw, directory.path, 0, nil) == 0)
        let handle = try #require(raw)
        defer { git_repository_free(handle) }
        var configPointer: OpaquePointer?
        #expect(git_repository_config(&configPointer, handle) == 0)
        let config = try #require(configPointer)
        defer { git_config_free(config) }
        try CommandLineConfig([
            .entries([ConfigEntry(name: "test.value", value: "Before")]),
            .includeIf(condition: "onbranch:other", path: "unread"),
            .includeIf(condition: "onbranch:main", path: included.path),
            .entries([ConfigEntry(name: "test.value", value: "After")])
        ]).install(into: config, repository: handle)
        #expect(try get("test.value", config) == "After")
        var entry: UnsafeMutablePointer<git_config_entry>?
        #expect(git_config_get_entry(&entry, config, "test.nested") == 0)
        let value = try #require(entry)
        defer { git_config_entry_free(value) }
        #expect(value.pointee.level.rawValue == GIT_CONFIG_LEVEL_APP.rawValue + 2)
        #expect(value.pointee.include_depth == 2)
        #expect(String(cString: value.pointee.origin_path) == nested.path)
        #expect(String(cString: value.pointee.backend_type) == "file")
        #expect(git_config_set_string(config, "test.written", "local") == 0)
        #expect(try Data(contentsOf: included) == original)
        #expect(try Repository.open(at: directory).configGet("test.written") == "local")
        #expect(try repository.configGet("test.written") == "local")
    }

    @Test("URL collection forbids remote URLs through any conditional include, including nested files")
    func allConditionalURLGuards() throws {
        defer { cleanUp() }
        let remote = try write("[remote \"hidden\"]\nurl = https://example.com/hidden\n", "remote")
        let nested = try write("[include]\npath = \(remote.path)\n", "nested")
        let empty = try write("[test]\nvalue = Included\n", "included")
        let repository = try Repository.initialize(at: root.appendingPathComponent("repo"), initialBranch: "main")
        for condition in ["hasconfig:remote.*.url:never", "gitdir:**", "onbranch:main"] {
            let error = #expect(throws: Libgit2Error.self) {
                try repository.setCommandLineConfig(CommandLineConfig([
                    .includeIf(condition: condition, path: nested.path),
                    .includeIf(condition: "hasconfig:remote.*.url:never", path: empty.path)
                ]))
            }
            #expect(error?.message.contains("remote URLs cannot be configured") == true)
        }
        // A later unconditional include contributes URLs normally.
        try repository.setCommandLineConfig(CommandLineConfig([
            .includeIf(condition: "hasconfig:remote.*.url:https://example.com/**", path: empty.path),
            .include(path: remote.path)
        ]))
        #expect(try repository.configGet("test.value") == "Included")
    }

    @Test("command includes refresh after their scope has ended and retry after denial")
    func commandRefresh() throws {
        defer { cleanUp() }
        let included = try write("[test]\nvalue = Before\n", "included")
        let directory = root.appendingPathComponent("repo")
        _ = try Repository.initialize(at: directory, initialBranch: "main")
        let repository = try Repository.withOperationConfiguration(OperationConfiguration(
            commandLine: CommandLineConfig([.includeIf(condition: "onbranch:main", path: included.path)]))) {
            try Repository.open(at: directory)
        }
        #expect(try repository.configGet("test.value") == "Before")
        try repository.setIncludePolicy(ConfigIncludePolicy { _ in false })
        try Data("[test]\nvalue = After\n".utf8).write(to: included)
        #expect(throws: Libgit2Error.self) { try repository.configGet("test.value") }
        try repository.setIncludePolicy(nil)
        #expect(try repository.configGet("test.value") == "After")
    }

    @Test("depth ten is supported and depth eleven fails atomically")
    func includeDepth() throws {
        defer { cleanUp() }
        let repository = try Repository.initialize(at: root.appendingPathComponent("repo"), initialBranch: "main")
        var included = try write("[test]\nvalue = deepest\n", "depth-10")
        for depth in (1...9).reversed() {
            included = try write("[include]\npath = \(included.path)\n", "depth-\(depth)")
        }
        try repository.setCommandLineConfig(CommandLineConfig([.include(path: included.path)]))
        #expect(try repository.configGet("test.value") == "deepest")
        let extra = try write("[include]\npath = \(included.path)\n", "depth-0")
        #expect(throws: Libgit2Error.self) {
            try repository.setCommandLineConfig(CommandLineConfig([.include(path: extra.path)]))
        }
        #expect(try repository.configGet("test.value") == "deepest")
    }

    @Test("nested scopes replace only the command-line set and leave no state behind")
    func conditionalScopeLifetime() throws {
        defer { cleanUp() }
        let included = try write("[test]\nvalue = Included\n", "included")
        let directory = root.appendingPathComponent("repo")
        _ = try Repository.initialize(at: directory, initialBranch: "main")
        let configuration = OperationConfiguration(commandLine: CommandLineConfig([
            .includeIf(condition: "onbranch:main", path: included.path)]))
        try Repository.withOperationConfiguration(configuration) { () throws in
            #expect(try Repository.open(at: directory).configGet("test.value") == "Included")
            try Repository.withOperationConfiguration(OperationConfiguration(commandLine: CommandLineConfig([]))) {
                () throws in
                #expect(try Repository.open(at: directory).configGet("test.value") == nil)
            }
            #expect(try Repository.open(at: directory).configGet("test.value") == "Included")
        }
        #expect(try Repository.open(at: directory).configGet("test.value") == nil)
    }
}
#endif

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
}
#endif

// A host's per-operation config, installed through GitKit's public API alone
// into the repository a clone or worktree add prepares — gated to Apple/Linux
// like the other suites that lay out repositories on disk.
#if os(macOS) || os(Linux)
import Foundation
import Testing
import GitKit

@Suite("Operation config levels through the public API", .serialized)
struct ConfigLevelConsumerTests {

    /// Named like GitKitTests' fixtures, so the fixture cleanup check sees it.
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("GitKitTests-\(UUID().uuidString)")

    private static let lf = Data("a\nb\n".utf8)
    private static let crlf = Data("a\r\nb\r\n".utf8)
    private static func silent(_: String) {}

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    private func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    private func write(_ text: String, to name: String) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = url(name)
        try Data(text.utf8).write(to: file)
        return file
    }

    /// `text.txt` holds `a\nb\n`; `core.autocrlf` is off on disk.
    private func makeSource() throws -> (URL, Repository) {
        let dir = url("source")
        let repo = try Repository.initialize(at: dir, initialBranch: "main")
        try repo.configSet("user.name", "T")
        try repo.configSet("user.email", "t@example.com")
        try repo.configSet("core.autocrlf", "false")
        try Self.lf.write(to: dir.appendingPathComponent("text.txt"))
        try repo.add(paths: [])
        _ = try repo.commitDetailed(
            message: "initial", author: Signature(name: "T", email: "t@example.com"),
            allowEmpty: false, env: [:], sign: .noSign)
        return (dir, repo)
    }

    @Test("a prepared clone fetches, checks out and writes through the added levels")
    func preparedClone() throws {
        defer { cleanUp() }
        let (source, _) = try makeSource()
        let globalText = "[t]\n\thost = global\n"
        let global = try write(globalText, to: "global")
        let target = url("clone")

        let clone = try Repository.clone(
            fromRemote: "alias:", to: target, progress: Self.silent,
            preparation: RepositoryPreparation { repository in
                try repository.addConfigFile(at: global, level: .global)
                try repository.addConfigEntries([
                    ConfigEntry(name: "url.\(source.path).insteadOf", value: "alias:"),
                    ConfigEntry(name: "core.autocrlf", value: "true")
                ], name: "command line")
            })

        #expect(try Data(contentsOf: target.appendingPathComponent("text.txt")) == Self.crlf)
        #expect(try clone.configGet("t.host") == "global")
        #expect(try clone.status().isClean)
        let local = try String(contentsOf: target.appendingPathComponent(".git/config"), encoding: .utf8)
        #expect(local.contains("[remote \"origin\"]"))
        #expect(local.contains("[branch \"main\"]"))
        #expect(!local.contains("autocrlf") && !local.contains("insteadOf"))
        #expect(try String(contentsOf: global, encoding: .utf8) == globalText)

        try clone.addRemote(name: "later", remote: "/nowhere")
        try clone.configSet("t.later", "1")
        #expect(try String(contentsOf: global, encoding: .utf8) == globalText)
        #expect(try clone.configGet("t.later") == "1")
    }

    @Test("a valueless entry is true and an empty one false in the first checkout")
    func valuelessVersusEmpty() throws {
        defer { cleanUp() }
        let (source, _) = try makeSource()
        for (name, value, expected) in [("valueless", nil, Self.crlf), ("empty", "", Self.lf)] {
            let target = url(name)
            try Repository.clone(
                fromRemote: source.path, to: target, progress: Self.silent,
                preparation: RepositoryPreparation { repository in
                    try repository.addConfigEntries([ConfigEntry(name: "core.autocrlf", value: value)])
                })
            #expect(try Data(contentsOf: target.appendingPathComponent("text.txt")) == expected, "\(name)")
        }
    }

    @Test("ordered duplicates and exact subsections read back through the public API")
    func entryFidelity() throws {
        defer { cleanUp() }
        let (_, repo) = try makeSource()
        let subsection = "https://Example.com/?a=b"
        try repo.addConfigEntries([
            ConfigEntry(name: "x.y", value: "1"),
            ConfigEntry(name: "x.y", value: " two # 2 "),
            ConfigEntry(name: "url.\(subsection).insteadOf", value: "é:")
        ])
        #expect(try repo.configGet("x.y") == " two # 2 ")
        #expect(try repo.configList().filter { $0.name == "x.y" }.map(\.value) == ["1", " two # 2 "])
        #expect(try repo.configGet("url.\(subsection).insteadof") == "é:")

        try repo.addConfigEntries([
            ConfigEntry(name: "t.flag", value: nil),
            ConfigEntry(name: "t.flag", value: "")
        ])
        #expect(try repo.configEntries().filter { $0.name == "t.flag" }.map(\.value) == [nil, ""])
    }

    @Test("a prepared worktree checks out through levels the primary does not see")
    func preparedWorktree() throws {
        defer { cleanUp() }
        let (_, primary) = try makeSource()
        let path = url("linked")

        let worktree = try primary.worktreeAdd(
            path: path, branch: "feature",
            preparation: RepositoryPreparation { repository in
                try repository.addConfigEntries([ConfigEntry(name: "core.autocrlf", value: "true")])
            })

        #expect(try Data(contentsOf: path.appendingPathComponent("text.txt")) == Self.crlf)
        #expect(try worktree.configGet("core.autocrlf") == "true")
        #expect(try primary.configGet("core.autocrlf") == "false")
    }

    @Test("a refused include or an invalid entry fails the clone and removes it")
    func failedPreparationCleansUp() throws {
        defer { cleanUp() }
        let (source, _) = try makeSource()
        let included = try write("[t]\n\tincluded = 1\n", to: "included")
        let global = try write("[include]\n\tpath = \(included.path)\n", to: "global")
        let asked = Asked()

        let refused = url("refused")
        #expect(throws: Libgit2Error.self) {
            try Repository.clone(
                fromRemote: source.path, to: refused, progress: Self.silent,
                preparation: RepositoryPreparation { repository in
                    try repository.setIncludePolicy(ConfigIncludePolicy { asked.add($0.path); return false })
                    try repository.addConfigFile(at: global, level: .global)
                })
        }
        #expect(asked.paths == [included.path])
        #expect(!FileManager.default.fileExists(atPath: refused.path))

        let invalid = url("invalid")
        #expect(throws: Libgit2Error.self) {
            try Repository.clone(
                fromRemote: source.path, to: invalid, progress: Self.silent,
                preparation: RepositoryPreparation { repository in
                    try repository.addConfigEntries([ConfigEntry(name: "nosection", value: "1")])
                })
        }
        #expect(!FileManager.default.fileExists(atPath: invalid.path))

        let late = url("late")
        #expect(throws: Libgit2Error.self) {
            try Repository.clone(
                fromRemote: source.path, to: late, branch: "does-not-exist", progress: Self.silent,
                preparation: RepositoryPreparation { repository in
                    try repository.addConfigFile(at: global, level: .global)
                    try repository.addConfigEntries([ConfigEntry(name: "core.autocrlf", value: "true")])
                })
        }
        #expect(!FileManager.default.fileExists(atPath: late.path))
    }

    final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        func add(_ path: String) { lock.lock(); seen.append(path); lock.unlock() }
        var paths: [String] { lock.lock(); defer { lock.unlock() }; return seen }
    }
}
#endif

#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

@Suite("Conditional config contexts")
struct ConditionalConfigContextTests {
    private let fixtures = TemporaryRepositories()

    private func write(_ text: String, _ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: fixtures.root, withIntermediateDirectories: true)
        let url = fixtures.url(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test("linked worktrees use their own gitdir, HEAD and worktree-only remote URLs")
    func linkedWorktree() throws {
        defer { fixtures.removeAll() }
        let included = try write("[test]\nvalue = Included\n", "included")
        let primary = try Repository.initialize(at: fixtures.url("primary"), initialBranch: "main")
        try primary.configSet("user.name", "T")
        try primary.configSet("user.email", "t@example.com")
        _ = try primary.commitDetailed(
            message: "initial", author: Signature(name: "T", email: "t@example.com"),
            allowEmpty: true, env: [:], sign: .noSign)
        try primary.configSet("extensions.worktreeConfig", "true")
        let directory = fixtures.url("linked")
        try primary.worktreeAdd(path: directory, branch: "feature")
        let linked = try Repository.open(at: directory)
        let gitdir = String(cString: git_repository_path(linked.repo))
        let worktree = URL(fileURLWithPath: gitdir).appendingPathComponent("config.worktree")
        try Data("[remote \"only\"]\nurl = https://worktree.example/repo\n".utf8).write(to: worktree)
        let common = fixtures.url("primary/.git/config")
        try (String(contentsOf: common, encoding: .utf8)
            + "[includeIf \"hasconfig:remote.*.url:https://worktree.example/**\"]\npath = \(included.path)\n")
            .write(to: common, atomically: true, encoding: .utf8)
        for condition in ["gitdir:\(String(gitdir.dropLast()))",
                          "onbranch:feature", "hasconfig:remote.*.url:https://worktree.example/**"] {
            let command = CommandLineConfig([.includeIf(condition: condition, path: included.path)])
            let live = try Repository.open(at: directory)
            try live.setCommandLineConfig(command)
            #expect(try live.configGet("test.value") == "Included")
            let opened = try Repository.withOperationConfiguration(OperationConfiguration(commandLine: command)) {
                try Repository.open(at: directory)
            }
            #expect(try opened.configGet("test.value") == "Included")
            try primary.setCommandLineConfig(command)
            #expect(try primary.configGet("test.value") == nil)
        }
    }

    @Test("a repository without a path reads its config with gitdir and onbranch false")
    func pathlessRepository() throws {
        defer { fixtures.removeAll() }
        let included = try write("[test]\nvalue = Included\n", "included")
        Libgit2.ensureInitialized()
        var repo: OpaquePointer?
        try check(git_repository_new(&repo))
        defer { git_repository_free(repo) }
        var config: OpaquePointer?
        try check(git_repository_config(&config, repo))
        defer { git_config_free(config) }
        let command = CommandLineConfig([
            .includeIf(condition: "gitdir:**", path: included.path),
            .includeIf(condition: "onbranch:**", path: included.path)
        ])
        let diagnostics = try command.install(into: try #require(config), repository: repo)
        #expect(diagnostics.isEmpty)
        var entry: UnsafeMutablePointer<git_config_entry>?
        #expect(git_config_get_entry(&entry, config, "test.value") == GIT_ENOTFOUND.rawValue)
        git_config_entry_free(entry)
    }

    @Test("installing entries without hasconfig reads no lower includes again")
    func noExtraReads() throws {
        defer { fixtures.removeAll() }
        let included = try write("[test]\nvalue = Included\n", "included")
        let repository = try Repository.initialize(at: fixtures.url("repo"), initialBranch: "main")
        try repository.configSet("include.path", included.path)
        #expect(try repository.configGet("test.value") == "Included")
        try repository.setIncludePolicy(ConfigIncludePolicy { _ in
            Issue.record("no include should be read by this installation")
            return false
        })
        try repository.setCommandLineConfig(CommandLineConfig([
            .entries([ConfigEntry(name: "test.new", value: "new")])]))
        #expect(try repository.configGet("test.new") == "new")
        #expect(try repository.configGet("test.value") == "Included")
    }

    @Test("onbranch is false for detached and unreadable HEAD; a new handle re-evaluates")
    func branchContext() throws {
        defer { fixtures.removeAll() }
        let included = try write("[test]\nvalue = Included\n", "included")
        let directory = fixtures.url("repo")
        let repository = try Repository.initialize(at: directory, initialBranch: "main")
        try repository.configSet("user.name", "T")
        try repository.configSet("user.email", "t@example.com")
        let commit = try repository.commitDetailed(
            message: "initial", author: Signature(name: "T", email: "t@example.com"),
            allowEmpty: true, env: [:], sign: .noSign)
        let command = CommandLineConfig([.includeIf(condition: "onbranch:main", path: included.path)])
        try repository.setCommandLineConfig(command)
        #expect(try repository.configGet("test.value") == "Included")
        var oid = git_oid()
        try check(git_oid_fromstr(&oid, commit.sha))
        try check(git_repository_set_head_detached(repository.repo, &oid))
        // Decisions stay with this handle until explicit application again.
        #expect(try repository.configGet("test.value") == "Included")
        let opened = try Repository.withOperationConfiguration(OperationConfiguration(commandLine: command)) {
            try Repository.open(at: directory)
        }
        #expect(try opened.configGet("test.value") == nil)
        try repository.setCommandLineConfig(command)
        #expect(try repository.configGet("test.value") == nil)
    }

    @Test("a valueless or unexpandable includeIf target fails only when its condition matches")
    func unresolvedTargets() throws {
        defer { fixtures.removeAll() }
        let repository = try Repository.initialize(at: fixtures.url("repo"), initialBranch: "main")
        let kept = CommandLineConfig([.entries([ConfigEntry(name: "test.value", value: "kept")])])
        let cases: [(String?, Bool, String)] = [
            (nil, false, "missing value for 'include.path'"),
            ("~nosuchuser/x", true, "could not expand include path '~nosuchuser/x'")
        ]
        for (path, unexpanded, message) in cases {
            func element(_ condition: String) -> CommandLineConfig.Element {
                unexpanded ? .includeIf(condition: condition, unexpandedPath: path ?? "")
                    : .includeIf(condition: condition, path: path)
            }
            try repository.setCommandLineConfig(kept)
            #expect {
                try repository.setCommandLineConfig(CommandLineConfig([element("onbranch:main")]))
            } throws: { error in
                (error as? Libgit2Error)?.message == message
            }
            // A failed installation leaves the previous config in force.
            #expect(try repository.configGet("test.value") == "kept")
            let configuration = OperationConfiguration(commandLine: CommandLineConfig([element("onbranch:main")]))
            #expect(throws: Libgit2Error.self) {
                try Repository.withOperationConfiguration(configuration) {
                    try Repository.open(at: fixtures.url("repo")).configGet("user.name")
                }
            }

            // Inert when false; the entry keeps Git's name and the raw value.
            try repository.setCommandLineConfig(CommandLineConfig([element("onbranch:other")]))
            #expect(try repository.configGet("test.value") == nil)
            if unexpanded {
                #expect(try repository.configGet("includeif.onbranch:other.path") == path)
                #expect(try repository.configGet("includeif.onbranch:other.gitkit-unexpanded-path") == nil)
            }
        }
        #expect {
            try repository.setCommandLineConfig(CommandLineConfig([.include(unexpandedPath: "~nosuchuser/x")]))
        } throws: { error in
            (error as? Libgit2Error)?.message == "could not expand include path '~nosuchuser/x'"
        }
        #expect {
            try repository.setCommandLineConfig(CommandLineConfig([.include(path: nil)]))
        } throws: { error in
            (error as? Libgit2Error)?.message == "missing value for 'include.path'"
        }
    }

    @Test("a deferred snapshot refresh retains the file backend's condition context")
    func snapshotRefresh() throws {
        defer { fixtures.removeAll() }
        let included = try write("[test]\nvalue = Included\n", "included")
        let repository = try Repository.initialize(at: fixtures.url("repo"), initialBranch: "main")
        let local = fixtures.url("repo/.git/config")
        try (String(contentsOf: local, encoding: .utf8)
            + "[includeIf \"gitdir:**/.git\"]\npath = \(included.path)\n")
            .write(to: local, atomically: true, encoding: .utf8)
        var snapshot: OpaquePointer?
        try check(git_repository_config_snapshot(&snapshot, repository.repo))
        defer { git_config_free(snapshot) }
        var entry: UnsafeMutablePointer<git_config_entry>?
        try check(git_config_get_entry(&entry, snapshot, "test.value"))
        defer { git_config_entry_free(entry) }
        #expect(entry?.pointee.value.map { String(cString: $0) } == "Included")
    }
}
#endif

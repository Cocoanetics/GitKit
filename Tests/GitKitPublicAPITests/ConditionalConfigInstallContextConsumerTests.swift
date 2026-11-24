#if os(macOS) || os(Linux)
import Foundation
import Testing
import GitKit

@Suite("Direct config installs preserve lower repository context")
struct ConditionalConfigInstallContextConsumerTests {
    private final class Policy: @unchecked Sendable {
        var deniedPath: String?
        var paths: [String] = []
    }

    @Test("nil install context preserves lower conditions and per-handle policy on refresh",
          arguments: [false, true], [false, true])
    func lowerContext(command: Bool, hasconfig: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitKitTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("repo")
        try Repository.initialize(at: directory, initialBranch: "main")
        let target = root.appendingPathComponent("included")
        try Data("[test]\nvalue = Included\n".utf8).write(to: target)
        let unconditional = root.appendingPathComponent("unconditional")
        try Data("[test]\nalways = yes\n".utf8).write(to: unconditional)
        let local = directory.appendingPathComponent(".git/config")
        let original = try String(contentsOf: local, encoding: .utf8)
        let text = original + """
            [include]
            path = \(unconditional.path)
            [includeIf "gitdir:**/.git"]
            path = \(target.path)
            [includeIf "onbranch:main"]
            path = \(target.path)

            """
        try Data(text.utf8).write(to: local, options: .atomic)
        var repository: OpaquePointer?
        #expect(git_repository_open_ext(&repository, directory.path, 0, nil) == 0)
        let repo = try #require(repository)
        defer { git_repository_free(repo) }
        let policy = Policy()
        #expect(gitkit_config_set_include_policy(repo, { path, _, _, payload in
            let policy = Unmanaged<Policy>.fromOpaque(payload!).takeUnretainedValue()
            let path = String(cString: path!)
            policy.paths.append(path)
            return policy.deniedPath == path ? -1 : 0
        }, Unmanaged.passUnretained(policy).toOpaque(), nil, nil) == 0)
        defer { _ = gitkit_config_set_include_policy(repo, nil, nil, nil, nil) }
        var pointer: OpaquePointer?
        #expect(git_repository_config(&pointer, repo) == 0)
        let config = try #require(pointer)
        defer { git_config_free(config) }
        let conditional = root.appendingPathComponent("conditional")
        try Data((hasconfig ? "[includeIf \"hasconfig:remote.*.url:never\"]\npath = \(target.path)\n" : "").utf8)
            .write(to: conditional)
        func install() throws {
            if command {
                try CommandLineConfig([.include(path: conditional.path)]).install(into: config)
            } else {
                try ConfigLayer.install([.file(conditional)], into: config)
            }
        }
        func value() throws -> String? {
            var entry: UnsafeMutablePointer<git_config_entry>?
            let result = git_config_get_entry(&entry, config, "test.value")
            if result == GIT_ENOTFOUND.rawValue { return nil }
            #expect(result == 0)
            defer { git_config_entry_free(entry) }
            return try #require(entry).pointee.value.map { String(cString: $0) }
        }
        try install()
        #expect(try value() == "Included")
        policy.paths = []
        try Data((text + "[test]\nchanged = yes\n").utf8).write(to: local, options: .atomic)
        policy.deniedPath = target.path
        var entry: UnsafeMutablePointer<git_config_entry>?
        #expect(git_config_get_entry(&entry, config, "test.value") < 0)
        git_config_entry_free(entry)
        #expect(policy.paths.contains(target.path))
        policy.deniedPath = nil
        #expect(try value() == "Included")

        // A hasconfig pre-scan must authorize lower includes using their own
        // repository, even though newly installed layers have no repository.
        // Malformed content proves a refusal happens before any parse.
        policy.paths = []
        policy.deniedPath = unconditional.path
        try Data("not valid config\n".utf8).write(to: unconditional, options: .atomic)
        let error = #expect(throws: Libgit2Error.self) {
            try CommandLineConfig([
                .includeIf(condition: "hasconfig:remote.*.url:never", path: target.path)
            ]).install(into: config)
        }
        #expect(error?.message == "include of '\(unconditional.path)' is not authorised")
        #expect(policy.paths.first == unconditional.path)
    }
}
#endif

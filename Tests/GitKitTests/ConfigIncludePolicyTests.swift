// Include authorisation — gated to Apple/Linux like the other suites that
// lay out repositories on disk.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

@Suite("Config include policy")
struct ConfigIncludePolicyTests {

    /// Records what a policy was asked.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [ConfigInclude] = []

        func record(_ include: ConfigInclude) {
            lock.lock(); defer { lock.unlock() }
            seen.append(include)
        }

        var includes: [ConfigInclude] {
            lock.lock(); defer { lock.unlock() }
            return seen
        }

        /// `name@depth from <includer>` per call, in order.
        var summary: [String] {
            includes.map {
                "\(URL(fileURLWithPath: $0.path).lastPathComponent)@\($0.depth)"
                    + " from \($0.includedFrom.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "?")"
            }
        }
    }

    /// A repository whose config includes `one` (which includes `nested`)
    /// and two `[includeIf]`s — `matching` applies here, `elsewhere` doesn't.
    private func makeRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigIncludePolicyTests-\(UUID().uuidString)")
        try Repository.initialize(at: dir)
        let git = dir.appendingPathComponent(".git")
        let url = git.appendingPathComponent("config")
        let config = try String(contentsOf: url, encoding: .utf8) + """
            [include]
            \tpath = one
            [includeIf "gitdir:**/.git"]
            \tpath = matching
            [includeIf "gitdir:/nowhere/"]
            \tpath = elsewhere

            """
        try config.write(to: url, atomically: true, encoding: .utf8)
        let files = [
            "one": "[include]\n\tpath = nested\n[test]\n\tone = 1\n",
            "nested": "[test]\n\tnested = 2\n",
            "matching": "[test]\n\tmatching = 3\n",
            "elsewhere": "[test]\n\telsewhere = 4\n"
        ]
        for (name, text) in files {
            try text.write(to: git.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return dir
    }

    @Test("the policy is asked once per include, nested ones and matching includeIf too")
    func askedForEachInclude() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = Recorder()

        let repo = try Repository.open(at: dir, includePolicy: ConfigIncludePolicy {
            recorder.record($0)
            return true
        })

        #expect(recorder.summary == [
            "one@1 from config", "nested@2 from one", "matching@1 from config"
        ])
        #expect(try repo.configGet("test.one") == "1")
        #expect(try repo.configGet("test.nested") == "2")
        #expect(try repo.configGet("test.matching") == "3")
        #expect(try repo.configGet("test.elsewhere") == nil)
    }

    @Test("a refused include fails the config load and its file is never read")
    func refusedIncludeIsNotRead() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = Recorder()

        let error = #expect(throws: Libgit2Error.self) {
            try Repository.open(at: dir, includePolicy: ConfigIncludePolicy {
                recorder.record($0)
                return !$0.path.hasSuffix("/one")
            })
        }

        #expect(error?.message.contains("include of") == true)
        #expect(error?.message.contains("/one' is not authorised") == true)
        // `one` was refused before it was read, so `nested` was never reached.
        #expect(recorder.summary == ["one@1 from config"])
    }

    @Test("a nested include can be refused on its own")
    func nestedIncludeRefused() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        let error = #expect(throws: Libgit2Error.self) {
            try Repository.open(at: dir, includePolicy: ConfigIncludePolicy {
                !$0.path.hasSuffix("/nested")
            })
        }

        #expect(error?.message.contains("/nested' is not authorised") == true)
    }

    @Test("a policy set after opening applies when the config is read again")
    func policySetAfterOpening() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try Repository.open(at: dir)
        #expect(try repo.configGet("test.one") == "1")

        let recorder = Recorder()
        try repo.setIncludePolicy(ConfigIncludePolicy {
            recorder.record($0)
            return false
        })
        // Changing the config makes libgit2 read it, includes and all, again.
        let url = dir.appendingPathComponent(".git/config")
        try (String(contentsOf: url, encoding: .utf8) + "[extra]\n\tkey = 1\n")
            .write(to: url, atomically: true, encoding: .utf8)

        #expect(throws: Libgit2Error.self) { try repo.configGet("extra.key") }
        #expect(recorder.summary.first == "one@1 from config")

        try repo.setIncludePolicy(nil)
        #expect(try repo.configGet("extra.key") == "1")
    }

    @Test("repositories in one process keep their own policies")
    func policiesAreIndependent() throws {
        let allowed = try makeRepo(), refused = try makeRepo(), unrestricted = try makeRepo()
        defer { for dir in [allowed, refused, unrestricted] { try? FileManager.default.removeItem(at: dir) } }

        let first = try Repository.open(at: allowed, includePolicy: ConfigIncludePolicy { _ in true })
        #expect(throws: Libgit2Error.self) {
            try Repository.open(at: refused, includePolicy: ConfigIncludePolicy { _ in false })
        }
        let third = try Repository.open(at: unrestricted)

        #expect(try first.configGet("test.nested") == "2")
        #expect(try third.configGet("test.nested") == "2")
    }

    @Test("with no policy installed includes are read as before")
    func noPolicy() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        let repo = try Repository.open(at: dir)

        #expect(try repo.configGet("test.nested") == "2")
        #expect(try repo.configGet("test.matching") == "3")
    }

    @Test("the process default applies to a repository without a policy of its own")
    func processDefault() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Process-wide, and other suites read configs concurrently: refuse
        // only this test's own repository.
        let marker = dir.lastPathComponent
        let recorder = Recorder()

        ConfigIncludePolicy.setDefault(ConfigIncludePolicy {
            guard $0.path.contains(marker) else { return true }
            recorder.record($0)
            return false
        })
        defer { ConfigIncludePolicy.setDefault(nil) }

        #expect(throws: Libgit2Error.self) { try Repository.open(at: dir) }
        #expect(recorder.summary == ["one@1 from config"])

        // A repository's own policy wins over the default.
        let repo = try Repository.open(at: dir, includePolicy: ConfigIncludePolicy { _ in true })
        #expect(try repo.configGet("test.nested") == "2")
    }

    @Test("a nested open from a policy callback leaves the outer thread policy in force")
    func nestedOpenRestoresThreadPolicy() throws {
        let outer = try makeRepo(), inner = try makeRepo()
        defer { for dir in [outer, inner] { try? FileManager.default.removeItem(at: dir) } }
        let recorder = Recorder()

        let error = #expect(throws: Libgit2Error.self) {
            try Repository.open(at: outer, includePolicy: ConfigIncludePolicy {
                recorder.record($0)
                if $0.path.hasSuffix("/one") {
                    _ = try? Repository.open(at: inner, includePolicy: ConfigIncludePolicy { _ in true })
                }
                return !$0.path.hasSuffix("/matching")
            })
        }

        // `matching` is read after the nested open and is still refused.
        #expect(error?.message.contains("/matching' is not authorised") == true)
    }

    @Test("replacing the process default while configs load doesn't free a policy in use")
    func replacingDefaultWhileLoading() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.lastPathComponent
        defer { ConfigIncludePolicy.setDefault(nil) }

        // Refuse only this test's repository, whichever policy is current.
        let make = { ConfigIncludePolicy { !$0.path.contains(marker) } }
        ConfigIncludePolicy.setDefault(make())

        let swapper = Task.detached {
            for _ in 0..<2000 { ConfigIncludePolicy.setDefault(make()) }
        }
        for _ in 0..<300 {
            #expect(throws: Libgit2Error.self) { try Repository.open(at: dir) }
        }
        await swapper.value
    }
}
#endif

// An operation's config levels reaching the repositories libgit2 opens for
// itself — fixtures are laid out with the system `git`, so, like the other
// submodule suites, this is gated to Apple/Linux.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

/// `Repository.withOperationConfiguration(_:_:)`, checked through real
/// native status and diff of a superproject: its submodules are opened by
/// libgit2 itself, never by the test.
@Suite("Operation configuration", .serialized)
struct OperationConfigurationTests {

    private let fixtures = TemporaryRepositories()

    private static let lf = Data("a\nb\n".utf8)
    private static let crlf = Data("a\r\nb\r\n".utf8)
    private static let autocrlf = OperationConfiguration.Level.entries(
        [ConfigEntry(name: "core.autocrlf", value: "true")])
    /// The host's system and XDG files left out, so that a test's own
    /// levels decide, whatever the machine's config says.
    private static let hostIsolated: [OperationConfiguration.Level] = [
        .entries([], .system, name: "isolated"), .entries([], .xdg, name: "isolated")
    ]
    /// No global level at all: the control for a test's global level.
    private static let noGlobal = OperationConfiguration(
        levels: hostIsolated + [.entries([], .global, name: "isolated")])

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    @discardableResult
    private func git(_ args: [String], in dir: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-c", "protocol.file.allow=always"] + args
        process.currentDirectoryURL = dir
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let error = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(description: "git \(args.joined(separator: " ")): \(String(decoding: error, as: UTF8.self))")
        }
        return String(decoding: output, as: UTF8.self)
    }

    private func makeRepo(_ name: String) throws -> URL {
        let dir = try fixtures.directory(name)
        try git(["init", "-q", "-b", "main"], in: dir)
        try git(["config", "user.email", "t@example.com"], in: dir)
        try git(["config", "user.name", "T"], in: dir)
        try git(["config", "core.autocrlf", "false"], in: dir)
        try Self.lf.write(to: dir.appendingPathComponent("plain.txt"))
        try git(["add", "plain.txt"], in: dir)
        try git(["commit", "-q", "-m", "init"], in: dir)
        return dir
    }

    private struct Fixture {
        let outer: URL
        /// outer/middle-sub/inner-sub: the checked-out leaf.
        let inner: URL
        let middle: URL
    }

    /// `outer` → `middle-sub` → `inner-sub`, initialised recursively, plus a
    /// registered `missing-sub` that is not initialised. The leaf's
    /// `plain.txt` is checked out with CRLF line endings — what
    /// `core.autocrlf=true` writes — and indexed so, while the leaf's own
    /// config says `core.autocrlf=false`. Its stat data no longer matches the
    /// index, so whoever compares it hashes it again under its config.
    private func makeFixture() throws -> Fixture {
        let leaf = try makeRepo("leaf-source")
        let middleSource = try makeRepo("middle-source")
        try git(["submodule", "add", "-q", leaf.path, "inner-sub"], in: middleSource)
        try git(["commit", "-q", "-m", "add inner-sub"], in: middleSource)

        let outer = try makeRepo("outer")
        try git(["submodule", "add", "-q", middleSource.path, "middle-sub"], in: outer)
        try git(["submodule", "add", "-q", leaf.path, "missing-sub"], in: outer)
        try git(["commit", "-q", "-m", "add submodules"], in: outer)
        try git(["submodule", "update", "-q", "--init", "--recursive"], in: outer)
        try git(["submodule", "deinit", "-q", "-f", "missing-sub"], in: outer)

        let middle = outer.appendingPathComponent("middle-sub")
        let inner = middle.appendingPathComponent("inner-sub")
        let plain = inner.appendingPathComponent("plain.txt")
        try Self.crlf.write(to: plain)
        try git(["-c", "core.autocrlf=true", "add", "plain.txt"], in: inner)
        try git(["config", "core.autocrlf", "false"], in: inner)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: plain.path)
        return Fixture(outer: outer, inner: inner, middle: middle)
    }

    /// Every config file and `.gitmodules` of the fixture, with its bytes.
    private func configBytes(_ fixture: Fixture, plus extra: [URL] = []) throws -> [String: Data] {
        var files = extra
        let gitDir = fixture.outer.appendingPathComponent(".git")
        let walk = FileManager.default.enumerator(at: gitDir, includingPropertiesForKeys: nil)
        while let url = walk?.nextObject() as? URL {
            if ["config", "config.worktree"].contains(url.lastPathComponent) { files.append(url) }
        }
        files += [fixture.outer, fixture.middle].map { $0.appendingPathComponent(".gitmodules") }
        var bytes: [String: Data] = [:]
        for file in files { bytes[file.path] = try Data(contentsOf: file) }
        return bytes
    }

    private func write(_ text: String, to name: String) throws -> URL {
        let url = fixtures.url(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test("status and diff hash a submodule's file under the operation's app level")
    func hiddenSubmoduleHandlesReadTheAppLevel() throws {
        defer { fixtures.removeAll() }
        let fixture = try makeFixture()
        let before = try configBytes(fixture)
        // Opened before the operation: only the opens libgit2 makes during
        // the status below can carry the level.
        let outer = try Repository.open(at: fixture.outer)

        // Control: the leaf's own `core.autocrlf=false` hashes CRLF as is.
        #expect(try outer.status().entries.map(\.path) == ["middle-sub"])
        #expect(try outer.diff(.workdirVsIndex, format: .nameOnly) == "middle-sub\n")

        let configuration = OperationConfiguration(levels: [Self.autocrlf])
        let report = try Repository.withOperationConfiguration(configuration) {
            try (outer.status(), outer.diff(.workdirVsIndex, format: .nameOnly))
        }
        #expect(report.0.isClean)
        #expect(report.1 == "")

        // The scope ended with the call: the leaf is dirty again.
        #expect(try outer.status().entries.map(\.path) == ["middle-sub"])
        #expect(try configBytes(fixture) == before)
    }

    @Test("a global level loses to the submodule's own config, as git's does")
    func globalLevelLosesToSubmoduleLocal() throws {
        defer { fixtures.removeAll() }
        let fixture = try makeFixture()
        let globalText = "[core]\n\tautocrlf = true\n"
        let global = try write(globalText, to: "global")
        let before = try configBytes(fixture, plus: [global])
        let outer = try Repository.open(at: fixture.outer)

        let configuration = OperationConfiguration(levels: Self.hostIsolated + [.file(global, .global)])
        let entries = try Repository.withOperationConfiguration(configuration) {
            try outer.status().entries.map(\.path)
        }
        #expect(entries == ["middle-sub"])
        #expect(try configBytes(fixture, plus: [global]) == before)

        // Without the leaf's local setting, the global level decides: with
        // no global level the leaf is dirty, with the operation's it is clean.
        try git(["config", "--unset", "core.autocrlf"], in: fixture.inner)
        let control = try Repository.withOperationConfiguration(Self.noGlobal) {
            try outer.status().entries.map(\.path)
        }
        #expect(control == ["middle-sub"])
        let clean = try Repository.withOperationConfiguration(configuration) {
            try outer.status().isClean
        }
        #expect(clean)
        #expect(try String(contentsOf: global, encoding: .utf8) == globalText)
    }

    @Test("an uninitialised submodule stays as it was and records nothing")
    func missingSubmoduleIsUnaffected() throws {
        defer { fixtures.removeAll() }
        let fixture = try makeFixture()
        let outer = try Repository.open(at: fixture.outer)
        let refuseAll = ConfigIncludePolicy { _ in false }

        let configuration = OperationConfiguration(levels: [Self.autocrlf], includePolicy: refuseAll)
        let report = try Repository.withOperationConfiguration(configuration) { try outer.status() }
        #expect(report.isClean)
        #expect(!report.entries.contains { $0.path == "missing-sub" })
    }

    @Test("an include refused in a submodule libgit2 opens itself is thrown")
    func refusedHiddenIncludeIsThrown() throws {
        defer { fixtures.removeAll() }
        let fixture = try makeFixture()
        let included = try write("[t]\n\tincluded = yes\n", to: "inner-include")
        try git(["config", "include.path", included.path], in: fixture.inner)
        let before = try configBytes(fixture)
        let outer = try Repository.open(at: fixture.outer)

        let seen = Recorded()
        let allowing = OperationConfiguration(
            levels: [Self.autocrlf],
            includePolicy: ConfigIncludePolicy { include in seen.append(include); return true })
        #expect(try Repository.withOperationConfiguration(allowing) { try outer.status().isClean })
        #expect(seen.includes.contains { $0.path == included.path && $0.depth == 1 })

        let refusing = OperationConfiguration(
            levels: [Self.autocrlf],
            includePolicy: ConfigIncludePolicy { $0.path != included.path })
        var reported = false
        let error = #expect(throws: Libgit2Error.self) {
            try Repository.withOperationConfiguration(refusing) {
                // libgit2 swallows the child's failed open: status returns.
                _ = try outer.status()
                reported = true
            }
        }
        #expect(reported)
        #expect(error?.message == "include of '\(included.path)' is not authorised")
        #expect(try configBytes(fixture) == before)
    }

    @Test("an include of the operation's global file is offered to the policy")
    func refusedIncludeOfOperationFile() throws {
        defer { fixtures.removeAll() }
        let fixture = try makeFixture()
        let included = try write("[core]\n\tautocrlf = true\n", to: "global-include")
        let global = try write("[include]\n\tpath = \(included.path)\n", to: "global")
        let outer = try Repository.open(at: fixture.outer)

        let allowing = OperationConfiguration(
            levels: Self.hostIsolated + [.file(global, .global)],
            includePolicy: ConfigIncludePolicy { _ in true })
        try git(["config", "--unset", "core.autocrlf"], in: fixture.inner)
        // Control: with no global level the leaf is dirty, so only the
        // included file can clean it.
        #expect(try Repository.withOperationConfiguration(Self.noGlobal) {
            try outer.status().entries.map(\.path)
        } == ["middle-sub"])
        #expect(try Repository.withOperationConfiguration(allowing) { try outer.status().isClean })

        let refusing = OperationConfiguration(
            levels: [.file(global, .global)],
            includePolicy: ConfigIncludePolicy { $0.path != included.path })
        let error = #expect(throws: Libgit2Error.self) {
            try Repository.withOperationConfiguration(refusing) { _ = try outer.status() }
        }
        #expect(error?.message == "include of '\(included.path)' is not authorised")
    }

    @Test("a failure GitKit already threw to the body is not thrown again")
    func reportedFailureIsNotThrownTwice() throws {
        defer { fixtures.removeAll() }
        let fixture = try makeFixture()
        let included = try write("[t]\n\tx = 1\n", to: "global-include")
        let global = try write("[include]\n\tpath = \(included.path)\n", to: "global")
        let configuration = OperationConfiguration(
            levels: [.file(global, .global)],
            includePolicy: ConfigIncludePolicy { $0.path != included.path })

        let caught = try Repository.withOperationConfiguration(configuration) { () -> Libgit2Error? in
            do {
                _ = try Repository.open(at: fixture.outer)
                return nil
            } catch let error as Libgit2Error {
                return error
            }
        }
        #expect(caught?.message == "include of '\(included.path)' is not authorised")
    }

    @Test("submodule sync writes each submodule's own config, not the operation's file")
    func syncWritesLocalConfigOnly() throws {
        defer { fixtures.removeAll() }
        let fixture = try makeFixture()
        let globalText = "[t]\n\thost = global\n"
        let global = try write(globalText, to: "global")
        let moved = fixtures.url("moved-leaf").path
        try git(["config", "--file", ".gitmodules", "submodule.inner-sub.url", moved], in: fixture.middle)
        let outer = try Repository.open(at: fixture.outer)

        let configuration = OperationConfiguration(levels: [
            .file(global, .global),
            .entries([ConfigEntry(name: "t.app", value: "1")])
        ])
        try Repository.withOperationConfiguration(configuration) {
            try outer.submoduleSync(recursive: true)
        }

        #expect(try git(["config", "--get", "submodule.inner-sub.url"], in: fixture.middle)
            .trimmingCharacters(in: .whitespacesAndNewlines) == moved)
        #expect(try git(["config", "--get", "remote.origin.url"], in: fixture.inner)
            .trimmingCharacters(in: .whitespacesAndNewlines) == moved)
        #expect(try String(contentsOf: global, encoding: .utf8) == globalText)
        for (path, data) in try configBytes(fixture) {
            let text = String(decoding: data, as: UTF8.self)
            #expect(!text.contains("app =") && !text.contains("host ="), "\(path)")
        }
    }

    @Test("scopes nest, end with their call and stay on their thread")
    func scopeLifecycle() throws {
        defer { fixtures.removeAll() }
        let dir = try fixtures.directory("repo")
        _ = try Repository.initialize(at: dir, initialBranch: "main")
        func probe() throws -> String? { try Repository.open(at: dir).configGet("gitkit.probe") }
        func level(_ value: String) -> OperationConfiguration {
            OperationConfiguration(levels: [.entries([ConfigEntry(name: "gitkit.probe", value: value)])])
        }

        let seen = try Repository.withOperationConfiguration(level("outer")) { () -> [String?] in
            var seen = [try probe()]
            seen.append(try Repository.withOperationConfiguration(level("inner")) { try probe() })
            seen.append(try probe())
            #expect(throws: Libgit2Error.self) {
                try Repository.withOperationConfiguration(level("thrown")) {
                    throw Libgit2Error(code: -1, klass: 0, message: "body")
                }
            }
            seen.append(try probe())

            // Another thread opening meanwhile sees none of it.
            let other = Recorded()
            let done = DispatchSemaphore(value: 0)
            let path = dir
            Thread {
                other.value = Result { try Repository.open(at: path).configGet("gitkit.probe") }
                done.signal()
            }.start()
            done.wait()
            seen.append(try #require(other.value).get())
            return seen
        }
        #expect(seen == ["outer", "inner", "outer", "outer", nil])
        #expect(try probe() == nil)

        // A repository opened in the scope keeps the level after it.
        let kept = try Repository.withOperationConfiguration(level("kept")) { try Repository.open(at: dir) }
        #expect(try kept.configGet("gitkit.probe") == "kept")
        #expect(kept.addedConfigLevels == [.app])
    }

    @Test("a global level opened in the scope is the explicit global scope; writes stay local")
    func writesStayLocal() throws {
        defer { fixtures.removeAll() }
        let dir = try fixtures.directory("repo")
        _ = try Repository.initialize(at: dir, initialBranch: "main")
        let globalText = "[t]\n\thost = global\n"
        let global = try write(globalText, to: "global")

        let configuration = OperationConfiguration(levels: [.file(global, .global)])
        let repo = try Repository.withOperationConfiguration(configuration) { () -> Repository in
            let repo = try Repository.open(at: dir)
            try repo.configSet("t.local", "1")
            return repo
        }
        #expect(try repo.configGet("t.host", scope: .global) == "global")
        #expect(try String(contentsOf: global, encoding: .utf8) == globalText)
        let local = try String(contentsOf: dir.appendingPathComponent(".git/config"), encoding: .utf8)
        #expect(local.contains("[t]") && !local.contains("host"))
    }

    @Test("a nested scope replaces only the levels it names")
    func nestedScopeKeepsOuterLevels() throws {
        defer { fixtures.removeAll() }
        let fixture = try makeFixture()
        let global = try write("[core]\n\tautocrlf = true\n[t]\n\thost = outer\n", to: "global")
        try git(["config", "--unset", "core.autocrlf"], in: fixture.inner)
        let outer = try Repository.open(at: fixture.outer)
        func probe(_ name: String) throws -> String? {
            try Repository.open(at: fixture.outer).configGet(name)
        }

        let outerScope = OperationConfiguration(levels: Self.hostIsolated + [
            .file(global, .global),
            .entries([ConfigEntry(name: "t.app", value: "outer")])
        ])
        let systemOnly = OperationConfiguration(levels: [
            .entries([ConfigEntry(name: "t.system", value: "inner")], .system, name: "inner")
        ])
        let emptyGlobal = OperationConfiguration(levels: [.entries([], .global, name: "inner")])
        try Repository.withOperationConfiguration(outerScope) { () throws in
            try Repository.withOperationConfiguration(systemOnly) { () throws in
                #expect(try probe("t.host") == "outer")
                #expect(try probe("t.app") == "outer")
                #expect(try probe("t.system") == "inner")
                // The leaf libgit2 opens itself still reads the outer global.
                #expect(try outer.status().isClean)
            }
            try Repository.withOperationConfiguration(emptyGlobal) { () throws in
                #expect(try probe("t.host") == nil)
                #expect(try probe("t.app") == "outer")
                #expect(try outer.status().entries.map(\.path) == ["middle-sub"])
            }
            #expect(try outer.status().isClean)
        }
    }

    @Test("a file level and its includes cannot change a repository's format or layout")
    func fileLevelsSkipRepositoryOnlySettings() throws {
        defer { fixtures.removeAll() }
        let fixture = try makeFixture()
        let elsewhere = try fixtures.directory("elsewhere")
        let included = try write(
            "[core]\n\tworktree = \(elsewhere.path)\n\tautocrlf = true\n[t]\n\tincluded = yes\n",
            to: "global-include")
        let global = try write("[include]\n\tpath = \(included.path)\n", to: "global")
        // At the app level, over each repository's own config: libgit2
        // would open every repository bare, or refuse its format.
        let app = try write(
            "[core]\n\tbare = true\n\trepositoryformatversion = 1\n"
                + "[extensions]\n\tgitkitbogus = yes\n[t]\n\tapp = yes\n",
            to: "app")
        try git(["config", "--unset", "core.autocrlf"], in: fixture.inner)
        let outer = try Repository.open(at: fixture.outer)

        let configuration = OperationConfiguration(
            levels: Self.hostIsolated + [.file(global, .global), .file(app, .app)],
            includePolicy: ConfigIncludePolicy { _ in true })
        try Repository.withOperationConfiguration(configuration) { () throws in
            let repo = try Repository.open(at: fixture.outer)
            #expect(repo.workdirURL?.resolvingSymlinksInPath().path
                == fixture.outer.resolvingSymlinksInPath().path)
            #expect(try repo.configGet("core.bare") == "false")
            #expect(try repo.configGet("core.repositoryformatversion") == "0")
            #expect(try repo.configGet("core.worktree") == nil)
            #expect(try repo.configGet("extensions.gitkitbogus") == nil)
            // The levels' other settings are read, the include's too.
            #expect(try repo.configGet("t.app") == "yes")
            #expect(try repo.configGet("t.included") == "yes")
            // The submodules libgit2 opens itself keep their worktrees and
            // read the included core.autocrlf.
            #expect(try outer.status().isClean)
        }
    }

    @Test("settings git reads from the repository's own config are refused")
    func repositoryOnlySettingsAreRefused() throws {
        for name in ["core.repositoryformatversion", "core.bare", "core.worktree",
                     "extensions.objectFormat", "Extensions.worktreeConfig"] {
            let configuration = OperationConfiguration(levels: [.entries([ConfigEntry(name: name, value: "1")])])
            var ran = false
            let error = #expect(throws: Libgit2Error.self) {
                try Repository.withOperationConfiguration(configuration) { ran = true }
            }
            #expect(!ran)
            #expect(error?.code == GIT_EINVALIDSPEC.rawValue)
        }
        // A subsection of the same name is an ordinary entry.
        let allowed = OperationConfiguration(levels: [.entries([ConfigEntry(name: "core.x.bare", value: "1")])])
        #expect(try Repository.withOperationConfiguration(allowed) { true })
    }
}

/// Collects what callbacks on other threads saw.
private final class Recorded: @unchecked Sendable {
    private let lock = NSLock()
    private var _includes: [ConfigInclude] = []
    private var _value: Result<String?, Error>?

    var includes: [ConfigInclude] { lock.withLock { _includes } }
    func append(_ include: ConfigInclude) { lock.withLock { _includes.append(include) } }

    var value: Result<String?, Error>? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
#endif

// Prepared clone and worktree creation — gated to Apple/Linux like the other
// suites that lay out repositories on disk. Fixtures are built with GitKit
// itself; no `git` process runs.
#if os(macOS) || os(Linux)
import Foundation
import Testing
import CGitKit
@testable import GitKit

/// A preparation sees the repository a clone or `worktreeAdd` creates before
/// its first checkout, so operation-only config decides the bytes written.
@Suite("Repository preparation before the first checkout", .serialized)
struct RepositoryPreparationTests {

    private let fixtures = TemporaryRepositories()

    private static let lf = Data("a\nb\n".utf8)
    private static let crlf = Data("a\r\nb\r\n".utf8)

    private struct PreparationFailed: Error, Equatable {
        let id = UUID()
    }

    /// Counts smudges per path, from any thread.
    final class SmudgeProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String: Int] = [:]
        private var workdirs: Set<String> = []

        func record(_ source: GitFilterSource) {
            lock.lock(); defer { lock.unlock() }
            paths[source.path, default: 0] += 1
            if let workdir = source.workingDirectory { workdirs.insert(Self.real(workdir)) }
        }

        var counts: [String: Int] {
            lock.lock(); defer { lock.unlock() }
            return paths
        }

        var workingDirectories: Set<String> {
            lock.lock(); defer { lock.unlock() }
            return workdirs
        }

        static func real(_ url: URL) -> String {
            url.resolvingSymlinksInPath().standardizedFileURL.path
        }
    }

    // MARK: Fixtures

    /// A repository whose `text.txt` holds `a\nb\n`, with `core.autocrlf`
    /// off on disk.
    private func makeSource(attributes: String? = nil) throws -> (URL, Repository) {
        let dir = try fixtures.directory("source")
        let repo = try Repository.initialize(at: dir, initialBranch: "main")
        try repo.configSet("user.name", "T")
        try repo.configSet("user.email", "t@example.com")
        try repo.configSet("core.autocrlf", "false")
        try Self.lf.write(to: dir.appendingPathComponent("text.txt"))
        if let attributes {
            try Data(attributes.utf8).write(to: dir.appendingPathComponent(".gitattributes"))
        }
        try repo.add(paths: [])
        _ = try repo.commitDetailed(
            message: "initial", author: Signature(name: "T", email: "t@example.com"),
            allowEmpty: false, env: [:], sign: .noSign)
        return (dir, repo)
    }

    /// What a host does: give the repository's live config an operation-only,
    /// read-only level above the files, as `GIT_CONFIG_COUNT` would.
    static func installOperationConfig(_ text: String, into repository: Repository) throws {
        var config: OpaquePointer?
        try check(git_repository_config(&config, repository.repo))
        defer { git_config_free(config) }
        var backend: UnsafeMutablePointer<git_config_backend>?
        try text.withCString { cText in
            try "operation".withCString { type in
                var options = git_config_backend_memory_options()
                options.version = UInt32(GIT_CONFIG_BACKEND_MEMORY_OPTIONS_VERSION)
                options.backend_type = type
                try check(git_config_backend_from_string(&backend, cText, text.utf8.count, &options))
            }
        }
        try check(git_config_add_backend(config, backend, GIT_CONFIG_LEVEL_APP, repository.repo, 0))
    }

    private static let autocrlf = "[core]\n\tautocrlf = true\n"

    private static func contents(of dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    private static func silent(_: String) {}

    // MARK: Clone

    @Test("a prepared clone writes its first checkout with the prepared config")
    func preparedCloneFirstMaterialization() throws {
        defer { fixtures.removeAll() }
        let (source, _) = try makeSource()
        let target = fixtures.url("clone")
        var prepared: Repository?

        let clone = try Repository.clone(
            fromRemote: source.path, to: target, progress: Self.silent,
            preparation: RepositoryPreparation { repository in
                prepared = repository
                // Before origin, the fetch, the index and every file.
                #expect(try Self.contents(of: target) == [".git"])
                #expect(!FileManager.default.fileExists(
                    atPath: target.appendingPathComponent(".git/index").path))
                #expect(try repository.remoteURL(named: "origin") == nil)
                try Self.installOperationConfig(Self.autocrlf, into: repository)
            })

        #expect(try Data(contentsOf: target.appendingPathComponent("text.txt")) == Self.crlf)
        #expect(clone === prepared)
        #expect(try clone.configGet("core.autocrlf") == "true")
        #expect(try clone.status().isClean)
        // The operation's config stayed off disk; the clone's own went there.
        let onDisk = try String(contentsOf: target.appendingPathComponent(".git/config"), encoding: .utf8)
        #expect(!onDisk.contains("autocrlf"))
        #expect(onDisk.contains("[remote \"origin\"]"))
        #expect(onDisk.contains("[branch \"main\"]"))
    }

    @Test("a prepared clone smudges each file once, in the prepared repository")
    func preparedCloneSmudgesOnce() throws {
        defer { fixtures.removeAll() }
        let driver = "probe-\(UUID().uuidString)"
        let probe = SmudgeProbe()
        try GitFilters.register(name: driver, smudge: { source, _ in
            probe.record(source)
            return nil
        })
        defer { try? GitFilters.unregister(name: driver) }
        let (source, _) = try makeSource(attributes: "*.txt filter=\(driver)\n")
        let target = fixtures.url("clone")

        let clone = try Repository.clone(
            fromRemote: source.path, to: target, progress: Self.silent,
            preparation: RepositoryPreparation { try Self.installOperationConfig(Self.autocrlf, into: $0) })

        #expect(probe.counts == ["text.txt": 1])
        #expect(probe.workingDirectories == [SmudgeProbe.real(try #require(clone.workdirURL))])
        #expect(try Data(contentsOf: target.appendingPathComponent("text.txt")) == Self.crlf)
    }

    @Test("a throwing preparation removes the clone it created, rethrowing its error")
    func throwingPreparationRemovesNewDirectory() throws {
        defer { fixtures.removeAll() }
        let (source, _) = try makeSource()
        let target = fixtures.url("clone")
        let failure = PreparationFailed()
        var kept: Repository?

        #expect(throws: failure) {
            try Repository.clone(
                fromRemote: source.path, to: target, progress: Self.silent,
                preparation: RepositoryPreparation { repository in
                    kept = repository
                    throw failure
                })
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        // GitKit freed the handle; the kept reference knows, and its deinit
        // frees nothing.
        #expect(kept?.isValid == false)
        kept = nil
    }

    @Test("a throwing preparation empties, but keeps, a directory that was there")
    func throwingPreparationKeepsExistingRoot() throws {
        defer { fixtures.removeAll() }
        let (source, _) = try makeSource()
        let target = try fixtures.directory("clone")

        #expect(throws: CancellationError.self) {
            try Repository.clone(
                fromRemote: source.path, to: target, progress: Self.silent,
                preparation: RepositoryPreparation { _ in throw CancellationError() })
        }
        #expect(try Self.contents(of: target) == [])
    }

    @Test("a directory with content is refused before anything is prepared or removed")
    func nonEmptyTargetIsLeftAlone() throws {
        defer { fixtures.removeAll() }
        let (source, _) = try makeSource()
        let target = try fixtures.directory("clone")
        try Data("mine\n".utf8).write(to: target.appendingPathComponent("keep.txt"))
        var prepared = false

        #expect(throws: Libgit2Error.self) {
            try Repository.clone(
                fromRemote: source.path, to: target, progress: Self.silent,
                preparation: RepositoryPreparation { _ in prepared = true })
        }
        #expect(!prepared)
        #expect(try Self.contents(of: target) == ["keep.txt"])
    }

    @Test("a clone failing after its preparation invalidates a kept repository")
    func failureAfterPreparation() throws {
        defer { fixtures.removeAll() }
        let (source, _) = try makeSource()
        let target = fixtures.url("clone")
        let existing = try fixtures.directory("existing")
        var kept: [Repository] = []

        for directory in [target, existing] {
            #expect(throws: Libgit2Error.self) {
                try Repository.clone(
                    fromRemote: source.path, to: directory, branch: "does-not-exist",
                    progress: Self.silent,
                    preparation: RepositoryPreparation { repository in
                        try repository.setIncludePolicy(ConfigIncludePolicy { _ in true })
                        kept.append(repository)
                    })
            }
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try Self.contents(of: existing) == [])
        #expect(kept.count == 2)
        #expect(kept.allSatisfy { !$0.isValid && $0.includePolicy == nil })
        kept.removeAll()
    }

    @Test("an include policy the preparation installs governs the clone and stays on the result")
    func includePolicyDuringClone() throws {
        defer { fixtures.removeAll() }
        let (source, _) = try makeSource()
        let extra = fixtures.url("extra.config")
        try "[test]\n\textra = 1\n".write(to: extra, atomically: true, encoding: .utf8)
        let asked = ConfigIncludePolicyTests.Recorder()
        let policy = ConfigIncludePolicy { asked.record($0); return true }
        var askedWhilePreparing = 0

        let clone = try Repository.clone(
            fromRemote: source.path, to: fixtures.url("clone"), progress: Self.silent,
            preparation: RepositoryPreparation { repository in
                try repository.setIncludePolicy(policy)
                try repository.configSet("include.path", extra.path)
                askedWhilePreparing = asked.includes.count
            })

        // The clone rewrote the config (origin, branch) and read the include
        // again with the policy in force, then handed it back to the result.
        #expect(asked.includes.count > askedWhilePreparing)
        #expect(clone.includePolicy != nil)
        #expect(try clone.configGet("test.extra") == "1")

        // Neither a thread policy nor a registration outlives the clone.
        let other = try fixtures.directory("other")
        try Repository.initialize(at: other)
        let otherConfig = other.appendingPathComponent(".git/config")
        try (try String(contentsOf: otherConfig, encoding: .utf8) + "[include]\n\tpath = \(extra.path)\n")
            .write(to: otherConfig, atomically: true, encoding: .utf8)
        let afterClone = asked.includes.count
        #expect(try Repository.open(at: other).configGet("test.extra") == "1")
        #expect(asked.includes.count == afterClone)
    }

    @Test("an unprepared clone is unchanged: its checkout follows its own config")
    func defaultCloneUnchanged() throws {
        defer { fixtures.removeAll() }
        let (source, _) = try makeSource()
        let target = fixtures.url("clone")

        let clone = try Repository.clone(fromRemote: source.path, to: target, progress: Self.silent)

        // Whatever the host's global config says, nothing operation-only.
        let expected = try clone.configGet("core.autocrlf") == "true" ? Self.crlf : Self.lf
        #expect(try Data(contentsOf: target.appendingPathComponent("text.txt")) == expected)
        #expect(clone.isValid)
    }

    // MARK: Worktree

    @Test("a prepared worktree writes its first checkout with the prepared config")
    func preparedWorktreeFirstMaterialization() throws {
        defer { fixtures.removeAll() }
        let (source, primary) = try makeSource()
        let path = fixtures.url("linked")
        let commonDir = SmudgeProbe.real(source.appendingPathComponent(".git"))
        var prepared: Repository?

        let worktree = try primary.worktreeAdd(
            path: path, branch: "feature",
            preparation: RepositoryPreparation { repository in
                prepared = repository
                let gitDir = URL(fileURLWithPath: String(cString: git_repository_path(repository.repo)))
                let common = URL(fileURLWithPath: String(cString: git_repository_commondir(repository.repo)))
                #expect(SmudgeProbe.real(gitDir) == commonDir + "/worktrees/linked")
                #expect(SmudgeProbe.real(common) == commonDir)
                #expect(!FileManager.default.fileExists(atPath: gitDir.appendingPathComponent("index").path))
                #expect(try Self.contents(of: path) == [".git"])
                try Self.installOperationConfig(Self.autocrlf, into: repository)
            })

        #expect(worktree === prepared)
        #expect(try Data(contentsOf: path.appendingPathComponent("text.txt")) == Self.crlf)
        #expect(try worktree.configGet("core.autocrlf") == "true")
        #expect(try primary.configGet("core.autocrlf") == "false")
        #expect(try worktree.currentBranch() == "feature")
        #expect(try worktree.status().isClean)
        #expect(try primary.linkedWorktreeList().map(\.name) == ["linked"])
    }

    @Test("a prepared worktree smudges each file once, in the worktree")
    func preparedWorktreeSmudgesOnce() throws {
        defer { fixtures.removeAll() }
        let driver = "probe-\(UUID().uuidString)"
        let probe = SmudgeProbe()
        try GitFilters.register(name: driver, smudge: { source, _ in
            probe.record(source)
            return nil
        })
        defer { try? GitFilters.unregister(name: driver) }
        let (_, primary) = try makeSource(attributes: "*.txt filter=\(driver)\n")
        let path = fixtures.url("linked")
        let before = probe.counts

        try primary.worktreeAdd(
            path: path, branch: "feature",
            preparation: RepositoryPreparation { try Self.installOperationConfig(Self.autocrlf, into: $0) })

        #expect(before.isEmpty)
        #expect(probe.counts == ["text.txt": 1])
        #expect(probe.workingDirectories == [SmudgeProbe.real(path)])
    }

    @Test("a throwing preparation prunes the worktree and deletes the branch it created")
    func throwingWorktreePreparationCreatedBranch() throws {
        defer { fixtures.removeAll() }
        let (source, primary) = try makeSource()
        let path = fixtures.url("linked")
        let failure = PreparationFailed()

        #expect(throws: failure) {
            try primary.worktreeAdd(
                path: path, branch: "feature",
                preparation: RepositoryPreparation { _ in throw failure })
        }
        #expect(!FileManager.default.fileExists(atPath: path.path))
        #expect(!FileManager.default.fileExists(
            atPath: source.appendingPathComponent(".git/worktrees/linked").path))
        #expect(try primary.localBranches() == ["main"])
        #expect(try primary.linkedWorktreeList().isEmpty)
    }

    @Test("a throwing preparation keeps a branch that was there")
    func throwingWorktreePreparationExistingBranch() throws {
        defer { fixtures.removeAll() }
        let (_, primary) = try makeSource()
        try primary.worktreeAdd(path: fixtures.url("first"), branch: "feature")
        try primary.worktreeRemove(name: "first")
        let path = fixtures.url("linked")

        #expect(throws: CancellationError.self) {
            try primary.worktreeAdd(
                path: path, branch: "feature",
                preparation: RepositoryPreparation { _ in throw CancellationError() })
        }
        #expect(!FileManager.default.fileExists(atPath: path.path))
        #expect(try primary.localBranches().sorted() == ["feature", "main"])
        #expect(try primary.linkedWorktreeList().isEmpty)
    }

    @Test("force reaches the deferred checkout")
    func forceReachesDeferredCheckout() throws {
        defer { fixtures.removeAll() }
        let (_, primary) = try makeSource()
        // An untracked file where the checkout wants to write: only force
        // overwrites it.
        let collide = RepositoryPreparation { repository in
            let file = try #require(repository.workdirURL).appendingPathComponent("text.txt")
            try Data("theirs\n".utf8).write(to: file)
        }

        let safe = fixtures.url("safe")
        #expect(throws: Libgit2Error.self) {
            try primary.worktreeAdd(path: safe, branch: "safe", preparation: collide)
        }
        #expect(!FileManager.default.fileExists(atPath: safe.path))
        #expect(try primary.localBranches() == ["main"])

        let forced = fixtures.url("forced")
        try primary.worktreeAdd(path: forced, branch: "forced", force: true, preparation: collide)
        #expect(try Data(contentsOf: forced.appendingPathComponent("text.txt")) == Self.lf)
    }

    @Test("an unprepared worktreeAdd is unchanged: its checkout follows the on-disk config")
    func defaultWorktreeUnchanged() throws {
        defer { fixtures.removeAll() }
        let (_, primary) = try makeSource()
        let path = fixtures.url("linked")

        try primary.worktreeAdd(path: path, branch: "feature")

        #expect(try Data(contentsOf: path.appendingPathComponent("text.txt")) == Self.lf)
        #expect(try primary.linkedWorktreeList().map(\.name) == ["linked"])
    }

    @Test("single-branch default-branch discovery uses the prepared config")
    func singleBranchDiscoveryUsesPreparedConfig() throws {
        defer { fixtures.removeAll() }
        let (source, _) = try makeSource()
        let alias = "gitkit-alias-\(UUID().uuidString):"
        let rewrite = "[url \"\(source.path)\"]\n\tinsteadOf = \(alias)\n"

        let clone = try Repository.clone(
            fromRemote: alias, to: fixtures.url("clone"), singleBranch: true, progress: Self.silent,
            preparation: RepositoryPreparation { try Self.installOperationConfig(rewrite, into: $0) })

        #expect(try clone.currentBranch() == "main")
        #expect(try clone.configGet("remote.origin.url") == alias)
    }

    @Test("this repository's include policy covers libgit2's own open of the new worktree")
    func includePolicyCoversNativeWorktreeOpen() throws {
        defer { fixtures.removeAll() }
        let (source, _) = try makeSource()
        let secret = fixtures.url("secret.config")
        try "[test]\n\tsecret = 1\n".write(to: secret, atomically: true, encoding: .utf8)
        let config = source.appendingPathComponent(".git/config")
        try (try String(contentsOf: config, encoding: .utf8)
            + "[includeIf \"gitdir:**/worktrees/linked\"]\n\tpath = \(secret.path)\n")
            .write(to: config, atomically: true, encoding: .utf8)
        let asked = ConfigIncludePolicyTests.Recorder()
        let primary = try Repository.open(at: source, includePolicy: ConfigIncludePolicy {
            asked.record($0)
            return true
        })
        var askedBeforePreparing = 0

        try primary.worktreeAdd(
            path: fixtures.url("linked"), branch: "feature",
            preparation: RepositoryPreparation { _ in
                askedBeforePreparing = asked.includes.filter { $0.path == secret.path }.count
            })

        // Once for libgit2's own open inside `git_worktree_add`, once for
        // the open that hands the worktree to the preparation.
        #expect(askedBeforePreparing == 2)
    }

    @Test("a failed native add removes only what it created and frees its name")
    func nativeAddFailureRollsBack() throws {
        defer { fixtures.removeAll() }
        let (source, primary) = try makeSource()
        let occupied = try fixtures.directory("occupied/linked")
        try Data("mine\n".utf8).write(to: occupied.appendingPathComponent("keep.txt"))
        let admin = source.appendingPathComponent(".git/worktrees")

        for preparation in [nil, RepositoryPreparation { _ in }] {
            #expect(throws: Libgit2Error.self) {
                if let preparation {
                    try primary.worktreeAdd(path: occupied, branch: "feature", preparation: preparation)
                } else {
                    try primary.worktreeAdd(path: occupied, branch: "feature")
                }
            }
            #expect(try Self.contents(of: occupied) == ["keep.txt"])
            #expect(!FileManager.default.fileExists(atPath: admin.path))
            #expect(try primary.localBranches() == ["main"])
        }

        let path = fixtures.url("linked")
        try primary.worktreeAdd(path: path, branch: "feature", preparation: RepositoryPreparation { _ in })
        #expect(try primary.linkedWorktreeList().map(\.name) == ["linked"])
    }

    @Test("an administrative directory left by an incomplete add is skipped, not reused")
    func staleAdministrativeDirectoryIsSkipped() throws {
        defer { fixtures.removeAll() }
        let (source, primary) = try makeSource()
        let stale = source.appendingPathComponent(".git/worktrees/linked")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)

        let worktree = try primary.worktreeAdd(
            path: fixtures.url("linked"), branch: "feature", preparation: RepositoryPreparation { _ in })

        #expect(try primary.linkedWorktreeList().map(\.name) == ["linked1"])
        #expect(try Self.contents(of: stale) == [])
        #expect(try worktree.currentBranch() == "feature")
    }

    // MARK: Retained handle

    @Test("using a kept clone repository after the clone failed stops the process")
    func keptRepositoryStopsAfterFailure() async throws {
        // The child stops before any cleanup of its own could run: this
        // process owns the fixtures and removes them.
        defer { fixtures.removeAll() }
        let root = try fixtures.directory("exit-test").path
        let result = await #expect(
            processExitsWith: .failure, observing: [\.standardErrorContent]
        ) { [root = root as String] in
            let base = URL(fileURLWithPath: root, isDirectory: true)
            let source = base.appendingPathComponent("source")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let repo = try Repository.initialize(at: source, initialBranch: "main")
            try Data("a\n".utf8).write(to: source.appendingPathComponent("a.txt"))
            try repo.add(paths: [])
            _ = try repo.commitDetailed(
                message: "initial", author: Signature(name: "T", email: "t@example.com"),
                allowEmpty: false, env: ["GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@example.com"],
                sign: .noSign)
            var kept: Repository?
            _ = try? Repository.clone(
                fromRemote: source.path, to: base.appendingPathComponent("clone"), branch: "does-not-exist",
                progress: { _ in }, preparation: RepositoryPreparation { kept = $0 })
            // Only a kept, invalidated repository gets this far.
            guard let kept, !kept.isValid else { return }
            _ = kept.workdirURL
        }
        let stderr = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
        #expect(stderr.contains("Repository used after the clone that created it failed"))
    }
}
#endif

#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

// Registration is process-wide. Serial execution keeps one test's unregister
// from racing a filter list that another test has already loaded.
@Suite("Custom clean/smudge filters", .serialized)
struct GitFiltersTests {
    private let fixtures = TemporaryRepositories()
    private let name = "upper-\(UUID().uuidString)"

    private enum TestError: Error { case failed }

    @discardableResult
    private func git(_ args: [String], in dir: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        process.environment = env
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Libgit2Error(code: -1, klass: 0, message: String(decoding: data, as: UTF8.self))
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func makeRepo(content: Data = Data("hello\n".utf8)) throws -> (URL, Repository) {
        let dir = try fixtures.directory("repo")
        try git(["init", "-b", "main"], in: dir)
        try git(["config", "user.name", "T"], in: dir)
        try git(["config", "user.email", "t@example.com"], in: dir)
        try git(["config", "commit.gpgsign", "false"], in: dir)
        try Data("*.txt -text filter=\(name)\n".utf8).write(to: dir.appendingPathComponent(".gitattributes"))
        try content.write(to: dir.appendingPathComponent("a.txt"))
        try git(["add", "."], in: dir)
        try git(["commit", "-m", "initial"], in: dir)
        return (dir, try Repository.open(at: dir))
    }

    private func requireDriver(in dir: URL) throws {
        try git(["config", "filter.\(name).required", "true"], in: dir)
    }

    private func restore(_ repo: Repository, in dir: URL) throws {
        let file = dir.appendingPathComponent("a.txt")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        try repo.checkoutPaths(["a.txt"])
    }

    private func expectFailure(
        _ direction: GitFilterDirection, reason: GitFilterError.Reason? = nil,
        underlying: Bool = false, _ operation: () throws -> Void
    ) {
        do {
            try operation()
            Issue.record("expected a filter failure")
        } catch let error as GitFilterError {
            #expect(error.driver == name)
            #expect(error.path == "a.txt")
            #expect(error.direction == direction)
            if let reason { #expect(error.reason == reason) }
            if underlying { #expect(error.underlying is TestError) }
        } catch { Issue.record(error, "expected GitFilterError") }
    }

    @Test("Checkout smudges, status cleans, and add/commit stores cleaned bytes")
    func roundTrip() throws {
        defer { fixtures.removeAll() }
        let (dir, repo) = try makeRepo()
        try git(["checkout", "--orphan", "empty"], in: dir)
        try git(["rm", "-rf", "."], in: dir)
        try git(["commit", "--allow-empty", "-m", "empty"], in: dir)
        try GitFilters.register(name: name, clean: { source, input in
            #expect(source.direction == .clean)
            return Data(String(decoding: input, as: UTF8.self).lowercased().utf8)
        }, smudge: { source, input in
            #expect(source.driver.hasPrefix("upper-"))
            #expect(source.direction == .smudge)
            #expect(source.path == "a.txt")
            #expect(source.objectID?.count == 40)
            #expect(source.gitDirectory.lastPathComponent == ".git")
            #expect(source.workingDirectory?.lastPathComponent == "repo")
            return Data(String(decoding: input, as: UTF8.self).uppercased().utf8)
        })
        defer { try? GitFilters.unregister(name: name) }
        try repo.checkout(ref: "main")
        #expect(try Data(contentsOf: dir.appendingPathComponent("a.txt")) == Data("HELLO\n".utf8))
        #expect(try repo.status().isClean)
        try Data("EDITED\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try repo.add(paths: ["a.txt"])
        _ = try repo.commitDetailed(message: "edit", author: Signature(name: "T", email: "t@example.com"),
                                    allowEmpty: false, sign: .noSign)
        #expect(try git(["cat-file", "-p", "HEAD:a.txt"], in: dir) == "edited\n")
    }

    /// The lock permits @Sendable factories to report observations across the
    /// operation boundary without sharing mutable stream state between files.
    private final class Observations: @unchecked Sendable {
        private let lock = NSLock()
        private var sizes: [Int] = []
        func record(_ count: Int) {
            lock.lock(); defer { lock.unlock() }
            sizes.append(count)
        }
        var chunks: [Int] {
            lock.lock(); defer { lock.unlock() }
            return sizes
        }
    }

    private final class CopyStream: GitFilterStream {
        let output: GitFilterOutput
        let observations: Observations
        init(_ output: GitFilterOutput, _ observations: Observations) {
            self.output = output
            self.observations = observations
        }
        func write(_ chunk: UnsafeRawBufferPointer) throws {
            observations.record(chunk.count)
            try output.write(chunk)
        }
        func close() throws {}
    }

    @Test("Clean receives bounded chunks for a multi-megabyte file")
    func streamingClean() throws {
        defer { fixtures.removeAll() }
        let (dir, repo) = try makeRepo()
        let observations = Observations()
        try GitFilters.register(name: name, GitFilter(clean: { _, output in CopyStream(output, observations) }))
        defer { try? GitFilters.unregister(name: name) }
        let bytes = Data(repeating: 65, count: 4 * 1024 * 1024 + 17)
        try bytes.write(to: dir.appendingPathComponent("a.txt"))
        try repo.add(paths: ["a.txt"])
        #expect(observations.chunks.count > 1)
        #expect(observations.chunks.allSatisfy { $0 <= 65_536 })
        #expect(observations.chunks.reduce(0, +) == bytes.count)
        #expect(try git(["rev-parse", ":a.txt"], in: dir) == git(["hash-object", "--no-filters", "a.txt"], in: dir))
    }

    private final class ExpandStream: GitFilterStream {
        let output: GitFilterOutput
        let observations: Observations
        private var pointer = Data()
        init(_ output: GitFilterOutput, _ observations: Observations) {
            self.output = output
            self.observations = observations
        }
        func write(_ chunk: UnsafeRawBufferPointer) throws { pointer.append(contentsOf: chunk) }
        func close() throws {
            #expect(pointer == Data("expand 8388608\n".utf8))
            let chunk = Data(repeating: 88, count: 65_536)
            for _ in 0..<128 {
                observations.record(chunk.count)
                try output.write(chunk)
            }
        }
    }

    @Test("Smudge expands a small pointer into 8 MiB of streamed output")
    func streamingSmudge() throws {
        defer { fixtures.removeAll() }
        let (dir, repo) = try makeRepo(content: Data("expand 8388608\n".utf8))
        let observations = Observations()
        try GitFilters.register(name: name, GitFilter(smudge: { _, output in ExpandStream(output, observations) }))
        defer { try? GitFilters.unregister(name: name) }
        try restore(repo, in: dir)
        let bytes = try Data(contentsOf: dir.appendingPathComponent("a.txt"))
        #expect(bytes.count == 8 * 1024 * 1024)
        #expect(bytes.allSatisfy { $0 == 88 })
        #expect(observations.chunks.count == 128)
        #expect(observations.chunks.allSatisfy { $0 == 65_536 })
    }

    @Test("Required buffered errors preserve the Swift error on checkout and add")
    func requiredFailures() throws {
        defer { fixtures.removeAll() }
        let (dir, repo) = try makeRepo()
        try requireDriver(in: dir)
        try GitFilters.register(name: name, clean: { _, _ in throw TestError.failed },
                                smudge: { _, _ in throw TestError.failed })
        defer { try? GitFilters.unregister(name: name) }
        expectFailure(.smudge, underlying: true) { try restore(repo, in: dir) }
        try Data("edit\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        expectFailure(.clean, underlying: true) { try repo.add(paths: ["a.txt"]) }
    }

    @Test("Optional buffered errors fall back to original input")
    func optionalFailure() throws {
        defer { fixtures.removeAll() }
        let (dir, repo) = try makeRepo()
        try GitFilters.register(name: name, clean: { _, _ in throw TestError.failed },
                                smudge: { _, _ in throw TestError.failed })
        defer { try? GitFilters.unregister(name: name) }
        try restore(repo, in: dir)
        #expect(try Data(contentsOf: dir.appendingPathComponent("a.txt")) == Data("hello\n".utf8))
        try Data("raw edit\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try repo.add(paths: ["a.txt"])
        #expect(try git(["cat-file", "-p", ":a.txt"], in: dir) == "raw edit\n")
    }

    enum FailureStage: Sendable, CaseIterable { case factory, write, close }

    private final class FailingStream: GitFilterStream {
        let output: GitFilterOutput
        let stage: FailureStage
        let observations: Observations
        init(_ output: GitFilterOutput, stage: FailureStage, observations: Observations) {
            self.output = output
            self.stage = stage
            self.observations = observations
        }
        func write(_ chunk: UnsafeRawBufferPointer) throws {
            observations.record(chunk.count)
            try output.write(chunk)
            if stage == .write { throw TestError.failed }
        }
        func close() throws {
            observations.record(-1)
            throw TestError.failed
        }
    }

    @Test("Optional streaming failures propagate from factory, write, and close", arguments: FailureStage.allCases)
    func streamingFailures(stage: FailureStage) throws {
        defer { fixtures.removeAll() }
        let (dir, repo) = try makeRepo()
        let observations = Observations()
        try GitFilters.register(name: name, GitFilter(smudge: { _, output in
            if stage == .factory { throw TestError.failed }
            return FailingStream(output, stage: stage, observations: observations)
        }))
        defer { try? GitFilters.unregister(name: name) }
        expectFailure(.smudge, underlying: true) { try restore(repo, in: dir) }
        switch stage {
        case .factory: #expect(observations.chunks.isEmpty)
        case .write: #expect(observations.chunks == [6]) // close is skipped after failure.
        case .close: #expect(observations.chunks == [6, -1])
        }
    }

    @Test("Custom attribute expressions match a required driver and respect priority")
    func attributesAndPriority() throws {
        defer { fixtures.removeAll() }
        let (dir, repo) = try makeRepo()
        try requireDriver(in: dir)
        let driver = name
        let first = name + "-first"
        let second = name + "-second"
        let appendA: GitFilter.BufferedTransform = { source, input in
            #expect(source.driver == driver)
            return input + Data("A".utf8)
        }
        let appendB: GitFilter.BufferedTransform = { source, input in
            #expect(source.driver == driver)
            return input + Data("B".utf8)
        }
        try GitFilters.register(name: second, attributes: "filter=\(name)", priority: 201,
                                clean: appendB, smudge: appendB)
        defer { try? GitFilters.unregister(name: second) }
        try GitFilters.register(name: first, attributes: "filter=\(name)", priority: 200,
                                clean: appendA, smudge: appendA)
        defer { try? GitFilters.unregister(name: first) }
        try restore(repo, in: dir)
        #expect(try Data(contentsOf: dir.appendingPathComponent("a.txt")) == Data("hello\nAB".utf8))
        try Data("raw\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try repo.add(paths: ["a.txt"])
        #expect(try git(["cat-file", "-p", ":a.txt"], in: dir) == "raw\nBA")
    }

    @Test("Source driver respects attributes loaded from HEAD")
    func attributesFromHEAD() throws {
        defer { fixtures.removeAll() }
        let (dir, repo) = try makeRepo()
        try git(["rm", ".gitattributes"], in: dir)
        let driver = name
        let registeredName = name + "-registration"
        try GitFilters.register(name: registeredName, attributes: "filter=*", smudge: { source, input in
            #expect(source.driver == driver)
            return input
        })
        defer { try? GitFilters.unregister(name: registeredName) }
        var filters: OpaquePointer?
        try check(git_filter_list_load(&filters, repo.repo, nil, "a.txt", GIT_FILTER_TO_WORKTREE,
                                      GIT_FILTER_ATTRIBUTES_FROM_HEAD.rawValue))
        defer { git_filter_list_free(filters) }
        #expect(filters != nil)
        var result = git_buf()
        defer { git_buf_dispose(&result) }
        try check(git_filter_list_apply_to_buffer(&result, filters, "hello\n", 6))
        #expect(result.size == 6)
    }

    @Test("The guard rejects missing required drivers, but permits optional ones")
    func missingRequired() throws {
        defer { fixtures.removeAll() }
        let (dir, repo) = try makeRepo()
        try GitFilters.enforceRequiredDrivers()
        try GitFilters.enforceRequiredDrivers()
        try requireDriver(in: dir)
        expectFailure(.smudge, reason: .requiredDriverMissing) { try restore(repo, in: dir) }
        try Data("raw\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        expectFailure(.clean, reason: .requiredDriverMissing) { try repo.add(paths: ["a.txt"]) }
        try git(["config", "filter.\(name).required", "false"], in: dir)
        try restore(repo, in: dir)
        #expect(try Data(contentsOf: dir.appendingPathComponent("a.txt")) == Data("hello\n".utf8))
    }

    @Test("A registration whose custom attributes do not select the driver remains missing")
    func nonmatchingRegistrationIsMissing() throws {
        defer { fixtures.removeAll() }
        let (dir, repo) = try makeRepo()
        try requireDriver(in: dir)
        try GitFilters.register(name: name, attributes: "large", clean: { _, input in input },
                                smudge: { _, input in input })
        defer { try? GitFilters.unregister(name: name) }
        expectFailure(.smudge, reason: .requiredDriverMissing) { try restore(repo, in: dir) }
        try Data("raw\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        expectFailure(.clean, reason: .requiredDriverMissing) { try repo.add(paths: ["a.txt"]) }
    }

    @Test("A missing direction is optional passthrough, but fails when required")
    func missingDirection() throws {
        defer { fixtures.removeAll() }
        let (dir, repo) = try makeRepo()
        try GitFilters.register(name: name, smudge: { _, data in data })
        defer { try? GitFilters.unregister(name: name) }
        try Data("raw\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try repo.add(paths: ["a.txt"])
        #expect(try git(["cat-file", "-p", ":a.txt"], in: dir) == "raw\n")
        try requireDriver(in: dir)
        expectFailure(.clean) { try repo.add(paths: ["a.txt"]) }
    }

    @Test("Factories and buffered transforms can choose passthrough")
    func passthrough() throws {
        defer { fixtures.removeAll() }
        let (dir, repo) = try makeRepo()
        try GitFilters.register(name: name, GitFilter(smudge: { source, _ in
            #expect(source.path == "a.txt")
            return nil
        }))
        defer { try? GitFilters.unregister(name: name) }
        try restore(repo, in: dir)
        #expect(try Data(contentsOf: dir.appendingPathComponent("a.txt")) == Data("hello\n".utf8))
        try GitFilters.unregister(name: name)
        try GitFilters.register(name: name, clean: { _, _ in nil }, smudge: { _, _ in nil })
        try restore(repo, in: dir)
        try repo.add(paths: ["a.txt"])
        #expect(try repo.status().isClean)
    }

    @Test("Duplicate registration, unregister, and re-registration")
    func lifecycle() throws {
        defer { fixtures.removeAll() }
        let (dir, repo) = try makeRepo()
        try GitFilters.register(name: name, smudge: { _, _ in Data("changed\n".utf8) })
        defer { try? GitFilters.unregister(name: name) }
        #expect(GitFilters.isRegistered(name))
        #expect(throws: Libgit2Error.self) { try GitFilters.register(name: name, GitFilter()) }
        try restore(repo, in: dir)
        #expect(try Data(contentsOf: dir.appendingPathComponent("a.txt")) == Data("changed\n".utf8))
        try GitFilters.unregister(name: name)
        #expect(!GitFilters.isRegistered(name))
        #expect(throws: Libgit2Error.self) { try GitFilters.unregister(name: name) }
        try restore(repo, in: dir)
        #expect(try Data(contentsOf: dir.appendingPathComponent("a.txt")) == Data("hello\n".utf8))
        try GitFilters.register(name: name, GitFilter())
    }

    @Test("Unregister preserves an already loaded filter list")
    func unregisterLoadedFilterList() throws {
        defer { fixtures.removeAll() }
        let (_, repo) = try makeRepo()
        let observations = Observations()
        try GitFilters.register(name: name, GitFilter(smudge: { _, output in
            CopyStream(output, observations)
        }))
        defer { try? GitFilters.unregister(name: name) }

        var filters: OpaquePointer?
        try check(git_filter_list_load(&filters, repo.repo, nil, "a.txt", GIT_FILTER_TO_WORKTREE, 0))
        defer { git_filter_list_free(filters) }
        #expect(filters != nil)
        try GitFilters.unregister(name: name)

        var result = git_buf()
        defer { git_buf_dispose(&result) }
        try check(git_filter_list_apply_to_buffer(&result, filters, "hello\n", 6))
        #expect(!GitFilters.isRegistered(name))
        #expect(result.size == 6)
        #expect(observations.chunks == [6])
    }
}
#endif

import Foundation
import Testing
@testable import GitKit

@Suite("Temporary repository cleanup")
struct TemporaryRepositoriesTests {
    enum Exit: CaseIterable, Sendable {
        case success, setupFailure, bodyFailure, earlyReturn
    }

    struct Failure: Error {}

    @Test("removes repositories, copies and partial setup on every exit", arguments: Exit.allCases)
    func removesFixtures(exit: Exit) throws {
        let fixtures = TemporaryRepositories()
        // Also clean up if a regression makes the assertions below fail.
        defer { fixtures.removeAll() }

        func run() throws {
            defer { fixtures.removeAll() }
            let seed = try fixtures.directory("seed")
            try Data("partial setup".utf8).write(to: seed.appendingPathComponent("file"))
            if exit == .setupFailure { throw Failure() }
            let repo = try Repository.initialize(at: seed, initialBranch: "main")
            #expect(try repo.currentBranch() == nil)
            let copy = fixtures.url("copy")
            try FileManager.default.copyItem(at: seed, to: copy)
            #expect(FileManager.default.fileExists(atPath: copy.appendingPathComponent(".git").path))
            if exit == .earlyReturn { return }
            if exit == .bodyFailure { throw Failure() }
        }

        if exit == .setupFailure || exit == .bodyFailure {
            #expect(throws: Failure.self) { try run() }
        } else {
            try run()
        }
        #expect(!FileManager.default.fileExists(atPath: fixtures.root.path))
        fixtures.removeAll() // Cleanup is safe before setup and after removal.
    }
}

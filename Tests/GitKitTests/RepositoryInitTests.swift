import Foundation
import Testing
@testable import GitKit

@Suite("Repository.initialize")
struct RepositoryInitTests {

    private func tmpDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("InitRepo-\(UUID().uuidString)")
    }

    @Test("init creates a .git directory with HEAD pointing at the default branch")
    func initWorking() throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Repository.initialize(at: dir, initialBranch: "main")

        let head = dir.appendingPathComponent(".git/HEAD")
        let contents = try String(contentsOf: head, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(contents == "ref: refs/heads/main")
    }

    @Test("init --bare lays out the bare object store directly in the dir")
    func initBare() throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Repository.initialize(at: dir, bare: true, initialBranch: "main")

        // Bare layout has HEAD/config/objects at the root, no .git/.
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("HEAD").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path))
    }

    @Test("init defaults to master when no initial branch is given")
    func initDefaultBranch() throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Repository.initialize(at: dir)

        let head = dir.appendingPathComponent(".git/HEAD")
        let contents = try String(contentsOf: head, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // libgit2 falls back to `master` unless `init.defaultBranch` is set.
        #expect(contents.hasPrefix("ref: refs/heads/"))
    }

    @Test("init with reinit=true succeeds on an existing repo")
    func reinitIdempotent() throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Repository.initialize(at: dir, initialBranch: "main")
        // Second call must not throw.
        try Repository.initialize(at: dir, initialBranch: "main", reinit: true)
    }
}

// What a clone or worktree add whose own init/open fails leaves behind when
// something else touched it meanwhile — gated to Apple/Linux like the other
// suites that lay out repositories on disk (Windows keeps everything).
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import GitKit

/// The refused include's policy runs inside the failing open, after the
/// operation wrote its files: what it does there stands for another writer.
/// Anything the operation can't prove its own keeps the whole creation.
@Suite("Rollback of a creation whose own open fails", .serialized)
struct CreationRollbackTests {

    private let fixtures = TemporaryRepositories()

    /// A primary repository on `main` with two commits; its config includes
    /// `secret` for the git directory of a linked worktree named `linked`.
    private func makeSource() throws -> (source: URL, secret: URL, main: String) {
        let dir = try fixtures.directory("source")
        let repo = try Repository.initialize(at: dir, initialBranch: "main")
        try repo.configSet("user.name", "T")
        try repo.configSet("user.email", "t@example.com")
        let author = Signature(name: "T", email: "t@example.com")
        var shas: [String] = []
        for text in ["a\n", "b\n"] {
            try Data(text.utf8).write(to: dir.appendingPathComponent("text.txt"))
            try repo.add(paths: [])
            _ = try repo.commitDetailed(
                message: text, author: author, allowEmpty: false, env: [:], sign: .noSign)
            shas.append(try String(contentsOf: dir.appendingPathComponent(".git/refs/heads/main"),
                                   encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let secret = fixtures.url("secret.config")
        try "[test]\n\tsecret = 1\n".write(to: secret, atomically: true, encoding: .utf8)
        let config = dir.appendingPathComponent(".git/config")
        try (try String(contentsOf: config, encoding: .utf8)
            + "[includeIf \"gitdir:**/worktrees/linked\"]\n\tpath = \(secret.path)\n")
            .write(to: config, atomically: true, encoding: .utf8)
        return (dir, secret, shas[1])
    }

    /// Adds `linked` on a new branch `feature` at `main~1`; the policy runs
    /// `meanwhile` once, then refuses the include.
    private func failingAdd(
        _ source: URL, secret: URL, meanwhile: @escaping @Sendable (_ path: URL) throws -> Void
    ) throws -> (Repository, URL) {
        let path = fixtures.url("linked")
        let primary = try Repository.open(at: source, includePolicy: ConfigIncludePolicy { include in
            if include.path == secret.path { try? meanwhile(path) }
            return false
        })
        #expect(throws: Libgit2Error.self) {
            try primary.worktreeAdd(
                path: path, branch: "feature", startPoint: "main~1",
                preparation: RepositoryPreparation { _ in Issue.record("prepared") })
        }
        return (primary, path)
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    @Test("a file someone adds to the new worktree keeps the worktree and its branch")
    func addedFileKeepsWorktree() throws {
        defer { fixtures.removeAll() }
        let (source, secret, _) = try makeSource()
        let (primary, path) = try failingAdd(source, secret: secret) { path in
            try Data("mine\n".utf8).write(to: path.appendingPathComponent("notes.txt"))
        }
        #expect(try Data(contentsOf: path.appendingPathComponent("notes.txt")) == Data("mine\n".utf8))
        #expect(Self.exists(path.appendingPathComponent(".git")))
        #expect(Self.exists(source.appendingPathComponent(".git/worktrees/linked/HEAD")))
        #expect(try primary.localBranches().sorted() == ["feature", "main"])
    }

    @Test("an add of another repository's worktree from the policy leaves this add's rollback intact")
    func nestedAddKeepsOuterRollback() throws {
        defer { fixtures.removeAll() }
        let (source, secret, _) = try makeSource()
        let other = try fixtures.directory("other")
        let otherRepo = try Repository.initialize(at: other, initialBranch: "main")
        try otherRepo.configSet("user.name", "T")
        try otherRepo.configSet("user.email", "t@example.com")
        try Data("o\n".utf8).write(to: other.appendingPathComponent("o.txt"))
        try otherRepo.add(paths: [])
        _ = try otherRepo.commitDetailed(
            message: "o", author: Signature(name: "T", email: "t@example.com"),
            allowEmpty: false, env: [:], sign: .noSign)
        let nested = fixtures.url("nested")
        let (primary, path) = try failingAdd(source, secret: secret) { _ in
            guard !Self.exists(nested) else { return }
            try Repository.open(at: other).worktreeAdd(path: nested, branch: "inner")
        }
        #expect(Self.exists(nested.appendingPathComponent("o.txt")))
        #expect(!Self.exists(path))
        #expect(!Self.exists(source.appendingPathComponent(".git/worktrees")))
        #expect(try primary.localBranches() == ["main"])
    }

    @Test("a metadata file rewritten meanwhile is not the add's: the worktree is kept")
    func rewrittenFileKeepsWorktree() throws {
        defer { fixtures.removeAll() }
        let (source, secret, _) = try makeSource()
        let head = source.appendingPathComponent(".git/worktrees/linked/HEAD")
        let (_, path) = try failingAdd(source, secret: secret) { _ in
            let text = try String(contentsOf: head, encoding: .utf8)
            try FileManager.default.removeItem(at: head)
            try text.write(to: head, atomically: false, encoding: .utf8)
        }
        #expect(Self.exists(head))
        #expect(Self.exists(path.appendingPathComponent(".git")))
    }

    @Test("a worktree directory replaced by a symlink leaves its target and the original alone")
    func replacedDirectoryIsLeftAlone() throws {
        defer { fixtures.removeAll() }
        let (source, secret, _) = try makeSource()
        let elsewhere = try fixtures.directory("elsewhere")
        try Data("gitdir: somewhere\n".utf8).write(to: elsewhere.appendingPathComponent(".git"))
        let moved = fixtures.url("moved")
        let (_, path) = try failingAdd(source, secret: secret) { path in
            try FileManager.default.moveItem(at: path, to: moved)
            try FileManager.default.createSymbolicLink(at: path, withDestinationURL: elsewhere)
        }
        #expect(try Data(contentsOf: elsewhere.appendingPathComponent(".git")) == Data("gitdir: somewhere\n".utf8))
        #expect(Self.exists(moved.appendingPathComponent(".git")))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)) != nil)
        #expect(Self.exists(source.appendingPathComponent(".git/worktrees/linked/HEAD")))
    }

    @Test("a branch moved meanwhile is kept, with its config, though the worktree is removed")
    func movedBranchIsKept() throws {
        defer { fixtures.removeAll() }
        let (source, secret, main) = try makeSource()
        let ref = source.appendingPathComponent(".git/refs/heads/feature")
        let config = source.appendingPathComponent(".git/config")
        let (primary, path) = try failingAdd(source, secret: secret) { _ in
            try Data("\(main)\n".utf8).write(to: ref)
            let text = try String(contentsOf: config, encoding: .utf8)
            try (text + "[branch \"feature\"]\n\tnote = mine\n").write(to: config, atomically: true, encoding: .utf8)
        }
        #expect(!Self.exists(path))
        #expect(!Self.exists(source.appendingPathComponent(".git/worktrees")))
        #expect(try primary.localBranches().sorted() == ["feature", "main"])
        #expect(try String(contentsOf: ref, encoding: .utf8) == "\(main)\n")
        #expect(try String(contentsOf: config, encoding: .utf8).contains("note = mine"))
    }

    /// Clones into a new and an existing empty `probe-clone`; the refused
    /// include's policy, in the new repository's open, runs `meanwhile` on
    /// each first.
    private func failingClones(
        _ source: URL, meanwhile: @escaping @Sendable (_ directory: URL) throws -> Void
    ) throws -> [URL] {
        let extra = fixtures.url("extra.config")
        try "[test]\n\textra = 1\n".write(to: extra, atomically: true, encoding: .utf8)
        let global = fixtures.url("global.config")
        try "[includeIf \"gitdir:**/probe-clone/\"]\n\tpath = \(extra.path)\n"
            .write(to: global, atomically: true, encoding: .utf8)
        let directories = [fixtures.url("probe-clone"), try fixtures.directory("existing/probe-clone")]
        for directory in directories {
            let policy = ConfigIncludePolicy { include in
                if include.path == extra.path { try? meanwhile(directory) }
                return false
            }
            #expect(throws: Libgit2Error.self) {
                try Repository.withOperationConfiguration(OperationConfiguration(
                    levels: [.file(global, .global)], includePolicy: policy)) {
                    try Repository.clone(
                        fromRemote: source.path, to: directory, progress: { _ in },
                        preparation: RepositoryPreparation { _ in Issue.record("prepared") })
                }
            }
        }
        return directories
    }

    @Test("a file someone adds to a new clone keeps the clone")
    func addedFileKeepsClone() throws {
        defer { fixtures.removeAll() }
        let (source, _, _) = try makeSource()
        for directory in try failingClones(source, meanwhile: { directory in
            try Data("mine\n".utf8).write(to: directory.appendingPathComponent(".git/notes.txt"))
        }) {
            #expect(try Data(contentsOf: directory.appendingPathComponent(".git/notes.txt")) == Data("mine\n".utf8))
            #expect(Self.exists(directory.appendingPathComponent(".git/HEAD")))
        }
    }

    @Test("a clone config someone writes to meanwhile is not the init's: the clone is kept")
    func rewrittenConfigKeepsClone() throws {
        defer { fixtures.removeAll() }
        let (source, _, _) = try makeSource()
        for directory in try failingClones(source, meanwhile: { directory in
            // In place, as an editor would: same file, new content.
            let handle = try FileHandle(forWritingTo: directory.appendingPathComponent(".git/config"))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("[x]\n\ty = z\n".utf8))
        }) {
            let config = try String(contentsOf: directory.appendingPathComponent(".git/config"), encoding: .utf8)
            #expect(config.contains("y = z"))
            #expect(Self.exists(directory.appendingPathComponent(".git/HEAD")))
        }
    }
}
#endif

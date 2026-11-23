// What a clone or worktree add whose own init/open fails leaves behind: all
// of it, once proven its own, so a retry succeeds; or, when something else
// touched it meanwhile, nothing. Runs on Windows too, where the rollback
// works by handle and file ID.
#if os(macOS) || os(Linux) || os(Windows)
import Foundation
import Testing
import CGitKit
@testable import GitKit
#if os(Windows)
import WinSDK
#endif

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
        // An `origin/main` to start a tracking branch from.
        try repo.configSet("remote.origin.url", dir.path)
        try repo.configSet("remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*")
        let tracking = dir.appendingPathComponent(".git/refs/remotes/origin/main")
        try FileManager.default.createDirectory(
            at: tracking.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("\(shas[1])\n".utf8).write(to: tracking)
        return (dir, secret, shas[1])
    }

    /// Adds `linked` on a new branch `feature` at `startPoint`; the policy runs
    /// `meanwhile` once, then refuses the include.
    private func failingAdd(
        _ source: URL, secret: URL, startPoint: String = "main~1",
        meanwhile: @escaping @Sendable (_ path: URL) throws -> Void
    ) throws -> (Repository, URL) {
        let path = fixtures.url("linked")
        let primary = try Repository.open(at: source, includePolicy: ConfigIncludePolicy { include in
            if Self.isFile(include.path, secret) { try? meanwhile(path) }
            return false
        })
        #expect(throws: Libgit2Error.self) {
            try primary.worktreeAdd(
                path: path, branch: "feature", startPoint: startPoint,
                preparation: RepositoryPreparation { _ in Issue.record("prepared") })
        }
        return (primary, path)
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Whether libgit2's spelling of an include path names `file` (on
    /// Windows it may be the long form of a short temporary directory).
    private static func isFile(_ path: String, _ file: URL) -> Bool {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)
            == file.lastPathComponent
    }

    private static func silent(_: String) {}

    // MARK: What the creation provably made goes

    @Test("a clone whose own init fails before the preparation removes what it created")
    func failedInitRemovesClone() throws {
        defer { fixtures.removeAll() }
        let (source, _, _) = try makeSource()
        try expectRetriableClone(from: source, into: [
            fixtures.url("probe-clone"), try fixtures.directory("existing/probe-clone")
        ])
    }

    @Test("a clone into a name outside the Basic Multilingual Plane is removed, and retried")
    func unicodeCloneIsRemoved() throws {
        defer { fixtures.removeAll() }
        let (source, _, _) = try makeSource()
        try expectRetriableClone(from: source, into: [
            fixtures.url("probe-clone-\u{FC}\u{6F22}\u{1F600}"),
            try fixtures.directory("existing/probe-clone-\u{FC}\u{6F22}\u{1F600}")
        ], pattern: "probe-clone-*")
    }

    #if os(Windows)
    @Test("a clone at a path longer than MAX_PATH is removed, and retried")
    func longPathCloneIsRemoved() throws {
        defer { fixtures.removeAll() }
        let (source, _, _) = try makeSource()
        let deep = String(repeating: "d", count: 120) + "/" + String(repeating: "e", count: 120)
        let target = fixtures.url("\(deep)/probe-clone")
        #expect(target.path.utf16.count > 260)
        try expectRetriableClone(from: source, into: [target])
    }
    #endif

    /// Clones into each of `directories` (new, or empty) twice: refused by
    /// the include policy in the new repository's own open, which removes
    /// what it made and keeps libgit2's error; then allowed, which succeeds.
    private func expectRetriableClone(
        from source: URL, into directories: [URL], pattern: String = "probe-clone"
    ) throws {
        let extra = fixtures.url("extra.config")
        try "[test]\n\textra = 1\n".write(to: extra, atomically: true, encoding: .utf8)
        // A level the new repository's open reads, with an include only that
        // repository's git directory matches.
        let global = fixtures.url("global.config")
        try "[includeIf \"gitdir:**/\(pattern)/\"]\n\tpath = \(extra.path)\n"
            .write(to: global, atomically: true, encoding: .utf8)
        var prepared = false
        func clone(into directory: URL, allowing: Bool) throws -> Repository {
            try Repository.withOperationConfiguration(OperationConfiguration(
                levels: [.file(global, .global)], includePolicy: ConfigIncludePolicy { _ in allowing })) {
                try Repository.clone(
                    fromRemote: source.path, to: directory, progress: Self.silent,
                    preparation: RepositoryPreparation { _ in prepared = true })
            }
        }
        let existed = directories.map(Self.exists)

        for directory in directories {
            let error = #expect(throws: Libgit2Error.self) { try clone(into: directory, allowing: false) }
            #expect(error?.message.contains("not authorised") == true)  // libgit2's own, as is
        }
        #expect(!prepared)
        for (directory, existed) in zip(directories, existed) {
            if existed {
                #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [])
            } else {
                #expect(!Self.exists(directory))
            }
        }

        for directory in directories {
            #expect(try clone(into: directory, allowing: true).configGet("test.extra") == "1")
        }
        #expect(prepared)
    }

    @Test("an add whose own open of the new worktree fails prunes it and the branch it created")
    func failedNativeOpenPrunesWorktree() throws {
        defer { fixtures.removeAll() }
        let (source, _, _) = try makeSource()
        let refusing = try Repository.open(at: source, includePolicy: ConfigIncludePolicy { _ in false })
        let path = fixtures.url("linked")
        let admin = source.appendingPathComponent(".git/worktrees")
        var prepared = false

        for preparation in [nil, RepositoryPreparation { _ in prepared = true }] {
            let error = #expect(throws: Libgit2Error.self) {
                if let preparation {
                    try refusing.worktreeAdd(path: path, branch: "feature", preparation: preparation)
                } else {
                    try refusing.worktreeAdd(path: path, branch: "feature")
                }
            }
            #expect(error?.message.contains("not authorised") == true)
            #expect(!Self.exists(path))
            #expect(!Self.exists(admin))
            #expect(try refusing.localBranches() == ["main"])
        }
        #expect(!prepared)

        let accepting = try Repository.open(at: source, includePolicy: ConfigIncludePolicy { _ in true })
        let worktree = try accepting.worktreeAdd(
            path: path, branch: "feature", preparation: RepositoryPreparation { _ in prepared = true })
        #expect(prepared)
        #expect(try accepting.linkedWorktreeList().map(\.name) == ["linked"])
        #expect(try worktree.configGet("test.secret") == "1")
    }

    // MARK: What it can't prove its own stays

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

    /// The inode of the directory `takeName` made, for the C hook.
    nonisolated(unsafe) private static var takenInode: UInt64 = 0

    /// Another writer making a directory at the working directory's name
    /// just before the kept worktree is renamed back there.
    private static let takeName: gitkit_created_restore_hook = { path in
        guard let path, String(cString: path).hasSuffix("/linked") else { return }
        let url = URL(fileURLWithPath: String(cString: path))
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try? Data("theirs\n".utf8).write(to: url.appendingPathComponent("theirs.txt"))
        #if !os(Windows)
        let inode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber]) as? UInt64
        takenInode = inode ?? 0
        #else
        takenInode = 1
        #endif
    }

    @Test("a directory that takes the kept worktree's name is not replaced by it")
    func takenNameIsNotReplaced() throws {
        defer { fixtures.removeAll() }
        let (source, secret, _) = try makeSource()
        let head = source.appendingPathComponent(".git/worktrees/linked/HEAD")
        Self.takenInode = 0
        gitkit_created_set_restore_hook(Self.takeName)
        defer { gitkit_created_set_restore_hook(nil) }
        let (_, path) = try failingAdd(source, secret: secret) { _ in
            // Something the add can't prove its own: the worktree is kept.
            let text = try String(contentsOf: head, encoding: .utf8)
            try FileManager.default.removeItem(at: head)
            try text.write(to: head, atomically: false, encoding: .utf8)
        }
        gitkit_created_set_restore_hook(nil)

        // The other writer's directory, as it made it.
        #expect(Self.takenInode != 0)
        #if !os(Windows)
        let inode = try FileManager.default.attributesOfItem(atPath: path.path)[.systemFileNumber] as? UInt64
        #expect(inode == Self.takenInode)
        #endif
        #expect(try FileManager.default.contentsOfDirectory(atPath: path.path) == ["theirs.txt"])
        // The worktree, kept whole under its private name; its git directory back.
        let parent = path.deletingLastPathComponent()
        let kept = try FileManager.default.contentsOfDirectory(atPath: parent.path)
            .filter { $0.hasPrefix(".linked.gitkit-rollback-") }
        #expect(kept.count == 1)
        #expect(kept.allSatisfy { Self.exists(parent.appendingPathComponent($0).appendingPathComponent(".git")) })
        #expect(Self.exists(head))
    }

    /// The working directory moved away while the add's open runs, and
    /// something else put in its place by `replace`.
    private func expectReplacedWorktreeLeftAlone(
        replace: @escaping @Sendable (_ path: URL, _ elsewhere: URL) throws -> Void,
        check: (_ path: URL) throws -> Void
    ) throws {
        let (source, secret, _) = try makeSource()
        let elsewhere = try fixtures.directory("elsewhere")
        try Data("gitdir: somewhere\n".utf8).write(to: elsewhere.appendingPathComponent(".git"))
        let moved = fixtures.url("moved")
        let (_, path) = try failingAdd(source, secret: secret) { path in
            try FileManager.default.moveItem(at: path, to: moved)
            try replace(path, elsewhere)
        }
        #expect(try Data(contentsOf: elsewhere.appendingPathComponent(".git")) == Data("gitdir: somewhere\n".utf8))
        #expect(Self.exists(moved.appendingPathComponent(".git")))
        #expect(Self.exists(source.appendingPathComponent(".git/worktrees/linked/HEAD")))
        try check(path)
    }

    @Test("a worktree directory replaced by another directory leaves both alone")
    func directoryReplacedByDirectoryIsLeftAlone() throws {
        defer { fixtures.removeAll() }
        try expectReplacedWorktreeLeftAlone(replace: { path, _ in
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
            try Data("gitdir: elsewhere\n".utf8).write(to: path.appendingPathComponent(".git"))
        }, check: { path in
            #expect((try? Data(contentsOf: path.appendingPathComponent(".git"))) == Data("gitdir: elsewhere\n".utf8))
        })
    }

    /// Whether this process may make symlinks (on Windows, that takes
    /// SeCreateSymbolicLinkPrivilege or Developer Mode).
    private static let symlinksAvailable: Bool = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitKitTests-symlink-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(
                at: dir.appendingPathComponent("link"), withDestinationURL: dir)
            return true
        } catch {
            return false
        }
    }()

    @Test("a worktree directory replaced by a symlink leaves its target and the original alone",
          .enabled(if: Self.symlinksAvailable, "this process may not create symlinks"))
    func replacedDirectoryIsLeftAlone() throws {
        defer { fixtures.removeAll() }
        try expectReplacedWorktreeLeftAlone(replace: { path, elsewhere in
            try FileManager.default.createSymbolicLink(at: path, withDestinationURL: elsewhere)
        }, check: { path in
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)) != nil)
        })
    }

    @Test("a metadata file hard-linked from elsewhere meanwhile is not the add's: the worktree is kept")
    func hardLinkedFileKeepsWorktree() throws {
        defer { fixtures.removeAll() }
        let (source, secret, _) = try makeSource()
        let head = source.appendingPathComponent(".git/worktrees/linked/HEAD")
        let link = fixtures.url("HEAD-link")
        let (_, path) = try failingAdd(source, secret: secret) { _ in
            try FileManager.default.linkItem(at: head, to: link)
        }
        #expect(Self.exists(head))
        #expect(Self.exists(path.appendingPathComponent(".git")))
        #expect(try Data(contentsOf: link) == (try Data(contentsOf: head)))
    }

    @Test("a metadata file renamed away and back meanwhile is not the add's: the worktree is kept")
    func renamedBackFileKeepsWorktree() throws {
        defer { fixtures.removeAll() }
        let (source, secret, _) = try makeSource()
        let head = source.appendingPathComponent(".git/worktrees/linked/HEAD")
        let aside = source.appendingPathComponent(".git/worktrees/linked/HEAD.aside")
        let (_, path) = try failingAdd(source, secret: secret) { _ in
            try FileManager.default.moveItem(at: head, to: aside)
            try FileManager.default.moveItem(at: aside, to: head)
        }
        #expect(Self.exists(head))
        #expect(Self.exists(path.appendingPathComponent(".git")))
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

    @Test("config someone writes for the created branch stays, though the branch is deleted")
    func foreignBranchConfigIsKept() throws {
        defer { fixtures.removeAll() }
        let (source, secret, _) = try makeSource()
        let config = source.appendingPathComponent(".git/config")
        let (primary, path) = try failingAdd(source, secret: secret) { _ in
            let text = try String(contentsOf: config, encoding: .utf8)
            try (text + "[branch \"feature\"]\n\tnote = mine\n").write(to: config, atomically: true, encoding: .utf8)
        }
        #expect(!Self.exists(path))
        #expect(try primary.localBranches() == ["main"])
        #expect(try primary.configGet("branch.feature.note") == "mine")
    }

    @Test("the upstream the add wrote goes with its branch; one changed meanwhile stays")
    func writtenUpstreamIsRemoved() throws {
        defer { fixtures.removeAll() }
        let (source, secret, _) = try makeSource()
        var (primary, _) = try failingAdd(source, secret: secret, startPoint: "origin/main") { _ in }
        #expect(try primary.localBranches() == ["main"])
        #expect(try primary.configGet("branch.feature.remote") == nil)
        #expect(try primary.configGet("branch.feature.merge") == nil)

        let config = source.appendingPathComponent(".git/config")
        (primary, _) = try failingAdd(source, secret: secret, startPoint: "origin/main") { _ in
            let text = try String(contentsOf: config, encoding: .utf8)
            try text.replacingOccurrences(of: "merge = refs/heads/main", with: "merge = refs/heads/other")
                .write(to: config, atomically: true, encoding: .utf8)
        }
        #expect(try primary.localBranches() == ["main"])
        #expect(try primary.configGet("branch.feature.remote") == nil)
        #expect(try primary.configGet("branch.feature.merge") == "refs/heads/other")
    }

    @Test("a branch deleted and made again under the same name meanwhile is kept, with its config")
    func recreatedBranchIsKept() throws {
        defer { fixtures.removeAll() }
        let (source, secret, main) = try makeSource()
        let ref = source.appendingPathComponent(".git/refs/heads/feature")
        let config = source.appendingPathComponent(".git/config")
        let (primary, path) = try failingAdd(source, secret: secret) { _ in
            try FileManager.default.removeItem(at: ref)
            try Data("\(main)\n".utf8).write(to: ref)
            let text = try String(contentsOf: config, encoding: .utf8)
            try (text + "[branch \"feature\"]\n\tnote = mine\n").write(to: config, atomically: true, encoding: .utf8)
        }
        #expect(!Self.exists(path))
        #expect(try primary.localBranches().sorted() == ["feature", "main"])
        #expect(try primary.configGet("branch.feature.note") == "mine")
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
                if Self.isFile(include.path, extra) { try? meanwhile(directory) }
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

    @Test("a clone HEAD someone replaces meanwhile, same text, is not the init's: the clone is kept")
    func replacedHeadKeepsClone() throws {
        defer { fixtures.removeAll() }
        let (source, _, _) = try makeSource()
        for directory in try failingClones(source, meanwhile: { directory in
            let head = directory.appendingPathComponent(".git/HEAD")
            let text = try String(contentsOf: head, encoding: .utf8)
            try FileManager.default.removeItem(at: head)
            try text.write(to: head, atomically: false, encoding: .utf8)
        }) {
            #expect(Self.exists(directory.appendingPathComponent(".git/HEAD")))
            #expect(Self.exists(directory.appendingPathComponent(".git/config")))
        }
    }
}

#if os(Windows)
// MARK: Windows: reparse points, streams and open handles

extension CreationRollbackTests {

    /// `path` as Win32 takes it: drive-letter, backslash-separated.
    private static func win32Path(_ url: URL) -> String {
        var path = url.path
        if path.hasPrefix("/"), path.dropFirst().dropFirst().first == ":" { path.removeFirst() }
        return path.replacingOccurrences(of: "/", with: "\\")
    }

    /// Opens `url` with Win32's CreateFileW; nil when it can't.
    private static func open(
        _ url: URL, access: DWORD, share: DWORD, disposition: DWORD, flags: DWORD = 0
    ) -> HANDLE? {
        let handle = win32Path(url).withCString(encodedAs: UTF16.self) {
            CreateFileW($0, access, share, nil, disposition, flags, nil)
        }
        return handle == INVALID_HANDLE_VALUE ? nil : handle
    }

    /// Makes `link` a directory junction (a mount-point reparse point) to
    /// `target`, as `mklink /J` does; no privilege needed.
    private static func makeJunction(at link: URL, to target: URL) throws {
        try FileManager.default.createDirectory(at: link, withIntermediateDirectories: false)
        let print = Array(win32Path(target).utf16)
        let substitute = Array("\\??\\".utf16) + print
        let names = substitute + [0] + print + [0]
        let dataLength = 8 + names.count * 2
        var buffer = [UInt8](repeating: 0, count: 8 + dataLength)
        func put16(_ value: Int, at offset: Int) {
            buffer[offset] = UInt8(value & 0xFF)
            buffer[offset + 1] = UInt8(value >> 8)
        }
        let tag: UInt32 = 0xA000_0003  // IO_REPARSE_TAG_MOUNT_POINT
        for index in 0..<4 { buffer[index] = UInt8((tag >> (8 * UInt32(index))) & 0xFF) }
        put16(dataLength, at: 4)
        put16(0, at: 8)                                  // SubstituteNameOffset
        put16(substitute.count * 2, at: 10)              // SubstituteNameLength
        put16((substitute.count + 1) * 2, at: 12)        // PrintNameOffset
        put16(print.count * 2, at: 14)                   // PrintNameLength
        for (index, unit) in names.enumerated() { put16(Int(unit), at: 16 + index * 2) }

        guard let handle = open(
            link, access: DWORD(GENERIC_WRITE), share: 0, disposition: DWORD(OPEN_EXISTING),
            flags: DWORD(FILE_FLAG_BACKUP_SEMANTICS) | DWORD(FILE_FLAG_OPEN_REPARSE_POINT))
        else { throw CocoaError(.fileWriteUnknown) }
        defer { CloseHandle(handle) }
        var returned: DWORD = 0
        let set = buffer.withUnsafeMutableBytes {
            DeviceIoControl(handle, 0x0009_00A4 /* FSCTL_SET_REPARSE_POINT */,
                            $0.baseAddress, DWORD($0.count), nil, 0, &returned, nil)
        }
        guard set else { throw CocoaError(.fileWriteUnknown) }
    }

    @Test("a worktree directory replaced by a junction leaves its target and the original alone")
    func directoryReplacedByJunctionIsLeftAlone() throws {
        defer { fixtures.removeAll() }
        try expectReplacedWorktreeLeftAlone(replace: { path, elsewhere in
            try Self.makeJunction(at: path, to: elsewhere)
        }, check: { path in
            let attributes = Self.win32Path(path).withCString(encodedAs: UTF16.self) { GetFileAttributesW($0) }
            #expect(attributes != INVALID_FILE_ATTRIBUTES
                    && attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0)
        })
    }

    @Test("an alternate data stream someone adds to a clone's config keeps the clone")
    func alternateStreamKeepsClone() throws {
        defer { fixtures.removeAll() }
        let (source, _, _) = try makeSource()
        for directory in try failingClones(source, meanwhile: { directory in
            let stream = URL(fileURLWithPath: directory.appendingPathComponent(".git/config").path + ":theirs")
            guard let handle = Self.open(
                stream, access: DWORD(GENERIC_WRITE), share: 0, disposition: DWORD(CREATE_NEW))
            else { throw CocoaError(.fileWriteUnknown) }
            defer { CloseHandle(handle) }
            var written: DWORD = 0
            _ = Array("mine\n".utf8).withUnsafeBytes {
                WriteFile(handle, $0.baseAddress, DWORD($0.count), &written, nil)
            }
        }) {
            let stream = URL(fileURLWithPath: directory.appendingPathComponent(".git/config").path + ":theirs")
            let handle = Self.open(stream, access: DWORD(GENERIC_READ),
                                   share: DWORD(FILE_SHARE_READ), disposition: DWORD(OPEN_EXISTING))
            #expect(handle != nil)
            if let handle { CloseHandle(handle) }
            #expect(Self.exists(directory.appendingPathComponent(".git/HEAD")))
        }
    }

    /// Handles a test holds open past the failing call.
    final class HeldHandles: @unchecked Sendable {
        private let lock = NSLock()
        private var handles: [HANDLE] = []

        func hold(_ handle: HANDLE) {
            lock.lock(); defer { lock.unlock() }
            handles.append(handle)
        }

        func closeAll() {
            lock.lock(); defer { lock.unlock() }
            handles.forEach { CloseHandle($0) }
            handles = []
        }
    }

    @Test("a file someone holds open in a clone across the failure keeps the clone, intact")
    func heldFileKeepsClone() throws {
        defer { fixtures.removeAll() }
        let (source, _, _) = try makeSource()
        let held = HeldHandles()
        defer { held.closeAll() }
        let directories = try failingClones(source, meanwhile: { directory in
            guard let handle = Self.open(
                directory.appendingPathComponent(".git/HEAD"), access: DWORD(GENERIC_READ),
                share: DWORD(FILE_SHARE_READ), disposition: DWORD(OPEN_EXISTING))
            else { throw CocoaError(.fileReadUnknown) }
            held.hold(handle)
        })
        held.closeAll()
        for directory in directories {
            #expect(try String(contentsOf: directory.appendingPathComponent(".git/HEAD"), encoding: .utf8)
                .hasPrefix("ref: refs/heads/"))
            #expect(Self.exists(directory.appendingPathComponent(".git/config")))
        }
    }
}
#endif
#endif

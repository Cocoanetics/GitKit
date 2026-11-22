import Foundation
import Testing
import CGitKit
@testable import GitKit

/// Complete on-disk snapshot of a repository's mutable state before and after
/// a `mergeTree` call: refs, `HEAD`, index bytes and mtime, working-tree files,
/// `MERGE_HEAD`, reflogs, and (optionally) loose objects, packs, and their mtimes.
struct RepositoryStateSnapshot: Equatable {
    struct FileState: Equatable {
        let data: Data
        let mtime: Date?
    }

    let headData: Data?
    let refs: [String: Data]
    let packedRefs: Data?
    let indexBytes: Data?
    let indexMtime: Date?
    let mergeHeadExists: Bool
    let reflogs: [String: Data]
    let worktreeFiles: [String: Data]
    let objects: [String: FileState]

    static func capture(
        repo: Repository,
        includeObjects: Bool = true
    ) throws -> RepositoryStateSnapshot {
        let fm = FileManager.default
        let gitDir = try #require(try repo.gitDir())
        let gitDirURL = URL(fileURLWithPath: gitDir, isDirectory: true)
        let commonDirURL = resolveCommonDir(from: gitDirURL)

        let headURL = gitDirURL.appendingPathComponent("HEAD")
        let headData = fm.fileExists(atPath: headURL.path) ? try Data(contentsOf: headURL) : nil

        let refs = try snapshotTree(under: commonDirURL.appendingPathComponent("refs"))
        let packedRefsURL = commonDirURL.appendingPathComponent("packed-refs")
        let packedRefs = fm.fileExists(atPath: packedRefsURL.path) ? try Data(contentsOf: packedRefsURL) : nil

        let indexURL = gitDirURL.appendingPathComponent("index")
        let indexBytes: Data?
        let indexMtime: Date?
        if fm.fileExists(atPath: indexURL.path) {
            indexBytes = try Data(contentsOf: indexURL)
            let attrs = try fm.attributesOfItem(atPath: indexURL.path)
            indexMtime = attrs[.modificationDate] as? Date
        } else {
            indexBytes = nil
            indexMtime = nil
        }

        let mergeHeadExists = fm.fileExists(atPath: gitDirURL.appendingPathComponent("MERGE_HEAD").path)

        var reflogs = try snapshotTree(under: commonDirURL.appendingPathComponent("logs"))
        if gitDirURL.standardizedFileURL != commonDirURL.standardizedFileURL {
            for (path, data) in try snapshotTree(under: gitDirURL.appendingPathComponent("logs")) {
                reflogs["worktree/\(path)"] = data
            }
        }

        let worktreeFiles: [String: Data]
        if let workdir = repo.workdirURL {
            worktreeFiles = try snapshotTree(under: workdir, skippingTopLevel: ".git")
        } else {
            worktreeFiles = [:]
        }

        let objects: [String: FileState]
        if includeObjects {
            objects = try snapshotFilesWithMtime(under: commonDirURL.appendingPathComponent("objects"))
        } else {
            objects = [:]
        }

        return RepositoryStateSnapshot(
            headData: headData,
            refs: refs,
            packedRefs: packedRefs,
            indexBytes: indexBytes,
            indexMtime: indexMtime,
            mergeHeadExists: mergeHeadExists,
            reflogs: reflogs,
            worktreeFiles: worktreeFiles,
            objects: objects)
    }

    private static func resolveCommonDir(from gitDirURL: URL) -> URL {
        let commondirFile = gitDirURL.appendingPathComponent("commondir")
        guard let raw = try? String(contentsOf: commondirFile, encoding: .utf8) else {
            return gitDirURL
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return gitDirURL }
        return URL(fileURLWithPath: trimmed, relativeTo: gitDirURL).standardizedFileURL
    }

    private static func snapshotTree(
        under root: URL,
        skippingTopLevel: String? = nil
    ) throws -> [String: Data] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [:] }
        let basePath = root.standardizedFileURL.path
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return [:]
        }
        var result: [String: Data] = [:]
        for case let fileURL as URL in enumerator {
            let rel = relativePath(of: fileURL, basePath: basePath)
            if let skip = skippingTopLevel, rel == skip || rel.hasPrefix("\(skip)/") {
                enumerator.skipDescendants()
                continue
            }
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                result[rel] = try Data(contentsOf: fileURL)
            }
        }
        return result
    }

    private static func snapshotFilesWithMtime(under root: URL) throws -> [String: FileState] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [:] }
        let basePath = root.standardizedFileURL.path
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return [:]
        }
        var result: [String: FileState] = [:]
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                let rel = relativePath(of: fileURL, basePath: basePath)
                let attrs = try fm.attributesOfItem(atPath: fileURL.path)
                result[rel] = FileState(
                    data: try Data(contentsOf: fileURL),
                    mtime: attrs[.modificationDate] as? Date)
            }
        }
        return result
    }

    private static func relativePath(of fileURL: URL, basePath: String) -> String {
        let full = fileURL.standardizedFileURL.path
        if full.hasPrefix(basePath + "/") {
            return String(full.dropFirst(basePath.count + 1))
        }
        return fileURL.lastPathComponent
    }
}

/// Native object-building helpers for merge-tree tests (zero external `git` CLI).
enum MergeTreeFixture {

    static let author = Signature(name: "Test Author", email: "test@example.com")

    static func initRepo(in fixtures: TemporaryRepositories, name: String = "repo") throws -> (URL, Repository) {
        let dir = fixtures.url(name)
        let repo = try Repository.initialize(at: dir, initialBranch: "main")
        try repo.configSet("user.name", "Test Author")
        try repo.configSet("user.email", "test@example.com")
        try repo.configSet("core.autocrlf", "false")
        return (dir, repo)
    }

    static func writeFile(_ data: Data, at relPath: String, in dir: URL) throws {
        let url = dir.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    static func writeText(_ text: String, at relPath: String, in dir: URL) throws {
        try writeFile(Data(text.utf8), at: relPath, in: dir)
    }

    @discardableResult
    static func commit(
        _ repo: Repository,
        in dir: URL,
        files: [String: Data],
        removing: [String] = [],
        message: String
    ) throws -> String {
        for (path, data) in files {
            try writeFile(data, at: path, in: dir)
        }
        if !removing.isEmpty {
            try repo.remove(paths: removing, keepWorktree: false, force: true)
        }
        if !files.isEmpty {
            try repo.add(paths: Array(files.keys))
        }
        return try repo.commitDetailed(
            message: message, author: author, allowEmpty: true, env: [:], sign: .noSign
        ).sha
    }

    @discardableResult
    static func commitText(
        _ repo: Repository,
        in dir: URL,
        files: [String: String],
        removing: [String] = [],
        message: String
    ) throws -> String {
        let dataFiles = files.mapValues { Data($0.utf8) }
        return try commit(repo, in: dir, files: dataFiles, removing: removing, message: message)
    }

    /// Creates a real native commit directly in the repository's ODB with the
    /// exact given file map (path -> (data, mode)) and parent commit OIDs,
    /// without touching HEAD, refs, the index, or the working tree.
    @discardableResult
    static func createNativeCommit(
        in repo: Repository,
        files: [String: (Data, UInt32)],
        parents: [String],
        message: String,
        timestamp: Int64 = 1_700_000_000
    ) throws -> (commit: String, tree: String) {
        let treeOID = try writeNativeTree(in: repo, files: files)

        var tree: OpaquePointer?
        var treeOIDCopy = treeOID
        try check(git_tree_lookup(&tree, repo.repo, &treeOIDCopy))
        defer { git_tree_free(tree) }

        var parentCommits: [OpaquePointer?] = []
        defer { parentCommits.forEach { git_commit_free($0) } }
        for parentHex in parents {
            var oid = git_oid()
            try check(git_oid_fromstr(&oid, parentHex))
            var commit: OpaquePointer?
            try check(git_commit_lookup(&commit, repo.repo, &oid))
            parentCommits.append(commit)
        }

        var sig: UnsafeMutablePointer<git_signature>?
        try check(git_signature_new(&sig, "Test Author", "test@example.com", timestamp, 0))
        defer { git_signature_free(sig) }

        var commitOID = git_oid()
        try parentCommits.withUnsafeMutableBufferPointer { buf in
            try check(git_commit_create(
                &commitOID, repo.repo, nil, sig, sig, "UTF-8", message, tree, buf.count, buf.baseAddress))
        }
        return (repo.formatOID(&commitOID), repo.formatOID(&treeOIDCopy))
    }

    static func writeNativeTree(
        in repo: Repository,
        files: [String: (Data, UInt32)]
    ) throws -> git_oid {
        var index: OpaquePointer?
        try check(git_index_new(&index))
        defer { git_index_free(index) }

        var odb: OpaquePointer?
        try check(git_repository_odb(&odb, repo.repo))
        defer { git_odb_free(odb) }

        for (path, (data, mode)) in files.sorted(by: { $0.key < $1.key }) {
            var blobOID = git_oid()
            try data.withUnsafeBytes { raw in
                try check(git_odb_write(&blobOID, odb, raw.baseAddress, raw.count, GIT_OBJECT_BLOB))
            }
            var entry = git_index_entry()
            entry.id = blobOID
            entry.mode = mode
            try path.withCString { cPath in
                entry.path = cPath
                try check(git_index_add(index, &entry))
            }
        }

        var treeOID = git_oid()
        try check(git_index_write_tree_to(&treeOID, index, repo.repo))
        return treeOID
    }
}

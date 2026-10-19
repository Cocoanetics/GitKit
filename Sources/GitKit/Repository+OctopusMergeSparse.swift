// A sparse checkout through an octopus merge, as unpack-trees keeps it:
// a path outside the sparse checkout gets its index entry, marked
// skip-worktree, and nothing in the work tree.
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif
import CGitKit

extension Repository {

    /// The cone-mode sparse-checkout patterns: directories taken whole,
    /// and directories whose own files only are taken. Files at the top
    /// are always in.
    struct SparseCone {
        var recursive: Set<String> = []
        var parents: Set<String> = []
        /// core.ignoreCase: directories compared as git's strcasecmp
        /// compares them, ASCII letters folded.
        var ignoreCase = false

        private func folded(_ text: String) -> String {
            guard ignoreCase else { return text }
            return String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
                ("A"..."Z").contains(scalar) ? Unicode.Scalar(scalar.value + 32)! : scalar
            }))
        }

        func includes(_ path: String) -> Bool {
            let path = folded(path)
            let dirs = path.split(separator: "/", omittingEmptySubsequences: false).dropLast()
            guard !dirs.isEmpty else { return true }
            var prefix = ""
            for dir in dirs {
                prefix += prefix.isEmpty ? String(dir) : "/" + dir
                if recursive.contains(prefix) { return true }
            }
            return parents.contains(prefix)
        }

        /// The patterns `git sparse-checkout set --cone` writes, or nil
        /// when `text` holds any other kind.
        init?(_ text: String, ignoreCase: Bool = false) {
            self.ignoreCase = ignoreCase
            for line in text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) })
            where !line.isEmpty && !line.hasPrefix("#") {
                if line == "/*" || line == "!/*/" { continue }
                if line.hasPrefix("!/"), line.hasSuffix("/*/"), line.count > 5 {
                    let dir = folded(Self.unescape(line.dropFirst(2).dropLast(3)))
                    recursive.remove(dir)
                    parents.insert(dir)
                } else if line.hasPrefix("/"), line.hasSuffix("/"), line.count > 2, !line.contains("*") {
                    recursive.insert(folded(Self.unescape(line.dropFirst().dropLast())))
                } else {
                    return nil
                }
            }
        }

        private static func unescape(_ text: Substring) -> String {
            var out = "", escaped = false
            for char in text {
                if !escaped, char == "\\" { escaped = true; continue }
                out.append(char)
                escaped = false
            }
            return out
        }
    }

    /// Whether core.sparseCheckout is on.
    func sparseCheckout() throws -> Bool {
        try configBool("core.sparsecheckout", default: false)
    }

    private func configBool(_ name: String, default fallback: Bool) throws -> Bool {
        var config: OpaquePointer?
        try check(git_repository_config_snapshot(&config, repo))
        defer { git_config_free(config) }
        var value: Int32 = 0
        return git_config_get_bool(&value, config, name) == 0 ? value != 0 : fallback
    }

    /// What the sparse-checkout file takes into the work tree: its cone
    /// in cone mode, when it holds cone patterns, or else its patterns as
    /// non-cone mode matches them; nil without a sparse checkout or file.
    func sparseIncludes() throws -> ((String) -> Bool)? {
        guard try sparseCheckout() else { return nil }
        let file = String(cString: git_repository_path(repo)) + "info/sparse-checkout"
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
        let ignoreCase = try ignoresCase()
        let coneMode = try configBool("core.sparsecheckoutcone", default: true)
        if coneMode, let cone = SparseCone(text, ignoreCase: ignoreCase) {
            return cone.includes
        }
        let patterns = SparsePatterns(text, ignoreCase: ignoreCase)
        return patterns.includes
    }

    /// Those of `paths` that stay out of the work tree: those the
    /// sparse-checkout file leaves out, as unpack-trees works
    /// skip-worktree out from it again (a file there is up to date, as
    /// the preflight found, and goes), or, without the file, those
    /// already skip-worktree where nothing stands.
    func sparseExclusions(of paths: [String], workdir: String) throws -> [String] {
        guard try sparseCheckout() else { return [] }
        var index: OpaquePointer?
        try check(git_repository_index(&index, repo))
        defer { git_index_free(index) }
        try check(git_index_read(index, 1))
        let skip = Set(skipWorktreePaths(index))
        let includes = try sparseIncludes()
        return paths.filter { path in
            if let includes { return !includes(path) }
            return skip.contains(path) && !Self.exists(workdir + path)
        }
    }

    /// Of the skip-worktree `paths` from before the merge, those that keep
    /// the bit: those the sparse-checkout file leaves out.
    func keepingSkipWorktree(_ paths: [String]) throws -> [String] {
        guard let includes = try sparseIncludes() else { return paths }
        return paths.filter { !includes($0) }
    }

    /// Take the files of `entries` out of the work tree, before anything
    /// else of the merge is written: where one can't go, or can't be
    /// looked at (a stale file left there would hide behind the bit),
    /// those already gone are put back from the unchanged index and this
    /// throws. Returns the files removed, for ``putBack(_:)``.
    func removeOutsideWorkTree(_ entries: [(path: String, entry: Entry)]) throws -> [String] {
        let workdir = git_repository_workdir(repo).map { String(cString: $0) } ?? ""
        var removed: [String] = []
        for (path, entry) in entries {
            do {
                let present = try Self.isPresent(workdir + path)
                try Self.removeFromWorkTree(path, in: workdir, gitlink: entry.mode == 0o160000)
                if present, entry.mode != 0o160000 { removed.append(path) }
            } catch {
                putBack(removed)
                throw error
            }
        }
        return removed
    }

    /// Write `paths` back from the index as it is.
    func putBack(_ paths: [String]) {
        try? checkout(paths, strategy: UInt32(GIT_CHECKOUT_FORCE.rawValue)) { options in
            try check(git_checkout_index(repo, nil, &options))
        }
    }

    /// What the index held at a path before ``stageOutsideWorkTree(_:)``.
    struct StagedBefore {
        let path: String
        let entry: Entry?
        let flagsExtended: UInt16
    }

    /// Put `entries` in the index with their skip-worktree bit, in one
    /// write: no file written, no checkout filter run. Returns what the
    /// index held there, for ``unstage(_:)``.
    func stageOutsideWorkTree(_ entries: [(path: String, entry: Entry)]) throws -> [StagedBefore] {
        guard !entries.isEmpty else { return [] }
        var index: OpaquePointer?
        try check(git_repository_index(&index, repo))
        defer { git_index_free(index) }
        try check(git_index_read(index, 1))
        let before = entries.map { path, _ in
            let old = git_index_get_bypath(index, path, 0)?.pointee
            return StagedBefore(path: path, entry: old.map { Entry(oid: $0.id, mode: $0.mode) },
                                flagsExtended: old?.flags_extended ?? 0)
        }
        try write(entries.map { ($0.path, $0.entry, UInt16(GIT_INDEX_ENTRY_SKIP_WORKTREE.rawValue)) }, to: index)
        return before
    }

    /// Put back what ``stageOutsideWorkTree(_:)`` replaced.
    func unstage(_ before: [StagedBefore]) {
        var index: OpaquePointer?
        guard git_repository_index(&index, repo) == 0 else { return }
        defer { git_index_free(index) }
        guard git_index_read(index, 1) == 0 else { return }
        for old in before where old.entry == nil { _ = git_index_remove_bypath(index, old.path) }
        let kept = before.compactMap { old in old.entry.map { (old.path, $0, old.flagsExtended) } }
        try? write(kept, to: index)
    }

    private func write(
        _ entries: [(path: String, entry: Entry, flagsExtended: UInt16)], to index: OpaquePointer?
    ) throws {
        for (path, entry, flagsExtended) in entries {
            _ = git_index_remove_bypath(index, path)
            try path.withCString { name in
                var record = git_index_entry()
                record.path = name
                record.id = entry.oid
                record.mode = entry.mode
                record.flags_extended = flagsExtended
                try check(git_index_add(index, &record))
            }
        }
        try check(git_index_write(index))
    }

    /// Whether anything is at `path` (lstat): nothing there is false; a
    /// path that can't be looked at throws, rather than pass for absent.
    static func isPresent(_ path: String) throws -> Bool {
        #if os(Windows)
        return exists(path)
        #else
        var info = stat()
        if lstat(path, &info) == 0 { return true }
        let code = errno
        if code == ENOENT || code == ENOTDIR { return false }
        throw Libgit2Error(code: -1, klass: 0, message: "unable to stat '\(path)': \(String(cString: strerror(code)))")
        #endif
    }

    /// Take `path` out of the work tree, and the directories that leaves
    /// empty; a submodule's directory only when it's empty. Throws where
    /// the file can't be removed.
    static func removeFromWorkTree(_ path: String, in workdir: String, gitlink: Bool = false) throws {
        var url = URL(fileURLWithPath: workdir + path)
        guard try isPresent(url.path) else { return }
        if gitlink {
            guard (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.isEmpty == true else { return }
        }
        try FileManager.default.removeItem(at: url)
        while url.deletingLastPathComponent().path.count >= workdir.count {
            url = url.deletingLastPathComponent()
            guard (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.isEmpty == true else { break }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Work skip-worktree out again for every merged entry, as
    /// unpack-trees does after a merge: a path the sparse-checkout file
    /// takes in loses the bit and is written where it's missing (a
    /// submodule's empty directory made); one it leaves out gets the bit,
    /// its file taken away where it's up to date (a changed one, or a
    /// submodule's directory with files, stays as git leaves it). A path
    /// whose name isn't UTF-8 is left as it is: a Swift string can't name
    /// its entry.
    func reapplySparsity() throws {
        guard let includes = try sparseIncludes() else { return }
        let workdir = git_repository_workdir(repo).map { String(cString: $0) } ?? ""
        var index: OpaquePointer?
        try check(git_repository_index(&index, repo))
        defer { git_index_free(index) }
        try check(git_index_read(index, 1))
        let bit = UInt16(GIT_INDEX_ENTRY_SKIP_WORKTREE.rawValue)
        var restore: [(path: String, gitlink: Bool)] = [], hide: [(path: String, entry: git_index_entry)] = []
        for i in 0..<git_index_entrycount(index) {
            guard let entry = git_index_get_byindex(index, i)?.pointee, (entry.flags >> 12) & 3 == 0 else { continue }
            let bytes = Self.bytes(entry.path), path = String(decoding: bytes, as: UTF8.self)
            guard path.utf8.elementsEqual(bytes) else { continue }
            let skipped = entry.flags_extended & bit != 0
            if includes(path) {
                if skipped { restore.append((path, entry.mode == 0o160000)) }
            } else if !skipped {
                hide.append((path, entry))
            }
        }
        // Written first (by force: the bit keeps safe checkout off it, and
        // nothing stands there), the bit cleared only then.
        for (path, gitlink) in restore where gitlink && !Self.exists(workdir + path) {
            try FileManager.default.createDirectory(atPath: workdir + path, withIntermediateDirectories: true)
        }
        try checkout(restore.filter { !$0.gitlink && !Self.exists(workdir + $0.path) }.map(\.path),
                     strategy: UInt32(GIT_CHECKOUT_FORCE.rawValue)) { options in
            try check(git_checkout_index(repo, nil, &options))
        }
        for (path, _) in restore { try setSkipWorktree(false, path: path) }
        // Whether a file is up to date is read off its content, not the
        // index's flags (assume-unchanged), as git's verify_uptodate does.
        let fileMode = try honorsFileMode(), symlinks = try honorsSymlinks()
        for (path, entry) in hide {
            let file = workdir + path
            if entry.mode == 0o160000 {
                if Self.exists(file), (try? FileManager.default.contentsOfDirectory(atPath: file))?.isEmpty != true {
                    continue
                }
                guard (try? Self.removeFromWorkTree(path, in: workdir, gitlink: true)) != nil else { continue }
            } else if Self.exists(file) {
                guard try matches(entry, path: path, at: file, fileMode: fileMode, symlinks: symlinks) else { continue }
                // One that can't go stays, unmarked, as git leaves it.
                guard (try? Self.removeFromWorkTree(path, in: workdir)) != nil else { continue }
            }
            try setSkipWorktree(true, path: path)
        }
    }
}

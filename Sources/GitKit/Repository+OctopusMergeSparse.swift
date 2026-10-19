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
        /// Directories by their bytes: Swift strings would take
        /// canonically equivalent names (é and e + ́) for one.
        var recursive: Set<[UInt8]> = []
        var parents: Set<[UInt8]> = []
        /// core.ignoreCase: directories compared as git's strcasecmp
        /// compares them, ASCII letters folded.
        var ignoreCase = false

        private func folded(_ text: String) -> [UInt8] {
            let bytes = Array(text.utf8)
            guard ignoreCase else { return bytes }
            return bytes.map { (65...90).contains($0) ? $0 + 32 : $0 }
        }

        func includes(_ path: String) -> Bool {
            let path = folded(path)
            let dirs = path.split(separator: 0x2F, omittingEmptySubsequences: false).dropLast()
            guard !dirs.isEmpty else { return true }
            var prefix: [UInt8] = []
            for dir in dirs {
                prefix += prefix.isEmpty ? Array(dir) : [0x2F] + dir
                if recursive.contains(prefix) { return true }
            }
            return parents.contains(prefix)
        }

        /// The patterns `git sparse-checkout set --cone` writes, or nil
        /// when `text` holds any other kind.
        init?(_ text: String, ignoreCase: Bool = false) {
            self.ignoreCase = ignoreCase
            // Only the trailing spaces git drops go: a leading one makes
            // the line a different (non-cone) pattern.
            for line in text.split(separator: "\n").map({ SparsePatterns.trimmingTrailingSpaces(
                String($0.hasSuffix("\r") ? $0.dropLast() : $0)) })
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

    /// A boolean setting, `fallback` where it's unset; a value that isn't
    /// a boolean throws, as git dies on it.
    private func configBool(_ name: String, default fallback: Bool) throws -> Bool {
        var config: OpaquePointer?
        try check(git_repository_config_snapshot(&config, repo))
        defer { git_config_free(config) }
        var value: Int32 = 0
        let rc = git_config_get_bool(&value, config, name)
        if rc == GIT_ENOTFOUND.rawValue { return fallback }
        try check(rc)
        return value != 0
    }

    /// What the sparse-checkout file takes into the work tree: its cone
    /// in cone mode (core.sparseCheckoutCone set true), when it holds cone
    /// patterns, or else its patterns as non-cone mode matches them; nil
    /// without a sparse checkout or file.
    func sparseIncludes() throws -> ((String) -> Bool)? {
        guard try sparseCheckout() else { return nil }
        let file = String(cString: git_repository_path(repo)) + "info/sparse-checkout"
        // Bytes, as git reads them: a comment that isn't UTF-8 costs the
        // other lines nothing; a rule that isn't can't be matched as git
        // matches its bytes, and stops the merge before anything changes.
        // No file is no rules; one that can't be read stops the merge.
        guard try Self.isPresent(file) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: file))
        for line in data.split(separator: 0x0A) {
            let bytes = Array(line)
            // A comment only where `#` is the line's first byte.
            guard bytes.first != 0x23,
                  !String(decoding: bytes, as: UTF8.self).utf8.elementsEqual(bytes) else { continue }
            throw Libgit2Error(code: -1, klass: 0, message:
                "cannot merge: sparse-checkout rule \(Self.quotedPath(bytes)) is not valid UTF-8")
        }
        let text = String(decoding: data, as: UTF8.self)
        let ignoreCase = try ignoresCase()
        // Unset is non-cone, as git reads it; `sparse-checkout set` writes
        // it true.
        let coneMode = try configBool("core.sparsecheckoutcone", default: false)
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
        for (path, _) in entries {
            do {
                let present = try Self.isPresent(workdir + path)
                try Self.removeFromWorkTree(path, in: workdir)
                // Whatever went, to put back from the index as it was; a
                // directory with files stays.
                if present, try !Self.isPresent(workdir + path) { removed.append(path) }
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

    /// An index entry at a path with its flag words: what the index held
    /// before ``stageOutsideWorkTree(_:)``, or what it stages.
    struct StagedBefore {
        let path: String
        let entry: Entry?
        let flags: UInt16
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
                                flags: old?.flags ?? 0, flagsExtended: old?.flags_extended ?? 0)
        }
        let skip = UInt16(GIT_INDEX_ENTRY_SKIP_WORKTREE.rawValue)
        let staged = entries.map { StagedBefore(path: $0.path, entry: $0.entry, flags: 0, flagsExtended: skip) }
        try write(staged, to: index)
        return before
    }

    /// Put back what ``stageOutsideWorkTree(_:)`` replaced.
    func unstage(_ before: [StagedBefore]) {
        var index: OpaquePointer?
        guard git_repository_index(&index, repo) == 0 else { return }
        defer { git_index_free(index) }
        guard git_index_read(index, 1) == 0 else { return }
        for old in before where old.entry == nil { _ = git_index_remove_bypath(index, old.path) }
        // Both flag words as they were: assume-unchanged too.
        try? write(before.filter { $0.entry != nil }, to: index)
    }

    private func write(
        _ entries: [StagedBefore], to index: OpaquePointer?
    ) throws {
        for staged in entries {
            guard let entry = staged.entry else { continue }
            let path = staged.path
            _ = git_index_remove_bypath(index, path)
            try path.withCString { name in
                var record = git_index_entry()
                record.path = name
                record.id = entry.oid
                record.mode = entry.mode
                // Only the bits an entry keeps (assume-unchanged); its
                // stage and name length are the index's to set.
                record.flags = staged.flags & UInt16(GIT_INDEX_ENTRY_VALID.rawValue)
                record.flags_extended = staged.flagsExtended
                try check(git_index_add(index, &record))
            }
        }
        try check(git_index_write(index))
    }

    /// Whether anything is at `path` (lstat): nothing there is false; a
    /// path that can't be looked at throws, rather than pass for absent.
    static func isPresent(_ path: String) throws -> Bool {
        #if os(Windows)
        do {
            _ = try FileManager.default.attributesOfItem(atPath: path)
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return false
        }
        #else
        var info = stat()
        if lstat(path, &info) == 0 { return true }
        let code = errno
        if code == ENOENT || code == ENOTDIR { return false }
        throw Libgit2Error(code: -1, klass: 0, message: "unable to stat '\(path)': \(String(cString: strerror(code)))")
        #endif
    }

    /// Take `path` out of the work tree, and the directories that leaves
    /// empty. A directory there (a submodule's, whatever the merge makes
    /// of the path) goes only when it's empty: one with files stays, as
    /// git keeps it. Throws where the path can't be removed or looked at.
    static func removeFromWorkTree(_ path: String, in workdir: String) throws {
        var url = URL(fileURLWithPath: workdir + path)
        guard try isPresent(url.path) else { return }
        let type = try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        if type == .typeDirectory, try !FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty { return }
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
    /// submodule's directory with files, stays as git leaves it). The
    /// files change first and the bits in one write of the index; where
    /// that fails, the files are put back as they were. A path whose name
    /// isn't UTF-8 is left as it is: a Swift string can't name its entry.
    /// Returns what takes the file changes back, once the index is back.
    @discardableResult
    func reapplySparsity() throws -> () -> Void {
        guard let includes = try sparseIncludes() else { return {} }
        let workdir = git_repository_workdir(repo).map { String(cString: $0) } ?? ""
        let (restore, hide) = try sparseChanges(includes)
        // Written by force: the bit keeps safe checkout off them, and
        // nothing stands there.
        var made: [String] = [], hidden: [String] = [], removed: [String] = [], emptied: [String] = []
        let written = restore.filter { !$0.gitlink && !Self.exists(workdir + $0.path) }.map(\.path)
        let undo = { [self] in
            putBack(removed)
            for path in emptied { try? FileManager.default.createDirectory(atPath: workdir + path,
                                                                           withIntermediateDirectories: true) }
            for path in written + made { try? FileManager.default.removeItem(atPath: workdir + path) }
        }
        do {
            for (path, gitlink) in restore where gitlink && !Self.exists(workdir + path) {
                try FileManager.default.createDirectory(atPath: workdir + path, withIntermediateDirectories: true)
                made.append(path)
            }
            // Whether a file is up to date is read off its content, not the
            // index's flags (assume-unchanged), as git's verify_uptodate does.
            let fileMode = try honorsFileMode(), symlinks = try honorsSymlinks()
            try checkout(written, strategy: UInt32(GIT_CHECKOUT_FORCE.rawValue)) { options in
                try check(git_checkout_index(repo, nil, &options))
            }
            for (path, entry) in hide {
                let file = workdir + path
                if try Self.isPresent(file) {
                    if entry.mode == 0o160000 {
                        // A submodule's place: only its (empty) directory
                        // goes; a file or link there is the user's.
                        let type = try FileManager.default.attributesOfItem(atPath: file)[.type] as? FileAttributeType
                        guard type == .typeDirectory else { continue }
                    } else if try !matches(entry, path: path, at: file, fileMode: fileMode, symlinks: symlinks) {
                        continue
                    }
                    // One that can't go stays, unmarked, as git leaves it.
                    guard (try? Self.removeFromWorkTree(path, in: workdir)) != nil else { continue }
                    if try Self.isPresent(file) { continue }
                    if entry.mode == 0o160000 { emptied.append(path) } else { removed.append(path) }
                }
                hidden.append(path)
            }
            try setSkipWorktree(on: hidden, off: restore.map(\.path))
        } catch {
            undo()
            throw error
        }
        return undo
    }

    /// The stage-0 entries whose skip-worktree bit `includes` changes:
    /// those to take back in (and whether each is a submodule), and those
    /// to leave out.
    private func sparseChanges(
        _ includes: (String) -> Bool
    ) throws -> (restore: [(path: String, gitlink: Bool)], hide: [(path: String, entry: git_index_entry)]) {
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
        return (restore, hide)
    }

    /// Set the skip-worktree bit on `on` and clear it on `off`, in one
    /// write of the index.
    private func setSkipWorktree(on: [String], off: [String]) throws {
        guard !on.isEmpty || !off.isEmpty else { return }
        var index: OpaquePointer?
        try check(git_repository_index(&index, repo))
        defer { git_index_free(index) }
        try check(git_index_read(index, 1))
        let bit = UInt16(GIT_INDEX_ENTRY_SKIP_WORKTREE.rawValue)
        for (paths, set) in [(on, true), (off, false)] {
            for path in paths {
                guard var entry = git_index_get_bypath(index, path, 0)?.pointee else { continue }
                entry.flags_extended = set ? entry.flags_extended | bit : entry.flags_extended & ~bit
                try path.withCString { name in
                    entry.path = name
                    try check(git_index_add(index, &entry))
                }
            }
        }
        try check(git_index_write(index))
    }
}

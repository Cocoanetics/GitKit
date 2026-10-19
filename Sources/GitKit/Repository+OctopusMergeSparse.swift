// A sparse checkout through an octopus merge, as unpack-trees keeps it:
// a path outside the sparse checkout gets its index entry, marked
// skip-worktree, and nothing in the work tree.
import Foundation
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

    /// Those of `paths` that stay out of the work tree, where nothing
    /// stands at them: those the sparse-checkout file leaves out, as
    /// unpack-trees works skip-worktree out from it again, or, without
    /// the file, those already skip-worktree.
    func sparseExclusions(of paths: [String], workdir: String) throws -> [String] {
        guard try sparseCheckout() else { return [] }
        var index: OpaquePointer?
        try check(git_repository_index(&index, repo))
        defer { git_index_free(index) }
        try check(git_index_read(index, 1))
        let skip = Set(skipWorktreePaths(index))
        let includes = try sparseIncludes()
        return paths.filter { path in
            (includes.map { !$0(path) } ?? skip.contains(path)) && !Self.exists(workdir + path)
        }
    }

    /// Of the skip-worktree `paths` from before the merge, those that keep
    /// the bit: those the sparse-checkout file leaves out.
    func keepingSkipWorktree(_ paths: [String]) throws -> [String] {
        guard let includes = try sparseIncludes() else { return paths }
        return paths.filter { !includes($0) }
    }

    /// Put `entries` in the index, skip-worktree, without checking them
    /// out: no file written, no checkout filter run.
    func recordOutsideWorkTree(_ entries: [(path: String, entry: Entry)]) throws {
        guard !entries.isEmpty else { return }
        var index: OpaquePointer?
        try check(git_repository_index(&index, repo))
        defer { git_index_free(index) }
        try check(git_index_read(index, 1))
        for (path, entry) in entries {
            _ = git_index_remove_bypath(index, path)
            try path.withCString { name in
                var record = git_index_entry()
                record.path = name
                record.id = entry.oid
                record.mode = entry.mode
                try check(git_index_add(index, &record))
            }
        }
        try check(git_index_write(index))
        for (path, _) in entries { try setSkipWorktree(true, path: path) }
    }

    /// Work skip-worktree out again for every merged entry, as
    /// unpack-trees does after a merge: a path the sparse-checkout file
    /// takes in loses the bit and is written where it's missing; one it
    /// leaves out gets the bit, its file taken away where it's up to
    /// date (a changed one stays, as git leaves it).
    func reapplySparsity() throws {
        guard let includes = try sparseIncludes() else { return }
        let workdir = git_repository_workdir(repo).map { String(cString: $0) } ?? ""
        var index: OpaquePointer?
        try check(git_repository_index(&index, repo))
        defer { git_index_free(index) }
        try check(git_index_read(index, 1))
        let bit = UInt16(GIT_INDEX_ENTRY_SKIP_WORKTREE.rawValue)
        var restore: [String] = [], hide: [String] = []
        for i in 0..<git_index_entrycount(index) {
            guard let entry = git_index_get_byindex(index, i)?.pointee, (entry.flags >> 12) & 3 == 0,
                  entry.mode != 0o160000 else { continue }
            let path = String(cString: entry.path), skipped = entry.flags_extended & bit != 0
            if includes(path) {
                if skipped { restore.append(path) }
            } else if !skipped {
                hide.append(path)
            }
        }
        for path in restore { try setSkipWorktree(false, path: path) }
        try checkout(restore.filter { !Self.exists(workdir + $0) },
                     strategy: UInt32(GIT_CHECKOUT_SAFE.rawValue)) { options in
            try check(git_checkout_index(repo, nil, &options))
        }
        let changed = UInt32(GIT_STATUS_WT_MODIFIED.rawValue | GIT_STATUS_WT_TYPECHANGE.rawValue)
        for path in hide {
            if Self.exists(workdir + path) {
                var flags: UInt32 = 0
                guard git_status_file(&flags, repo, path) == 0, flags & changed == 0 else { continue }
                var url = URL(fileURLWithPath: workdir + path)
                try FileManager.default.removeItem(at: url)
                // And the directories it leaves empty.
                while url.deletingLastPathComponent().path.count >= workdir.count {
                    url = url.deletingLastPathComponent()
                    let entries = try? FileManager.default.contentsOfDirectory(atPath: url.path)
                    guard entries?.isEmpty == true else { break }
                    try? FileManager.default.removeItem(at: url)
                }
            }
            try setSkipWorktree(true, path: path)
        }
    }
}

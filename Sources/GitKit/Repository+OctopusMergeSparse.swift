// A sparse checkout through an octopus merge, as unpack-trees keeps it:
// a path outside the sparse checkout gets its index entry, marked
// skip-worktree, and nothing in the work tree.
import Foundation
import CGitKit

extension Repository {

    /// A path the merge updates that stays out of the work tree, and the
    /// deepest of its directories that already exists.
    struct SparseExclusion {
        let path: String
        let existing: String
    }

    /// The cone-mode sparse-checkout patterns: directories taken whole,
    /// and directories whose own files only are taken. Files at the top
    /// are always in.
    struct SparseCone {
        var recursive: Set<String> = []
        var parents: Set<String> = []

        func includes(_ path: String) -> Bool {
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
        init?(_ text: String) {
            for line in text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) })
            where !line.isEmpty && !line.hasPrefix("#") {
                if line == "/*" || line == "!/*/" { continue }
                if line.hasPrefix("!/"), line.hasSuffix("/*/"), line.count > 5 {
                    let dir = Self.unescape(line.dropFirst(2).dropLast(3))
                    recursive.remove(dir)
                    parents.insert(dir)
                } else if line.hasPrefix("/"), line.hasSuffix("/"), line.count > 2, !line.contains("*") {
                    recursive.insert(Self.unescape(line.dropFirst().dropLast()))
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
        if try configBool("core.sparsecheckoutcone", default: true), let cone = SparseCone(text) {
            return cone.includes
        }
        let patterns = SparsePatterns(text, ignoreCase: try ignoresCase())
        return patterns.includes
    }

    /// Those of `paths` that stay out of the work tree, where nothing
    /// stands at them: those the sparse-checkout file leaves out, as
    /// unpack-trees works skip-worktree out from it again, or, without
    /// the file, those already skip-worktree.
    func sparseExclusions(of paths: [String], workdir: String) throws -> [SparseExclusion] {
        guard try sparseCheckout() else { return [] }
        var index: OpaquePointer?
        try check(git_repository_index(&index, repo))
        defer { git_index_free(index) }
        try check(git_index_read(index, 1))
        let skip = Set(skipWorktreePaths(index))
        let includes = try sparseIncludes()
        return paths.compactMap { path in
            let outside = includes.map { !$0(path) } ?? skip.contains(path)
            guard outside, !Self.exists(workdir + path) else { return nil }
            return SparseExclusion(path: path, existing: Self.deepestExisting(path, in: workdir))
        }
    }

    /// Of the skip-worktree `paths` from before the merge, those that keep
    /// the bit: those the sparse-checkout file leaves out.
    func keepingSkipWorktree(_ paths: [String]) throws -> [String] {
        guard let includes = try sparseIncludes() else { return paths }
        return paths.filter { !includes($0) }
    }

    /// Take away what the checkout wrote for `exclusions` that the merge
    /// left merged, and the directories made for it; mark them
    /// skip-worktree.
    func leaveOutOfWorkTree(_ exclusions: [SparseExclusion], workdir: String) throws {
        guard !exclusions.isEmpty else { return }
        var index: OpaquePointer?
        try check(git_repository_index(&index, repo))
        defer { git_index_free(index) }
        try check(git_index_read(index, 1))
        let merged = exclusions.filter { git_index_get_bypath(index, $0.path, 0) != nil }
        for exclusion in merged {
            var url = URL(fileURLWithPath: workdir + exclusion.path)
            try? FileManager.default.removeItem(at: url)
            while url.deletingLastPathComponent().path.count > exclusion.existing.count {
                url = url.deletingLastPathComponent()
                guard (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.isEmpty == true else { break }
                try? FileManager.default.removeItem(at: url)
            }
        }
        for exclusion in merged { try setSkipWorktree(true, path: exclusion.path) }
    }

    /// The deepest of `path`'s directories that exists under `workdir`.
    static func deepestExisting(_ path: String, in workdir: String) -> String {
        var url = URL(fileURLWithPath: workdir + path).deletingLastPathComponent()
        while url.path.count > workdir.count, !exists(url.path) { url = url.deletingLastPathComponent() }
        return url.path
    }
}

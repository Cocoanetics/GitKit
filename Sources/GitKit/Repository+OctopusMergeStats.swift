// The merge's diffstat as git writes it after a merge (show_stats with
// --summary): paths quoted as git quotes them, renames found, and the
// name and graph columns sized as git sizes them.
import Foundation
import CGitKit

extension Repository {

    /// A path as git writes it in a diff summary (quote_c_style): in
    /// double quotes with C escapes when it holds a control character, a
    /// quote or a backslash, or, with core.quotePath, a byte above 0x7f.
    static func quotedPath(_ path: [UInt8], quotePath: Bool = true) -> String {
        func needsQuote(_ byte: UInt8) -> Bool {
            byte < 0x20 || byte == 0x22 || byte == 0x5C || byte == 0x7F || (quotePath && byte >= 0x80)
        }
        guard path.contains(where: needsQuote) else { return String(decoding: path, as: UTF8.self) }
        let escapes: [UInt8: String] = [0x07: "\\a", 0x08: "\\b", 0x09: "\\t", 0x0A: "\\n", 0x0B: "\\v",
                                        0x0C: "\\f", 0x0D: "\\r", 0x22: "\\\"", 0x5C: "\\\\"]
        var out: [UInt8] = [0x22]
        for byte in path {
            if let escape = escapes[byte] {
                out += Array(escape.utf8)
            } else if needsQuote(byte) {
                let octal = String(byte, radix: 8)
                out += Array(("\\" + String(repeating: "0", count: 3 - octal.count) + octal).utf8)
            } else {
                out.append(byte)
            }
        }
        out.append(0x22)
        return String(decoding: out, as: UTF8.self)
    }

    /// A C string's bytes, which needn't be UTF-8.
    static func bytes(_ string: UnsafePointer<CChar>) -> [UInt8] {
        Array(UnsafeBufferPointer(start: string, count: strlen(string))).map { UInt8(bitPattern: $0) }
    }

    /// Whether paths are written with bytes above 0x7f escaped
    /// (core.quotePath, true unless set false).
    func quotesPaths() throws -> Bool {
        var config: OpaquePointer?
        try check(git_repository_config_snapshot(&config, repo))
        defer { git_config_free(config) }
        var value: Int32 = 1
        return git_config_get_bool(&value, config, "core.quotepath") != 0 || value != 0
    }

    /// `old => new` as git's diff summary writes a rename (pprint_rename):
    /// a common leading directory and trailing part outside braces,
    /// `dir/{a => b}/file`, or both paths whole when either is quoted.
    static func renameText(_ old: [UInt8], _ new: [UInt8], quotePath: Bool = true) -> String {
        let quotedOld = quotedPath(old, quotePath: quotePath), quotedNew = quotedPath(new, quotePath: quotePath)
        guard quotedOld.hasPrefix("\"") || quotedNew.hasPrefix("\"") else { return renameText(quotedOld, quotedNew) }
        return quotedOld + " => " + quotedNew
    }

    /// `old => new` for paths that need no quoting, with braces.
    static func renameText(_ old: String, _ new: String) -> String {
        let a = Array(old.utf8), b = Array(new.utf8)
        let slash = UInt8(ascii: "/")
        var prefix = 0
        var i = 0
        while i < a.count, i < b.count, a[i] == b[i] {
            if a[i] == slash { prefix = i + 1 }
            i += 1
        }
        // A common suffix starts at a slash, and doesn't run past the
        // prefix (into its slash only, when there is one).
        var suffix = 0
        var x = a.count, y = b.count
        let floor = prefix - (prefix > 0 ? 1 : 0)
        while x >= floor, y >= floor {
            let ca: UInt8 = x < a.count ? a[x] : 0, cb: UInt8 = y < b.count ? b[y] : 0
            guard ca == cb else { break }
            if ca == slash { suffix = a.count - x }
            x -= 1
            y -= 1
        }
        guard prefix + suffix > 0 else { return old + " => " + new }
        func text(_ bytes: ArraySlice<UInt8>) -> String { String(decoding: bytes, as: UTF8.self) }
        let aMid = a[prefix..<max(prefix, a.count - suffix)], bMid = b[prefix..<max(prefix, b.count - suffix)]
        return text(a[..<prefix]) + "{" + text(aMid) + " => " + text(bMid) + "}" + text(a[(a.count - suffix)...])
    }

    /// A merge's diffstat: its block, created and deleted files' lines,
    /// and every summary line in git's order.
    struct MergeStats {
        let summary: String
        let added: [String]
        let deleted: [String]
        let lines: [String]
    }

    /// One path in the diffstat: its name as printed, and its lines added
    /// and deleted, or its sizes after and before when it's binary.
    struct StatFile {
        let name: String
        let added: Int
        let deleted: Int
        let binary: Bool
    }

    func mergeStats(from old: git_oid, to new: git_oid) throws -> MergeStats {
        let quotePath = try quotesPaths()
        let (nameLimit, graphLimit) = try statWidths()
        return try withTree(old) { old in
            try withTree(new) { new in
                var diff: OpaquePointer?
                try check(git_diff_tree_to_tree(&diff, repo, old, new, nil))
                defer { git_diff_free(diff) }
                // Renames found, as git's merge diffstat finds them.
                var find = git_diff_find_options()
                try check(git_diff_find_options_init(&find, UInt32(GIT_DIFF_FIND_OPTIONS_VERSION)))
                find.flags = UInt32(GIT_DIFF_FIND_RENAMES.rawValue)
                try check(git_diff_find_similar(diff, &find))
                var files: [StatFile] = [], lines: [String] = [], added: [String] = [], deleted: [String] = []
                for i in 0..<git_diff_num_deltas(diff) {
                    var patch: OpaquePointer?
                    try check(git_patch_from_diff(&patch, diff, i))
                    defer { git_patch_free(patch) }
                    guard let delta = git_patch_get_delta(patch)?.pointee else { continue }
                    let oldBytes = Self.bytes(delta.old_file.path), newBytes = Self.bytes(delta.new_file.path)
                    let oldPath = Self.quotedPath(oldBytes, quotePath: quotePath)
                    let newPath = Self.quotedPath(newBytes, quotePath: quotePath)
                    let oldMode = String(format: "%06o", delta.old_file.mode)
                    let newMode = String(format: "%06o", delta.new_file.mode)
                    let binary = delta.flags & UInt32(GIT_DIFF_FLAG_BINARY.rawValue) != 0
                    var context = 0, adds = 0, dels = 0
                    if !binary { try check(git_patch_line_stats(&context, &adds, &dels, patch)) }
                    let renamed = delta.status == GIT_DELTA_RENAMED
                    let name = renamed ? Self.renameText(oldBytes, newBytes, quotePath: quotePath) : newPath
                    files.append(binary
                        ? StatFile(name: name, added: Int(delta.new_file.size), deleted: Int(delta.old_file.size),
                                   binary: true)
                        : StatFile(name: name, added: adds, deleted: dels, binary: false))
                    // ` create mode`, ` delete mode`, ` rename … (N%)`, ` mode change`.
                    switch delta.status {
                    case GIT_DELTA_ADDED:
                        lines.append(" create mode \(newMode) \(newPath)")
                        added.append(lines[lines.count - 1])
                    case GIT_DELTA_DELETED:
                        lines.append(" delete mode \(oldMode) \(oldPath)")
                        deleted.append(lines[lines.count - 1])
                    case GIT_DELTA_RENAMED:
                        lines.append(" rename \(name) (\(delta.similarity)%)")
                        if oldMode != newMode { lines.append(" mode change \(oldMode) => \(newMode)") }
                    default:
                        if oldMode != newMode { lines.append(" mode change \(oldMode) => \(newMode) \(newPath)") }
                    }
                }
                let summary = Self.diffstat(files, nameLimit: nameLimit, graphLimit: graphLimit)
                return MergeStats(summary: summary, added: added, deleted: deleted, lines: lines)
            }
        }
    }

    /// diff.statNameWidth and diff.statGraphWidth, 0 when unset.
    func statWidths() throws -> (name: Int, graph: Int) {
        var config: OpaquePointer?
        try check(git_repository_config_snapshot(&config, repo))
        defer { git_config_free(config) }
        var name: Int32 = 0, graph: Int32 = 0
        if git_config_get_int32(&name, config, "diff.statnamewidth") != 0 { name = 0 }
        if git_config_get_int32(&graph, config, "diff.statgraphwidth") != 0 { graph = 0 }
        return (Int(name), Int(graph))
    }

    /// The diffstat block as git's show_stats writes it for 80 columns,
    /// without its last newline: the name column as wide as the widest
    /// name, the `+`/`-` graph scaled to what's left.
    static func diffstat(_ files: [StatFile], width: Int = 80, nameLimit: Int = 0, graphLimit: Int = 0) -> String {
        guard !files.isEmpty else { return "" }
        func columns<S: Sequence>(_ text: S) -> Int where S.Element == Unicode.Scalar {
            text.reduce(0) { $0 + ($1.properties.generalCategory == .nonspacingMark ? 0 : 1) }
        }
        var maxLen = 0, maxChange = 0, numberWidth = 0, binWidth = 0
        for file in files {
            maxLen = max(maxLen, columns(file.name.unicodeScalars))
            if file.binary {
                // "Bin XXX -> YYY bytes", the count aligned with "Bin".
                binWidth = max(binWidth, 14 + String(file.added).count + String(file.deleted).count)
                numberWidth = 3
            } else {
                maxChange = max(maxChange, file.added + file.deleted)
            }
        }
        numberWidth = max(String(maxChange).count, numberWidth)
        let width = max(width, 16 + 6 + numberWidth)
        var graphWidth = maxChange + 4 > binWidth ? maxChange : binWidth - 4
        if graphLimit != 0, graphLimit < graphWidth { graphWidth = graphLimit }
        var nameWidth = nameLimit > 0 && nameLimit < maxLen ? nameLimit : maxLen
        if nameWidth + numberWidth + 6 + graphWidth > width {
            if graphWidth > width * 3 / 8 - numberWidth - 6 { graphWidth = max(width * 3 / 8 - numberWidth - 6, 6) }
            if graphLimit != 0, graphWidth > graphLimit { graphWidth = graphLimit }
            if nameWidth > width - numberWidth - 6 - graphWidth {
                nameWidth = width - numberWidth - 6 - graphWidth
            } else {
                graphWidth = width - numberWidth - 6 - nameWidth
            }
        }
        func scaled(_ count: Int) -> Int { count == 0 ? 0 : 1 + count * (graphWidth - 1) / maxChange }
        func padded(_ text: String, to count: Int) -> String {
            String(repeating: " ", count: max(count - text.count, 0)) + text
        }
        var out: [String] = []
        for file in files {
            // A name too wide loses its front, from a slash where there is one.
            var name = Substring.UnicodeScalarView(file.name.unicodeScalars), prefix = "", len = nameWidth
            var nameLen = columns(name)
            if nameWidth < nameLen {
                prefix = "..."
                len = max(len - 3, 0)
                while nameLen > len, let first = name.first {
                    nameLen -= columns([first])
                    name.removeFirst()
                }
                if let slash = name.firstIndex(of: "/") { name = name[slash...] }
            }
            let head = " " + prefix + String(name) + String(repeating: " ", count: max(len - columns(name), 0)) + " | "
            if file.binary {
                let tail = file.added == 0 && file.deleted == 0 ? "" : " \(file.deleted) -> \(file.added) bytes"
                out.append(head + padded("Bin", to: numberWidth) + tail)
                continue
            }
            var add = file.added, del = file.deleted
            if graphWidth <= maxChange {
                var total = scaled(add + del)
                if total < 2, add > 0, del > 0 { total = 2 }
                if add < del {
                    add = scaled(add)
                    del = total - add
                } else {
                    del = scaled(del)
                    add = total - del
                }
            }
            let change = file.added + file.deleted
            out.append(head + padded(String(change), to: numberWidth) + (change > 0 ? " " : "")
                       + String(repeating: "+", count: max(add, 0)) + String(repeating: "-", count: max(del, 0)))
        }
        let text = files.filter { !$0.binary }
        let adds = text.reduce(0) { $0 + $1.added }, dels = text.reduce(0) { $0 + $1.deleted }
        var total = files.count == 1 ? " 1 file changed" : " \(files.count) files changed"
        if adds > 0 || dels == 0 { total += adds == 1 ? ", 1 insertion(+)" : ", \(adds) insertions(+)" }
        if dels > 0 || adds == 0 { total += dels == 1 ? ", 1 deletion(-)" : ", \(dels) deletions(-)" }
        return (out + [total]).joined(separator: "\n")
    }
}

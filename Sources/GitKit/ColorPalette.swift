import Foundation

/// Palette used by `git status` / `git diff` to colorize their
/// output. Mirrors real git's defaults (`color.status.*` /
/// `color.diff.*`) close enough to look familiar without
/// implementing config-driven theming.
///
/// When `enabled == false`, every method returns its input
/// unchanged — call sites stay terse (`palette.staged("modified:")`
/// works whether color is on or off).
public struct ColorPalette: Sendable {

    /// Whether ANSI escapes are emitted. `false` turns every method
    /// into a pass-through.
    public let enabled: Bool
    /// Create a palette; `enabled: true` emits ANSI colors,
    /// `enabled: false` behaves like ``disabled``.
    public init(enabled: Bool) { self.enabled = enabled }

    /// No-op palette — every method returns its input unchanged.
    /// Default for `verboseFormat()` so existing callers (and the
    /// `--color=never` path) need no extra plumbing.
    public static let disabled = ColorPalette(enabled: false)

    // MARK: - status

    /// Staged paths / verbose labels — `new file:`, `modified:`, etc.
    public func staged(_ s: String)    -> String { wrap(s, sgr: "32") }    // green
    /// Unstaged paths + untracked paths + conflicted lines.
    public func unstaged(_ s: String)  -> String { wrap(s, sgr: "31") }    // red
    /// Branch name in the verbose header.
    public func branch(_ s: String)    -> String { wrap(s, sgr: "32") }    // green

    // MARK: - diff

    /// Bold-white file headers (`diff --git`, `index`, `--- a/foo`,
    /// `+++ b/foo`).
    public func meta(_ s: String)      -> String { wrap(s, sgr: "1") }     // bold
    /// `@@ … @@` hunk separators.
    public func frag(_ s: String)      -> String { wrap(s, sgr: "36") }    // cyan
    /// `+` lines.
    public func added(_ s: String)     -> String { wrap(s, sgr: "32") }    // green
    /// `-` lines.
    public func removed(_ s: String)   -> String { wrap(s, sgr: "31") }    // red

    private func wrap(_ s: String, sgr: String) -> String {
        guard enabled, !s.isEmpty else { return s }
        return "\u{1B}[\(sgr)m\(s)\u{1B}[m"
    }

    // MARK: - patch colorizer

    /// Walk a libgit2-produced unified-diff string line by line and
    /// apply the standard `git diff` colors. Same per-line rules real
    /// git uses for `color.diff.*`:
    ///   - `diff --git` / `index` / `--- a/...` / `+++ b/...` → bold
    ///   - `@@ … @@`                                          → cyan
    ///   - leading `+` (but not the `+++` header)             → green
    ///   - leading `-` (but not the `---` header)             → red
    ///   - everything else                                    → default
    ///
    /// No-op when `enabled == false`. Preserves the input's trailing
    /// newline policy byte-for-byte.
    public func colorizePatch(_ patch: String) -> String {
        guard enabled, !patch.isEmpty else { return patch }
        let hadTrailingNewline = patch.hasSuffix("\n")
        var lines = patch.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        // `split` with `omittingEmptySubsequences: false` keeps the
        // empty tail after a trailing newline. Drop it so we don't
        // emit an extra blank line, then re-add the newline below.
        if hadTrailingNewline, lines.last == "" { lines.removeLast() }
        for (i, line) in lines.enumerated() {
            lines[i] = colorize(diffLine: line)
        }
        return lines.joined(separator: "\n") + (hadTrailingNewline ? "\n" : "")
    }

    private func colorize(diffLine line: String) -> String {
        if line.hasPrefix("diff --git") || line.hasPrefix("index ")
            || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
            || line.hasPrefix("new file mode") || line.hasPrefix("deleted file mode")
            || line.hasPrefix("similarity index") || line.hasPrefix("rename from")
            || line.hasPrefix("rename to") || line.hasPrefix("copy from")
            || line.hasPrefix("copy to") || line.hasPrefix("old mode")
            || line.hasPrefix("new mode") {
            return meta(line)
        }
        if line.hasPrefix("@@") { return frag(line) }
        if line.hasPrefix("+")  { return added(line) }
        if line.hasPrefix("-")  { return removed(line) }
        return line
    }

    // MARK: - diffstat colorizer

    /// Colorize a `git diff --stat` summary the way real git's
    /// `color.diff` defaults do:
    ///   - the per-file histogram bar — the leading run of `+` green,
    ///     the trailing run of `-` red (` foo | 5 ++-` → green `++`,
    ///     red `-`); a scaled bar (` foo | 170 +++…---`) colors the
    ///     same way
    ///   - a binary delta — ` Bin <old> -> <new> bytes` — colors the
    ///     old size red and the new size green
    ///   - the file path, the change count, the `|` separator, and the
    ///     trailing `N files changed …` summary line stay uncolored
    ///
    /// No-op when `enabled == false`. Preserves the input's trailing
    /// newline policy byte-for-byte.
    ///
    /// Only `--stat` is routed here. `--shortstat` is intentionally
    /// left uncolored — real git colors the per-file bars but not the
    /// lone shortstat summary line — and the machine-readable forms
    /// (`--numstat` / `--raw` / `--name-only` / `--name-status`) stay
    /// plain so downstream pipes don't have to strip escapes.
    public func colorizeDiffStat(_ stat: String) -> String {
        guard enabled, !stat.isEmpty else { return stat }
        let hadTrailingNewline = stat.hasSuffix("\n")
        var lines = stat.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if hadTrailingNewline, lines.last == "" { lines.removeLast() }
        for (i, line) in lines.enumerated() {
            lines[i] = colorize(statLine: line)
        }
        return lines.joined(separator: "\n") + (hadTrailingNewline ? "\n" : "")
    }

    private func colorize(statLine line: String) -> String {
        // Only per-file lines carry the ` <path> | …` separator; the
        // trailing `N files changed …` summary has no `|`, so it (and
        // any other separator-less line) passes through untouched. Use
        // the LAST `|` so a path that itself contains `|` still splits
        // at the real separator (the count / bar never contain one).
        guard let bar = line.lastIndex(of: "|") else { return line }
        let prefix = String(line[...bar])           // through the `|`
        let stats = String(line[line.index(after: bar)...])

        // Binary delta — ` Bin <old> -> <new> bytes`: old size red,
        // new size green. Checked before the histogram path, which
        // wouldn't match it anyway (no trailing `+`/`-` run).
        if let binary = colorizeBinaryStat(stats) { return prefix + binary }

        // Text histogram — a trailing run of `+`/`-`, additions before
        // deletions. Walk back over the bar, then color the `+` segment
        // green and the `-` segment red.
        var graphStart = stats.endIndex
        while graphStart > stats.startIndex {
            let prev = stats.index(before: graphStart)
            guard stats[prev] == "+" || stats[prev] == "-" else { break }
            graphStart = prev
        }
        guard graphStart < stats.endIndex else { return line }   // no bar (e.g. ` 0`)
        let head = stats[..<graphStart]
        let graph = stats[graphStart...]
        let plusEnd = graph.firstIndex { $0 != "+" } ?? graph.endIndex
        return prefix + head + added(String(graph[..<plusEnd]))
            + removed(String(graph[plusEnd...]))
    }

    /// Recolor a binary diffstat tail — ` Bin <old> -> <new> bytes` —
    /// with the old size red and the new size green, matching real git.
    /// Returns nil when `stats` isn't that exact shape, so the caller
    /// falls through to the histogram path and the line stays plain.
    ///
    /// A pure-stdlib scan (no `NSRegularExpression`) so it stays
    /// portable to every platform GitKit builds on. libgit2 emits the
    /// same single-spaced ` Bin <old> -> <new> bytes` form real git
    /// does, so rebuilding with single spaces is byte-exact.
    private func colorizeBinaryStat(_ stats: String) -> String? {
        let lead = stats.prefix { $0 == " " }
        let body = stats[lead.endIndex...]
        guard body.hasPrefix("Bin "), body.hasSuffix(" bytes") else { return nil }
        let core = body.dropFirst("Bin ".count).dropLast(" bytes".count)  // "<old> -> <new>"
        let parts = String(core).components(separatedBy: " -> ")
        guard parts.count == 2,
              let old = parts.first, !old.isEmpty, old.allSatisfy(\.isNumber),
              let new = parts.last, !new.isEmpty, new.allSatisfy(\.isNumber)
        else { return nil }
        return String(lead) + "Bin " + removed(old) + " -> " + added(new) + " bytes"
    }
}

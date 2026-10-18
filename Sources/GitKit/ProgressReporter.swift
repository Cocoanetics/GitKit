import Foundation
import CGitKit

/// Progress-output plumbing for the network operations
/// (``Repository/clone(from:to:depth:singleBranch:branch:credentials:progress:)``,
/// fetch, push).
public enum GitProgress {
    /// The default progress sink: the process's real standard error.
    /// Embedders that virtualise IO (e.g. shell hosts) pass their own
    /// sink to the operation instead.
    public static let standardError: @Sendable (String) -> Void = { text in
        FileHandle.standardError.write(Data(text.utf8))
    }
}

/// A fetch's line for one ref, held until the fetch is done: git
/// orders the lines and sizes their ref column once it knows them all.
struct FetchSummaryLine {
    enum Kind { case deleted, fetchHead, update }
    let kind: Kind
    /// `*` new, ` ` fast-forward, `+` forced, `t` tag update,
    /// `-` deleted.
    let flag: Character
    /// `[new branch]`, `abc1234..def5678`, `branch` (FETCH_HEAD), …
    let summary: String
    /// The remote ref, e.g. `refs/heads/main` (empty when deleted).
    let remoteRef: String
    /// The remote ref as shown (`main`, `(none)`).
    let remote: String
    /// The local ref, e.g. `refs/remotes/origin/main` (`FETCH_HEAD`).
    let localRef: String
    /// The local ref as shown (`origin/main`).
    let local: String
    /// Shown after the line in parentheses (`forced update`).
    var note: String?
}

/// Formats and emits `remote: …` / `Receiving objects: …` /
/// `From <url>` / `<oldsha>..<newsha> <ref> -> <tracking>` lines to
/// stderr. Mirrors what real git prints during fetch / clone / push.
///
/// Each network-op (`fetch`/`clone`/`push`) builds one of these,
/// passes it through `withCallbacksPayload` to install C trampolines on
/// `git_remote_callbacks`, and the trampolines mutate it via the
/// shared `payload` raw pointer.
struct ProgressReporter {
    /// `From <url>` / `To <url>` header — emitted lazily, exactly once,
    /// just before the first per-ref summary line.
    var headerURL: String?
    var headerEmitted = false
    /// `From` (fetch) vs `To` (push) — the header verb.
    let direction: Direction
    /// Where progress text goes. Defaults to the process's stderr; an
    /// embedder (e.g. a shell host) injects its own sink to route the
    /// output through its IO plumbing instead.
    let output: @Sendable (String) -> Void

    enum Direction { case fetch, push }

    init(
        headerURL: String?,
        direction: Direction,
        output: @escaping @Sendable (String) -> Void = ProgressReporter.standardError
    ) {
        self.headerURL = headerURL
        self.direction = direction
        self.output = output
    }

    /// Default sink: the process's real standard error.
    static let standardError = GitProgress.standardError

    /// Pending per-ref summary lines. We collect them inside the
    /// callbacks (which fire mid-operation) and flush them in the
    /// caller's `defer` so output isn't interleaved with transfer
    /// progress. Real git does the same.
    var refLines: [String] = []

    /// What a push is about to do to each remote ref, keyed by the
    /// destination ref name — recorded at push negotiation, so the
    /// summary can print `old..new` like git.
    var pushUpdates: [String: PushUpdate] = [:]
    /// The pushing repository, to tell a forced update from a
    /// fast-forward.
    var repository: OpaquePointer?
    /// How many hex digits object IDs show in the push summary
    /// (`core.abbrev`).
    var abbreviation = 7
    /// Each pushed ref's source as the caller spelled it (`HEAD`,
    /// `main`), keyed by the destination ref; git shows it instead of
    /// the ref it resolves to.
    var typedSources: [String: String] = [:]
    /// The updates the remote refused, with its reasons.
    var remoteRejections: [PushRejectedError.Rejection] = []

    /// The fetch's lines, in the order to print them once ordered.
    var fetchLines: [FetchSummaryLine] = []

    /// `fetchLines` as git prints them (`format_display`). The ref column
    /// is at least 10 wide, widened for an update's remote ref when its
    /// line still fits 80 columns.
    var formattedFetchLines: [String] {
        let refWidth = fetchLines
            .filter { $0.kind == .update && 21 + $0.remote.count + 4 + $0.local.count < 80 }
            .map(\.remote.count).reduce(10, max)
        let summaryWidth = 2 * abbreviation + 3
        func padded(_ text: String, _ width: Int) -> String {
            text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
        }
        return fetchLines.map { line in
            let note = line.note.map { "  (\($0))" } ?? ""
            return " \(line.flag) \(padded(line.summary, summaryWidth)) "
                + "\(padded(line.remote, refWidth)) -> \(line.local)\(note)"
        }
    }

    struct PushUpdate {
        /// The local ref being pushed, e.g. `refs/heads/main`.
        let source: String
        /// The remote ref's current and new object IDs; `nil` for a ref
        /// being created or deleted.
        let oldID: git_oid?
        let newID: git_oid?
    }

    /// `Receiving objects:` / `Writing objects:` last printed percent.
    /// Only re-emit when the integer percent advances, to match real
    /// git's roughly-100-updates-per-phase pacing.
    var lastTransferPct: Int = -1
    /// Same throttle for `Resolving deltas:`.
    var lastDeltaPct: Int = -1

    /// Sideband state: whether we're currently in the middle of a line
    /// (i.e. saw text but no terminator yet) so the next chunk doesn't
    /// re-prepend `remote: `. Set when the previous chunk ended without
    /// `\r` or `\n`.
    var sidebandLineOpen = false

    /// `Counting/Compressing objects:` for push (server pack-building).
    /// Throttle by integer percent + emit the `, done.\n` terminator on
    /// every stage completion.
    var lastPackStage: Int32 = -1
    var lastPackPct: Int = -1

    /// `Writing objects:` for push (client pushes the pack).
    var lastPushTransferPct: Int = -1

    /// Suppress sideband / transfer / pack progress for local URLs.
    /// libgit2's local transport fires the callbacks even when real git
    /// stays silent — set this to mute them. Per-ref summary lines and
    /// header still emit.
    var suppressTransferProgress = false

    func write(_ s: String) {
        output(s)
    }

    /// Emit the `From <url>\n` / `To <url>\n` header on first call.
    mutating func emitHeaderIfNeeded() {
        guard !headerEmitted, let header else { return }
        headerEmitted = true
        write(header)
    }

    /// `From <url>\n` / `To <url>\n`, the URL shown as git shows it.
    private var header: String? {
        guard let url = headerURL else { return nil }
        return direction == .fetch
            ? "From \(Self.fetchDisplayURL(url))\n"
            : "To \(Self.anonymizedURL(url))\n"
    }

    /// `url` without the credentials it may carry, as git shows remotes
    /// (`transport_anonymize_url`): `https://user:token@host/r` becomes
    /// `https://host/r`, `git@host:r` becomes `host:r`. Local paths stay.
    static func anonymizedURL(_ url: String) -> String {
        guard let at = url.firstIndex(of: "@") else { return url }
        let colon = url.firstIndex(of: ":")
        let slash = url.firstIndex(of: "/")
        // A local path: no colon, or a slash before the first one.
        guard let colon, slash.map({ $0 > colon }) ?? true else { return url }
        let rest = url[url.index(after: at)...]
        guard let scheme = url.range(of: "://") else {
            // `me@there:/path` — the `@` has to come before a colon.
            return rest.contains(":") ? String(rest) : url
        }
        let schemeName = url[..<scheme.lowerBound]
        guard schemeName.allSatisfy({ $0.isLetter || $0.isNumber || "+.-".contains($0) }) else {
            return url
        }
        // An `@` past the first slash is part of the path.
        if let pathSlash = url[scheme.upperBound...].firstIndex(of: "/"), pathSlash < at {
            return url
        }
        return String(url[..<scheme.upperBound]) + rest
    }

    /// The URL in a fetch's `From` line: anonymized, without trailing
    /// slashes and a `.git` suffix (builtin/fetch.c).
    static func fetchDisplayURL(_ url: String) -> String {
        var shown = Substring(anonymizedURL(url))
        while shown.count > 1, shown.hasSuffix("/") { shown = shown.dropLast() }
        if shown.count > 5, shown.hasSuffix(".git") { shown = shown.dropLast(4) }
        return String(shown)
    }

    /// True if `url` points at a local repo (file:// or a plain path
    /// with no scheme). libgit2's local transport fires transfer /
    /// sideband callbacks where real git stays silent, so we mute them
    /// for these URLs to match real-git's local-clone/fetch output.
    static func isLocalURL(_ url: String?) -> Bool {
        guard let url else { return false }
        if url.hasPrefix("file://") { return true }
        // Schemed remote (http://, https://, ssh://, git@host:…) is
        // never local. Bare paths (no `://` and either absolute or
        // present on disk) are.
        if url.contains("://") { return false }
        if url.contains("@") && url.contains(":") { return false } // ssh shorthand
        if url.hasPrefix("/") { return true }
        return FileManager.default.fileExists(atPath: url)
    }

    /// The `From`/`To` header and the pending per-ref summary lines, as
    /// ``flushRefLines()`` writes them.
    var refSummary: String {
        guard !refLines.isEmpty else { return "" }
        return (header ?? "") + refLines.map { $0 + "\n" }.joined()
    }

    /// Flush any pending per-ref summary lines. Caller invokes this
    /// after the network op completes.
    mutating func flushRefLines() {
        refLines += formattedFetchLines
        fetchLines.removeAll()
        guard !refLines.isEmpty else { return }
        emitHeaderIfNeeded()
        for line in refLines {
            write(line + "\n")
        }
        refLines.removeAll(keepingCapacity: false)
    }
}

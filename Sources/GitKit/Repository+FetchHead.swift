import Foundation
import CGitKit

extension Repository {

    /// A fetch's `lines` in git's order, with a line added for each ref
    /// it stored in FETCH_HEAD alone (` * branch  main -> FETCH_HEAD`).
    ///
    /// git prints pruned refs first, then walks the fetched refs in
    /// passes (builtin/fetch.c, `store_updated_refs`): the ref to merge,
    /// the other refs `refspecs` fetch, then what came along with them —
    /// auto-followed tags and the opportunistic update of a
    /// remote-tracking ref — each pass in ref-name order.
    func orderedFetchLines(
        _ lines: [FetchSummaryLine], refspecs: [String]
    ) -> [FetchSummaryLine] {
        // With nothing to fetch by, libgit2 fetches HEAD.
        let parsed: [(spec: OpaquePointer, mapped: Bool)] = (refspecs.isEmpty ? ["HEAD"] : refspecs)
            .compactMap { text in
                var spec: OpaquePointer?
                guard !text.hasPrefix("^"), git_refspec_parse(&spec, text, 1) == 0,
                      let spec
                else { return nil }
                return (spec, git_refspec_dst(spec).map { $0.pointee != 0 } ?? false)
            }
        defer { parsed.forEach { git_refspec_free($0.spec) } }
        func fetched(_ name: String, mapped: Bool) -> Bool {
            parsed.contains { $0.mapped == mapped && Self.refspec($0.spec, fetches: name) }
        }

        let entries = fetchHeadEntries()
        let toMerge = Set(entries.filter(\.merge).map(\.name))
        var ranked: [(rank: Int, key: String, line: FetchSummaryLine)] = []
        for line in lines {
            switch line.kind {
            case .deleted:
                ranked.append((0, line.local, line))
            case .update:
                let rank = fetched(line.remoteRef, mapped: true)
                    ? (toMerge.contains(line.remoteRef) ? 1 : 2) : 3
                ranked.append((rank, line.remoteRef, line))
            case .fetchHead:
                continue
            }
        }
        for entry in entries
        where fetched(entry.name, mapped: false) && !fetched(entry.name, mapped: true) {
            let (kind, what) = Self.fetchHeadDescription(of: entry.name)
            ranked.append((entry.merge ? 1 : 2, entry.name, FetchSummaryLine(
                kind: .fetchHead, flag: "*", summary: kind,
                remoteRef: entry.name, remote: what, local: "FETCH_HEAD")))
        }
        return ranked.enumerated()
            .sorted { ($0.element.rank, $0.element.key, $0.offset) < ($1.element.rank, $1.element.key, $1.offset) }
            .map(\.element.line)
    }

    /// What the remote is configured to fetch (`remote.<name>.fetch`).
    func configuredFetchRefspecs(_ remote: OpaquePointer?) throws -> [String] {
        var array = git_strarray()
        try check(git_remote_get_fetch_refspecs(&array, remote))
        defer { git_strarray_dispose(&array) }
        return (0..<array.count).compactMap { index in
            array.strings?[index].map { String(cString: $0) }
        }
    }

    /// FETCH_HEAD's refs, in order: the remote ref's name (`HEAD` for
    /// the remote's HEAD) and whether it's the one to merge.
    private func fetchHeadEntries() -> [(name: String, merge: Bool)] {
        final class Entries { var list: [(name: String, merge: Bool)] = [] }
        let entries = Entries()
        let payload = Unmanaged.passUnretained(entries).toOpaque()
        _ = git_repository_fetchhead_foreach(repo, { name, _, _, isMerge, payload in
            guard let payload else { return 0 }
            let entries = Unmanaged<Entries>.fromOpaque(payload).takeUnretainedValue()
            let text = name.map { String(cString: $0) } ?? ""
            entries.list.append((text.isEmpty ? "HEAD" : text, isMerge != 0))
            return 0
        }, payload)
        return entries.list
    }

    /// Whether `spec` fetches remote ref `name`: its source matches it,
    /// as written or as git expands a short name (`main` for
    /// `refs/heads/main`).
    private static func refspec(_ spec: OpaquePointer, fetches name: String) -> Bool {
        if git_refspec_src_matches(spec, name) == 1 { return true }
        guard let source = git_refspec_src(spec).map({ String(cString: $0) }),
              !source.contains("*")
        else { return false }
        return ["refs/", "refs/tags/", "refs/heads/", "refs/remotes/"]
            .contains { $0 + source == name }
    }

    /// The summary and name git shows for a FETCH_HEAD entry.
    private static func fetchHeadDescription(of name: String) -> (kind: String, what: String) {
        for (prefix, kind) in [("refs/heads/", "branch"), ("refs/tags/", "tag"),
                               ("refs/remotes/", "remote-tracking branch")]
        where name.hasPrefix(prefix) {
            return (kind, String(name.dropFirst(prefix.count)))
        }
        return ("branch", name)
    }
}

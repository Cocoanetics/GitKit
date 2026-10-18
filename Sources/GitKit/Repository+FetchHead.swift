import Foundation
import CGitKit

/// A fetch's summary line with where git prints it: by pass (`rank`),
/// then by the refspec it came from, then by ref name.
private struct RankedFetchLine {
    let rank: Int
    let refspec: Int
    /// The ref name as bytes, as git orders ref names.
    let key: [UInt8]
    let line: FetchSummaryLine

    init(rank: Int, refspec: Int, key: String, line: FetchSummaryLine) {
        self.rank = rank
        self.refspec = refspec
        self.key = Array(key.utf8)
        self.line = line
    }
}

extension Repository {

    /// A fetch's `lines` in git's order, with a line added for each ref
    /// it stored in FETCH_HEAD alone (` * branch  main -> FETCH_HEAD`).
    ///
    /// git prints pruned refs first, then walks the fetched refs in
    /// passes (builtin/fetch.c, `store_updated_refs`): the ref to merge,
    /// the other refs `refspecs` fetch and the tags that came along, then
    /// the opportunistic updates of remote-tracking refs, each in
    /// ref-name order.
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
        // An update the refspecs asked for, as opposed to an
        // opportunistic one of another remote-tracking ref.
        func storer(of name: String, into local: String) -> Int? {
            parsed.firstIndex {
                $0.mapped && Self.refspec($0.spec, fetches: name)
                    && Self.refspec($0.spec, maps: name, to: local)
            }
        }

        let entries = fetchHeadEntries()
        // Ref names as bytes, as git compares them.
        let toMerge = Set(entries.filter(\.merge).map { Array($0.name.utf8) })
        var ranked: [RankedFetchLine] = []
        for line in lines.map({ Self.qualified($0, by: entries.map(\.name)) }) {
            switch line.kind {
            case .deleted:
                // By the full local name, as git walks its refs for stale
                // ones (get_stale_heads).
                ranked.append(.init(rank: 0, refspec: 0, key: line.localRef, line: line))
            case .update:
                if let refspec = storer(of: line.remoteRef, into: line.localRef) {
                    ranked.append(.init(rank: toMerge.contains(Array(line.remoteRef.utf8)) ? 1 : 2,
                                        refspec: refspec, key: line.remoteRef, line: line))
                } else if line.remoteRef.hasPrefix("refs/tags/") {
                    // Followed tags come next…
                    ranked.append(.init(rank: 3, refspec: 0, key: line.remoteRef, line: line))
                } else {
                    // …then the opportunistic updates, by the refspec
                    // that fetched each ref.
                    let refspec = parsed.firstIndex { Self.refspec($0.spec, fetches: line.remoteRef) }
                    ranked.append(.init(rank: 4, refspec: refspec ?? parsed.count,
                                        key: line.remoteRef, line: line))
                }
            case .fetchHead:
                continue
            }
        }
        // Each source-only refspec gets a FETCH_HEAD line for each ref it
        // fetched, in refspec order: `main dev main` lists `main` twice,
        // as FETCH_HEAD does, while `main main:copy` lists it once.
        // FETCH_HEAD holds a ref once per refspec, so the n-th refspec to
        // fetch a ref takes its n-th entry (and with it, whether it's to
        // be merged). Ref names compare as bytes, as git compares them.
        let occurrencesByName = Dictionary(grouping: entries) { Array($0.name.utf8) }
        var taken: [[UInt8]: Int] = [:]
        for (index, refspec) in parsed.enumerated() {
            var shown = Set<[UInt8]>()
            for entry in entries
            where Self.refspec(refspec.spec, fetches: entry.name) && shown.insert(Array(entry.name.utf8)).inserted {
                let name = Array(entry.name.utf8)
                let occurrences = occurrencesByName[name] ?? [entry]
                let occurrence = occurrences[min(taken[name, default: 0], occurrences.count - 1)]
                taken[name, default: 0] += 1
                guard !refspec.mapped else { continue }
                let (kind, what) = Self.fetchHeadDescription(of: entry.name)
                let line = FetchSummaryLine(
                    kind: .fetchHead, flag: "*", summary: kind,
                    remoteRef: entry.name, remote: what, localRef: "FETCH_HEAD", local: "FETCH_HEAD")
                ranked.append(.init(rank: occurrence.merge ? 1 : 2, refspec: index, key: entry.name, line: line))
            }
        }
        return ranked.enumerated()
            .sorted { lhs, rhs in
                let (a, b) = (lhs.element, rhs.element)
                if (a.rank, a.refspec) != (b.rank, b.refspec) {
                    return (a.rank, a.refspec) < (b.rank, b.refspec)
                }
                if a.key != b.key { return a.key.lexicographicallyPrecedes(b.key) }
                return lhs.offset < rhs.offset
            }
            .map(\.element.line)
    }

    /// Whether `refspec` stores what it fetches in a local ref: it has a
    /// destination (`main:refs/heads/x`, a wildcard mapping).
    static func storesFetchedRef(_ refspec: String) -> Bool {
        guard !refspec.hasPrefix("^"), let colon = refspec.lastIndex(of: ":") else { return false }
        return refspec.index(after: colon) < refspec.endIndex
    }

    /// A boolean config value as git reads one (`git_config_bool`):
    /// `true`/`yes`/`on`, `false`/`no`/`off`, any integer (`00` and `-0`
    /// are false), a key without a value (true) or an empty one (false).
    /// `nil` when unset; anything else throws git's "bad boolean config
    /// value".
    func configFlag(_ name: String) throws -> Bool? {
        var config: OpaquePointer?
        try check(git_repository_config_snapshot(&config, repo))
        defer { git_config_free(config) }
        var entry: UnsafeMutablePointer<git_config_entry>?
        let result = git_config_get_entry(&entry, config, name)
        if result == GIT_ENOTFOUND.rawValue { return nil }
        try check(result)
        defer { git_config_entry_free(entry) }
        // The entry keeps a missing value apart from an empty one, which
        // configGet can't; libgit2's parser reads it as git does.
        var flag: Int32 = 0
        guard git_config_parse_bool(&flag, entry?.pointee.value) == 0 else {
            let value = entry?.pointee.value.map { String(cString: $0) } ?? ""
            throw Libgit2Error(
                code: GIT_ERROR.rawValue, klass: Int32(GIT_ERROR_CONFIG.rawValue),
                message: "bad boolean config value '\(value)' for '\(Self.canonicalConfigKey(name))'")
        }
        return flag != 0
    }

    /// A config key as git spells it in messages: section and variable
    /// lowercased, a subsection as written (`fetch.showforcedupdates`,
    /// `remote.Origin.url`).
    static func canonicalConfigKey(_ name: String) -> String {
        guard let first = name.firstIndex(of: "."), let last = name.lastIndex(of: "."), first < last else {
            return name.lowercased()
        }
        return name[..<first].lowercased() + name[first..<last] + name[last...].lowercased()
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
    static func refspec(_ spec: OpaquePointer, fetches name: String) -> Bool {
        if git_refspec_src_matches(spec, name) == 1 { return true }
        guard let source = git_refspec_src(spec).map({ String(cString: $0) }),
              !source.contains("*")
        else { return false }
        return ["refs/", "refs/tags/", "refs/heads/", "refs/remotes/"]
            .contains { ($0 + source).utf8.elementsEqual(name.utf8) }
    }

    /// Whether `spec` sends remote ref `name` to local ref `local`, a
    /// short destination taken as git expands it.
    private static func refspec(_ spec: OpaquePointer, maps name: String, to local: String) -> Bool {
        let destination: String
        if let source = git_refspec_src(spec), String(cString: source).contains("*") {
            var buffer = git_buf()
            defer { git_buf_dispose(&buffer) }
            guard git_refspec_transform(&buffer, spec, name) == 0, let pointer = buffer.ptr else {
                return false
            }
            destination = String(cString: pointer)
        } else {
            // libgit2's transform wants the source as written (`dev`, not
            // `refs/heads/dev`); a plain refspec has just the one target.
            guard let dst = git_refspec_dst(spec) else { return false }
            destination = String(cString: dst)
        }
        return ["", "refs/", "refs/heads/", "refs/tags/", "refs/remotes/"]
            .contains { ($0 + destination).utf8.elementsEqual(local.utf8) }
    }

    /// `line` with a remote ref given as typed in a refspec (`main`)
    /// spelled out as FETCH_HEAD names it (`refs/heads/main`), which also
    /// tells what kind of ref a new one is.
    private static func qualified(_ line: FetchSummaryLine, by names: [String]) -> FetchSummaryLine {
        guard line.kind == .update, !line.remoteRef.hasPrefix("refs/"),
              let full = names.first(where: { name in
                  ["refs/", "refs/tags/", "refs/heads/", "refs/remotes/"]
                      .contains { ($0 + line.remoteRef).utf8.elementsEqual(name.utf8) }
              })
        else { return line }
        var line = line
        line.remoteRef = full
        if line.summary == "[new ref]" {
            line.summary = full.hasPrefix("refs/heads/") ? "[new branch]"
                : full.hasPrefix("refs/tags/") ? "[new tag]" : "[new ref]"
        }
        return line
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

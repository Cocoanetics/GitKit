import Foundation
import CGitKit

/// A fetch that left some local refs as they were, because git's rules
/// refuse the update: a tag a non-forced refspec would move (`would
/// clobber existing tag`). Everything else was fetched and updated, and
/// each refused ref's summary line has been printed; git says nothing
/// more, and exits with status 1.
public struct FetchRejectedError: Error, LocalizedError, Sendable, Equatable {
    /// The local refs left alone, e.g. `refs/tags/v1`.
    public let refs: [String]

    public var errorDescription: String? {
        "some local refs could not be updated"
    }
}

extension Repository {

    /// The tag refspec git adds for `--tags` (`tag_refspec`).
    static let allTagsRefspec = "refs/tags/*:refs/tags/*"

    /// Every local tag and the object it points at, by name as bytes.
    func localTagObjects() throws -> [[UInt8]: git_oid] {
        var iterator: UnsafeMutablePointer<git_reference_iterator>?
        try check(git_reference_iterator_glob_new(&iterator, repo, "refs/tags/*"))
        defer { git_reference_iterator_free(iterator) }
        var tags: [[UInt8]: git_oid] = [:]
        while true {
            var ref: OpaquePointer?
            let rc = git_reference_next(&ref, iterator)
            if rc == GIT_ITEROVER.rawValue { break }
            try check(rc)
            defer { git_reference_free(ref) }
            guard let name = git_reference_name(ref), let target = git_reference_target(ref) else {
                continue
            }
            tags[Array(String(cString: name).utf8)] = target.pointee
        }
        return tags
    }

    /// Settle the tags a fetch moved the way git would have
    /// (`fetch.c`'s `update_local_ref` and `apply_negative_refspecs`),
    /// libgit2 moving them by other rules:
    /// - a tag this repository has moves only when a forced refspec maps
    ///   a remote ref onto it. One a non-forced refspec maps elsewhere —
    ///   the tag refspec `--tags` adds is one — stays, refused as `would
    ///   clobber existing tag`; libgit2 moves some such tags and leaves
    ///   others, so each is checked here;
    /// - with all tags fetched, a tag a negative refspec excludes isn't
    ///   fetched at all, which libgit2's pass over the tags ignores.
    ///
    /// Returns the tags refused, and the ones excluded, whose lines go
    /// from FETCH_HEAD.
    func settleFetchedTags(
        before: [[UInt8]: git_oid], remoteRefs: RemoteRefs, refspecs: [String], allTags: Bool,
        lines: inout [FetchSummaryLine]
    ) throws -> (refused: [String], excluded: [String]) {
        let texts = refspecs + (allTags ? [Self.allTagsRefspec] : [])
        let specs: [(spec: OpaquePointer, text: String)] = texts.compactMap { text in
            var spec: OpaquePointer?
            guard git_refspec_parse(&spec, text, 1) == 0, let spec else { return nil }
            return (spec, text)
        }
        defer { specs.forEach { git_refspec_free($0.spec) } }
        let negatives = specs.filter { $0.text.hasPrefix("^") }
        func isExcluded(_ name: String) -> Bool {
            negatives.contains { git_refspec_src_matches_negative($0.spec, name) == 1 }
        }
        /// The local tags the fetch's refspecs map remote ref `name`
        /// onto, each with whether a forced refspec does.
        func tags(for name: String) -> [(tag: String, forced: Bool)] {
            specs.compactMap { spec in
                // A short source (`main:refs/tags/x`) fetches the ref git
                // expands it to.
                guard !spec.text.hasPrefix("^"), let dst = git_refspec_dst(spec.spec), dst.pointee != 0,
                      Self.refspec(spec.spec, fetches: name)
                else { return nil }
                let tag: String
                if let source = git_refspec_src(spec.spec), String(cString: source).contains("*") {
                    var buffer = git_buf()
                    defer { git_buf_dispose(&buffer) }
                    guard git_refspec_transform(&buffer, spec.spec, name) == 0, let pointer = buffer.ptr else {
                        return nil
                    }
                    tag = String(cString: pointer)
                } else {
                    tag = String(cString: dst)
                }
                return tag.hasPrefix("refs/tags/") ? (tag, git_refspec_force(spec.spec) == 1) : nil
            }
        }
        /// Put `tag` back as `before` had it, or gone if it had none.
        func restore(_ tag: String) throws {
            var now = git_oid()
            let exists = git_reference_name_to_id(&now, repo, tag) == 0
            if var old = before[Array(tag.utf8)] {
                guard !exists || git_oid_equal(&now, &old) == 0 else { return }
                var ref: OpaquePointer?
                try check(git_reference_create(&ref, repo, tag, &old, 1, nil))
                git_reference_free(ref)
            } else if exists {
                try check(git_reference_remove(repo, tag))
            }
        }

        var refused: [String] = []
        var excluded: [String] = []
        for name in remoteRefs.names {
            guard var remote = remoteRefs.object(of: name) else { continue }
            if allTags, name.hasPrefix("refs/tags/"), isExcluded(name) {
                try restore(name)
                lines.removeAll { $0.localRef.utf8.elementsEqual(name.utf8) }
                excluded.append(name)
                continue
            }
            let mapped = tags(for: name)
            // Each tag the ref goes to is settled on its own; a forced
            // refspec to that same tag lets it move.
            for tag in mapped.map(\.tag) where !mapped.contains(where: { $0.tag == tag && $0.forced }) {
                guard var old = before[Array(tag.utf8)], git_oid_equal(&old, &remote) == 0,
                      !refused.contains(tag)
                else { continue }
                try restore(tag)
                lines.removeAll { $0.localRef.utf8.elementsEqual(tag.utf8) }
                lines.append(.init(
                    kind: .update, flag: "!", summary: "[rejected]",
                    remoteRef: name, remote: shortRefName(name), localRef: tag, local: shortRefName(tag),
                    note: "would clobber existing tag"))
                refused.append(tag)
            }
        }
        return (refused, excluded)
    }

    /// Drop the tags libgit2 followed that git wouldn't have. git follows
    /// a tag when what it points at is in the repository once the fetch
    /// is in (`find_non_local_tags`, then `backfill_tags`); libgit2 asks
    /// the remote for every tag's objects, so it ends up with, and
    /// follows, all of them. A followed tag — a `[new tag]` no refspec
    /// asked for — is kept here only if a ref that isn't a tag, or what
    /// FETCH_HEAD holds, reaches what it points at. Returns the tags
    /// dropped.
    func dropUnfollowableTags(refspecs: [String], lines: inout [FetchSummaryLine]) throws -> [String] {
        let specs: [OpaquePointer] = refspecs.filter { !$0.hasPrefix("^") }.compactMap { text in
            var spec: OpaquePointer?
            return git_refspec_parse(&spec, text, 1) == 0 ? spec : nil
        }
        defer { specs.forEach { git_refspec_free($0) } }
        let followed = lines.filter { line in
            line.kind == .update && line.summary == "[new tag]"
                && !specs.contains { git_refspec_src_matches($0, line.remoteRef) == 1 }
        }
        guard !followed.isEmpty else { return [] }

        // The tips that count: every ref but the tags, and what FETCH_HEAD
        // holds but tags.
        var tips: [git_oid] = []
        var iterator: UnsafeMutablePointer<git_reference_iterator>?
        try check(git_reference_iterator_new(&iterator, repo))
        defer { git_reference_iterator_free(iterator) }
        while true {
            var ref: OpaquePointer?
            let rc = git_reference_next(&ref, iterator)
            if rc == GIT_ITEROVER.rawValue { break }
            try check(rc)
            defer { git_reference_free(ref) }
            guard let name = git_reference_name(ref), !String(cString: name).hasPrefix("refs/tags/"),
                  let target = git_reference_target(ref)
            else { continue }
            tips.append(target.pointee)
        }
        final class Heads { var oids: [git_oid] = [] }
        let heads = Heads()
        _ = git_repository_fetchhead_foreach(repo, { name, _, oid, _, payload in
            // A tag's own entry doesn't vouch for it.
            guard let payload, let oid,
                  !(name.map { String(cString: $0).hasPrefix("refs/tags/") } ?? false)
            else { return 0 }
            Unmanaged<Heads>.fromOpaque(payload).takeUnretainedValue().oids.append(oid.pointee)
            return 0
        }, Unmanaged.passUnretained(heads).toOpaque())
        tips += heads.oids

        var dropped: [String] = []
        var snapshot: Set<String>?
        for line in followed {
            var object: OpaquePointer?
            guard git_revparse_single(&object, repo, line.localRef + "^{}") == 0,
                  var target = git_object_id(object)?.pointee
            else { git_object_free(object); continue }
            let type = git_object_type(object)
            git_object_free(object)
            let reached: Bool
            if type == GIT_OBJECT_COMMIT {
                reached = tips.contains { tip in var tip = tip; return git_oid_equal(&tip, &target) == 1 }
                    || git_graph_reachable_from_any(repo, &target, tips, tips.count) == 1
            } else {
                // A tree or blob: kept when the tips' trees hold it.
                if snapshot == nil { snapshot = tipTrees(tips) }
                reached = snapshot?.contains(Self.hex(target)) == true
            }
            guard !reached else { continue }
            try check(git_reference_remove(repo, line.localRef))
            dropped.append(line.localRef)
        }
        lines.removeAll { line in dropped.contains { $0.utf8.elementsEqual(line.localRef.utf8) } }
        try removeFetchHeadTags(dropped)
        return dropped
    }

    /// Every tree and blob the commits among `tips` hold, as hex IDs.
    /// git follows a tag of a tree or blob it has once the fetch is in;
    /// libgit2 fetched every tag's objects, so the tips' snapshots stand
    /// in for what git would have.
    private func tipTrees(_ tips: [git_oid]) -> Set<String> {
        final class Found { var ids = Set<String>() }
        let found = Found()
        for var tip in tips {
            var commit: OpaquePointer?
            guard git_commit_lookup(&commit, repo, &tip) == 0 else { continue }
            defer { git_commit_free(commit) }
            var tree: OpaquePointer?
            guard git_commit_tree(&tree, commit) == 0 else { continue }
            defer { git_tree_free(tree) }
            guard let root = git_tree_id(tree)?.pointee,
                  found.ids.insert(Self.hex(root)).inserted
            else { continue }
            _ = git_tree_walk(tree, GIT_TREEWALK_PRE, { _, entry, payload in
                guard let entry, let payload, let id = git_tree_entry_id(entry)?.pointee else { return 0 }
                Unmanaged<Found>.fromOpaque(payload).takeUnretainedValue().ids.insert(Repository.hex(id))
                return 0
            }, Unmanaged.passUnretained(found).toOpaque())
        }
        return found.ids
    }

    static func hex(_ oid: git_oid) -> String {
        var oid = oid
        return String(cString: git_oid_tostr_s(&oid))
    }

    /// Take `tags`' not-for-merge lines out of FETCH_HEAD.
    private func removeFetchHeadTags(_ tags: [String]) throws {
        guard !tags.isEmpty, let gitDir = git_repository_path(repo) else { return }
        let url = URL(fileURLWithPath: String(cString: gitDir)).appendingPathComponent("FETCH_HEAD")
        guard let data = try? Data(contentsOf: url) else { return }
        let marks = tags.map { Array("\tnot-for-merge\ttag '\(shortRefName($0))' of ".utf8) }
        var output = Data()
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        where !marks.contains(where: { Array(line).firstRange(of: $0) != nil }) {
            output.append(contentsOf: line)
            output.append(UInt8(ascii: "\n"))
        }
        try output.write(to: url)
    }

    /// FETCH_HEAD as git writes it for a fetch of all tags: the tags
    /// after what the other refspecs fetched, once each, in the remote's
    /// order (`tags`), and none a negative refspec excludes. libgit2
    /// writes them first, and again for some of the refspecs it applies.
    func reorderFetchHeadForAllTags(tags: [String], excluding excluded: [String]) throws {
        guard !tags.isEmpty, let gitDir = git_repository_path(repo) else { return }
        let url = URL(fileURLWithPath: String(cString: gitDir)).appendingPathComponent("FETCH_HEAD")
        guard let data = try? Data(contentsOf: url) else { return }
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).map(Array.init)
        // `<oid>\tnot-for-merge\ttag 'v1' of <url>`
        func mark(_ tag: String) -> [UInt8] { Array("\tnot-for-merge\ttag '\(shortRefName(tag))' of ".utf8) }
        func isLine(_ line: [UInt8], of tag: String) -> Bool { line.firstRange(of: mark(tag)) != nil }
        let others = lines.filter { line in !tags.contains { isLine(line, of: $0) } }
        let tagLines = tags.filter { !excluded.contains($0) }
            .compactMap { tag in lines.first { isLine($0, of: tag) } }
        var output = Data()
        for line in others + tagLines {
            output.append(contentsOf: line)
            output.append(UInt8(ascii: "\n"))
        }
        try output.write(to: url)
    }
}

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

/// The objects a repository had before a fetch: its loose objects, the
/// packs it had then (`objects/pack/*.idx`), a fetch writing what it
/// downloads as a new pack, and what its alternates hold.
final class ObjectsBefore {
    private var odb: OpaquePointer?

    init(repository: OpaquePointer?, packs: Set<String>) {
        guard let path = git_repository_commondir(repository) ?? git_repository_path(repository) else { return }
        let objects = URL(fileURLWithPath: String(cString: path)).appendingPathComponent("objects")
        guard git_odb_new(&odb) == 0 else { return }
        var loose: UnsafeMutablePointer<git_odb_backend>?
        if git_odb_backend_loose(&loose, objects.path, -1, 0, 0, 0) == 0 {
            _ = git_odb_add_backend(odb, loose, 2)
        }
        for pack in packs {
            var backend: UnsafeMutablePointer<git_odb_backend>?
            let index = objects.appendingPathComponent("pack").appendingPathComponent(pack).path
            if git_odb_backend_one_pack(&backend, index) == 0 {
                _ = git_odb_add_backend(odb, backend, 1)
            }
        }
        // A fetch writes nothing into the alternates: all they hold counts.
        for alternate in Self.alternates(of: objects) {
            var loose: UnsafeMutablePointer<git_odb_backend>?
            if git_odb_backend_loose(&loose, alternate.path, -1, 0, 0, 0) == 0 {
                _ = git_odb_add_alternate(odb, loose, 2)
            }
            var packed: UnsafeMutablePointer<git_odb_backend>?
            if git_odb_backend_pack(&packed, alternate.path) == 0 {
                _ = git_odb_add_alternate(odb, packed, 1)
            }
        }
    }

    /// The object directories `objects/info/alternates` names, and theirs
    /// in turn (git follows them five deep), a relative one read against
    /// the directory that names it.
    private static func alternates(of objects: URL, depth: Int = 0) -> [URL] {
        guard depth < 5,
              let text = try? String(
                contentsOf: objects.appendingPathComponent("info/alternates"), encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .flatMap { line -> [URL] in
                let url = line.hasPrefix("/")
                    ? URL(fileURLWithPath: line)
                    : objects.appendingPathComponent(line).standardizedFileURL
                return [url] + alternates(of: url, depth: depth + 1)
            }
    }

    deinit { git_odb_free(odb) }

    func has(_ oid: git_oid) -> Bool {
        var oid = oid
        return odb.map { git_odb_exists($0, &oid) == 1 } ?? false
    }

    /// The pack indexes `repository` has now, by file name.
    static func packs(of repository: OpaquePointer?) -> Set<String> {
        guard let path = git_repository_commondir(repository) ?? git_repository_path(repository) else { return [] }
        let dir = URL(fileURLWithPath: String(cString: path)).appendingPathComponent("objects/pack")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Set(names.filter { $0.hasSuffix(".idx") })
    }
}

/// Which local tags a fetch's refspecs send each remote ref to.
private struct TagMapping {
    private let specs: [(spec: OpaquePointer, text: String)]
    private let remoteRefs: RemoteRefs
    private let owner: SpecOwner

    /// Frees the parsed refspecs with the mapping.
    private final class SpecOwner {
        var specs: [OpaquePointer] = []
        deinit { specs.forEach { git_refspec_free($0) } }
    }

    init(_ texts: [String], remoteRefs: RemoteRefs) {
        let owner = SpecOwner()
        specs = texts.compactMap { text in
            var spec: OpaquePointer?
            guard git_refspec_parse(&spec, text, 1) == 0, let spec else { return nil }
            owner.specs.append(spec)
            return (spec, text)
        }
        self.owner = owner
        self.remoteRefs = remoteRefs
    }

    /// Whether a negative refspec excludes remote ref `name`.
    func isExcluded(_ name: String) -> Bool {
        specs.contains { $0.text.hasPrefix("^") && git_refspec_src_matches_negative($0.spec, name) == 1 }
    }

    /// The local tags the refspecs map remote ref `name` onto, each with
    /// whether a forced refspec does; `explicitOnly` leaves out the tag
    /// refspec `--tags` adds.
    func tags(for name: String, explicitOnly: Bool) -> [(tag: String, forced: Bool)] {
        // A negative refspec excludes the ref from every mapping.
        guard !isExcluded(name) else { return [] }
        return specs.compactMap { spec in
            guard !spec.text.hasPrefix("^"), !(explicitOnly && spec.text == Repository.allTagsRefspec),
                  let dst = git_refspec_dst(spec.spec), dst.pointee != 0,
                  fetches(spec.spec, name)
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

    /// Whether `spec` fetches remote ref `name`. A short source
    /// (`main:refs/tags/x`) fetches the one ref git expands it to, the
    /// first of its spellings the remote has (`refs/tags/foo` before
    /// `refs/heads/foo`, as `ref_rev_parse_rules` orders them).
    private func fetches(_ spec: OpaquePointer, _ name: String) -> Bool {
        guard let source = git_refspec_src(spec).map({ String(cString: $0) }),
              !source.contains("*"), !source.hasPrefix("refs/")
        else { return Repository.refspec(spec, fetches: name) }
        let resolved = [source, "refs/\(source)", "refs/tags/\(source)", "refs/heads/\(source)",
                        "refs/remotes/\(source)", "refs/remotes/\(source)/HEAD"]
            .first { remoteRefs.object(of: $0) != nil }
        return resolved.map { $0.utf8.elementsEqual(name.utf8) } ?? false
    }
}

extension Repository {

    /// The tag refspec git adds for `--tags` (`tag_refspec`).
    static let allTagsRefspec = "refs/tags/*:refs/tags/*"

    /// Every local tag that is a symbolic ref (`refs/tags/x ->
    /// refs/heads/main`), and its target, by name as bytes.
    func localSymbolicTags() throws -> [[UInt8]: SymbolicTag] {
        var iterator: UnsafeMutablePointer<git_reference_iterator>?
        try check(git_reference_iterator_glob_new(&iterator, repo, "refs/tags/*"))
        defer { git_reference_iterator_free(iterator) }
        var tags: [[UInt8]: SymbolicTag] = [:]
        while true {
            var ref: OpaquePointer?
            let rc = git_reference_next(&ref, iterator)
            if rc == GIT_ITEROVER.rawValue { break }
            try check(rc)
            defer { git_reference_free(ref) }
            guard let name = git_reference_name(ref), let target = git_reference_symbolic_target(ref) else {
                continue
            }
            var oid = git_oid()
            let resolved = git_reference_name_to_id(&oid, repo, name) == 0 ? oid : nil
            tags[Array(String(cString: name).utf8)] = SymbolicTag(target: String(cString: target), oid: resolved)
        }
        return tags
    }

    /// A symbolic tag as it was: the ref it names, and what that held.
    struct SymbolicTag {
        let target: String
        let oid: git_oid?
    }

    /// Put `tag` back as `before` had it, or gone if it had none; a
    /// symbolic tag stays the symbolic ref it was.
    private func restoreTag(
        _ tag: String, before: [[UInt8]: git_oid], symbolicBefore: [[UInt8]: SymbolicTag]
    ) throws {
        if let symbolic = symbolicBefore[Array(tag.utf8)] {
            var ref: OpaquePointer?
            defer { git_reference_free(ref) }
            if git_reference_lookup(&ref, repo, tag) == 0, let current = git_reference_symbolic_target(ref),
               String(cString: current) == symbolic.target {
                return
            }
            var created: OpaquePointer?
            try check(git_reference_symbolic_create(&created, repo, tag, symbolic.target, 1, nil))
            git_reference_free(created)
            return
        }
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
        before: [[UInt8]: git_oid], symbolicBefore: [[UInt8]: SymbolicTag] = [:],
        remoteRefs: RemoteRefs, refspecs: [String], allTags: Bool,
        lines: inout [FetchSummaryLine]
    ) throws -> (refused: [String], excluded: [String]) {
        let mapping = TagMapping(refspecs + (allTags ? [Self.allTagsRefspec] : []), remoteRefs: remoteRefs)
        let tags = mapping.tags(for:explicitOnly:)
        func restore(_ tag: String) throws {
            try restoreTag(tag, before: before, symbolicBefore: symbolicBefore)
        }

        // The local tags the explicit refspecs store into, from any ref.
        let explicitTags = Set(remoteRefs.names.flatMap { name in
            tags(name, true).map { Array($0.tag.utf8) }
        })
        var refused: [String] = []
        // Ref names as bytes, as git compares them.
        var refusedNames = Set<[UInt8]>()
        var excluded: [String] = []
        for name in remoteRefs.names {
            guard var remote = remoteRefs.object(of: name) else { continue }
            if allTags, name.hasPrefix("refs/tags/"), mapping.isExcluded(name) {
                // Only `--tags`' own mapping is excluded: what an explicit
                // refspec stores there stays.
                if !explicitTags.contains(Array(name.utf8)) {
                    try restore(name)
                    lines.removeAll { $0.localRef.utf8.elementsEqual(name.utf8) }
                } else if let source = remoteRefs.names.first(where: { source in
                    tags(source, true).contains { $0.tag.utf8.elementsEqual(name.utf8) }
                }), var value = remoteRefs.object(of: source) {
                    // libgit2 ran the tag itself over it too: the explicit
                    // source's value goes back, with one line for it.
                    var ref: OpaquePointer?
                    try check(git_reference_create(&ref, repo, name, &value, 1, nil))
                    git_reference_free(ref)
                    var seen = false
                    lines.removeAll { line in
                        guard line.localRef.utf8.elementsEqual(name.utf8) else { return false }
                        defer { seen = true }
                        return seen || !line.remoteRef.utf8.elementsEqual(source.utf8)
                    }
                }
                excluded.append(name)
                continue
            }
            let mapped = tags(name, false)
            // Each tag the ref goes to is settled on its own; a forced
            // refspec to that same tag (by its bytes) lets it move.
            for tag in mapped.map(\.tag) where !mapped.contains(where: {
                $0.forced && $0.tag.utf8.elementsEqual(tag.utf8)
            }) {
                // git leaves a symbolic tag alone, saying nothing and
                // keeping it out of FETCH_HEAD.
                if symbolicBefore[Array(tag.utf8)] != nil {
                    try restore(tag)
                    lines.removeAll { $0.localRef.utf8.elementsEqual(tag.utf8) }
                    if allTags { excluded.append(tag) }
                    continue
                }
                guard var old = before[Array(tag.utf8)], !refusedNames.contains(Array(tag.utf8)) else {
                    continue
                }
                guard git_oid_equal(&old, &remote) == 0 else {
                    // Up to date, as git sees it; libgit2 may have read a
                    // short source as another ref and moved the tag.
                    var now = git_oid()
                    if git_reference_name_to_id(&now, repo, tag) == 0, git_oid_equal(&now, &old) == 0 {
                        try restore(tag)
                        lines.removeAll { $0.localRef.utf8.elementsEqual(tag.utf8) }
                    }
                    continue
                }
                try restore(tag)
                lines.removeAll { $0.localRef.utf8.elementsEqual(tag.utf8) }
                lines.append(.init(
                    kind: .update, flag: "!", summary: "[rejected]",
                    remoteRef: name, remote: shortRefName(name), localRef: tag, local: shortRefName(tag),
                    note: "would clobber existing tag"))
                refused.append(tag)
                refusedNames.insert(Array(tag.utf8))
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
    func dropUnfollowableTags(
        refspecs: [String], packsBefore: Set<String>, lines: inout [FetchSummaryLine]
    ) throws -> [String] {
        let specs: [OpaquePointer] = refspecs.filter { !$0.hasPrefix("^") }.compactMap { text in
            var spec: OpaquePointer?
            return git_refspec_parse(&spec, text, 1) == 0 ? spec : nil
        }
        defer { specs.forEach { git_refspec_free($0) } }
        let followed = lines.filter { line in
            line.kind == .update && line.summary == "[new tag]"
                && !specs.contains { Self.refspec($0, fetches: line.remoteRef) }
        }
        guard !followed.isEmpty else { return [] }

        // The tips that count: every ref but the tags, what FETCH_HEAD
        // holds but tags, and what the refspecs stored.
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
        // And the refs the refspecs stored, tags too (`main:refs/tags/x`).
        for line in lines where line.kind == .update && line.flag != "!"
            && !followed.contains(where: { $0.localRef.utf8.elementsEqual(line.localRef.utf8) }) {
            var oid = git_oid()
            if git_reference_name_to_id(&oid, repo, line.localRef) == 0 { tips.append(oid) }
        }

        // What each followed tag points at, peeled.
        var targets: [(tag: String, id: git_oid, isCommit: Bool)] = []
        for line in followed {
            var object: OpaquePointer?
            guard git_revparse_single(&object, repo, line.localRef + "^{}") == 0,
                  let id = git_object_id(object)?.pointee
            else { git_object_free(object); continue }
            targets.append((line.localRef, id, git_object_type(object) == GIT_OBJECT_COMMIT))
            git_object_free(object)
        }
        // A tip that is an annotated tag stands for what it points at.
        for var tip in tips {
            var object: OpaquePointer?
            guard git_object_lookup(&object, repo, &tip, GIT_OBJECT_TAG) == 0 else { continue }
            defer { git_object_free(object) }
            var peeled: OpaquePointer?
            if git_object_peel(&peeled, object, GIT_OBJECT_ANY) == 0, let id = git_object_id(peeled)?.pointee {
                tips.append(id)
            }
            git_object_free(peeled)
        }
        // The commit graph takes commits only; a tip can be a tree or blob.
        let commitTips = tips.filter { tip in
            var tip = tip
            var object: OpaquePointer?
            defer { git_object_free(object) }
            return git_object_lookup(&object, repo, &tip, GIT_OBJECT_COMMIT) == 0
        }
        let others = Set(targets.filter { !$0.isCommit }.map { Self.hex($0.id) })
        let held = others.isEmpty ? [] : historyHolds(others, from: tips)
        var dropped: [String] = []
        var before: ObjectsBefore?
        for target in targets {
            var id = target.id
            let reached = target.isCommit
                ? commitTips.contains { tip in var tip = tip; return git_oid_equal(&tip, &id) == 1 }
                    || git_graph_reachable_from_any(repo, &id, commitTips, commitTips.count) == 1
                : held.contains(Self.hex(id))
            guard !reached else { continue }
            // An object the repository had before, reachable or not, is
            // one git follows a tag of.
            if before == nil { before = ObjectsBefore(repository: repo, packs: packsBefore) }
            if before?.has(id) == true { continue }
            try check(git_reference_remove(repo, target.tag))
            dropped.append(target.tag)
        }
        lines.removeAll { line in dropped.contains { $0.utf8.elementsEqual(line.localRef.utf8) } }
        try removeFetchHeadTags(dropped)
        return dropped
    }

    /// Which of `targets` (trees and blobs, as hex IDs) the history of
    /// `tips` holds. git follows a tag of a tree or blob it has once the
    /// fetch is in; libgit2 fetched every tag's objects, so what the
    /// commits reachable from the tips hold stands in for what git would
    /// have. Each tree is walked once, and the walk stops once every
    /// target is found.
    private func historyHolds(_ targets: Set<String>, from tips: [git_oid]) -> Set<String> {
        final class Search {
            var wanted: Set<String>
            var found = Set<String>()
            var seenTrees = Set<String>()
            init(_ wanted: Set<String>) { self.wanted = wanted }
            /// Note `id`; whether it's a tree not walked before.
            func visit(_ id: String, isTree: Bool) -> Bool {
                if wanted.remove(id) != nil { found.insert(id) }
                return isTree ? seenTrees.insert(id).inserted : false
            }
        }
        let search = Search(targets)
        /// Walk `tree`'s entries, skipping subtrees walked before.
        func walkTree(_ tree: OpaquePointer?) {
            _ = git_tree_walk(tree, GIT_TREEWALK_PRE, { _, entry, payload in
                guard let entry, let payload, let id = git_tree_entry_id(entry)?.pointee else { return 0 }
                let search = Unmanaged<Search>.fromOpaque(payload).takeUnretainedValue()
                let isTree = git_tree_entry_type(entry) == GIT_OBJECT_TREE
                // A subtree walked before holds nothing new: skip it.
                return search.visit(Repository.hex(id), isTree: isTree) || !isTree ? 0 : 1
            }, Unmanaged.passUnretained(search).toOpaque())
        }
        // A tip can be a tree or blob itself (`refs/meta/blob`).
        for var tip in tips {
            var object: OpaquePointer?
            guard git_object_lookup(&object, repo, &tip, GIT_OBJECT_ANY) == 0 else { continue }
            defer { git_object_free(object) }
            switch git_object_type(object) {
            case GIT_OBJECT_TREE:
                if search.visit(Self.hex(tip), isTree: true) { walkTree(object) }
            case GIT_OBJECT_BLOB:
                _ = search.visit(Self.hex(tip), isTree: false)
            default:
                break
            }
        }
        var walk: OpaquePointer?
        guard git_revwalk_new(&walk, repo) == 0 else { return [] }
        defer { git_revwalk_free(walk) }
        // Only commits start a walk.
        for var tip in tips where git_revwalk_push(walk, &tip) != 0 { git_error_clear() }
        var oid = git_oid()
        while !search.wanted.isEmpty, git_revwalk_next(&oid, walk) == 0 {
            var commit: OpaquePointer?
            guard git_commit_lookup(&commit, repo, &oid) == 0 else { continue }
            defer { git_commit_free(commit) }
            var tree: OpaquePointer?
            guard git_commit_tree(&tree, commit) == 0 else { continue }
            defer { git_tree_free(tree) }
            guard let root = git_tree_id(tree)?.pointee,
                  search.visit(Self.hex(root), isTree: true)
            else { continue }
            walkTree(tree)
        }
        return search.found
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
        // Ref names as bytes, as git compares them.
        let excludedNames = Set(excluded.map { Array($0.utf8) })
        let tagLines = tags.filter { !excludedNames.contains(Array($0.utf8)) }
            .compactMap { tag in lines.first { isLine($0, of: tag) } }
        var output = Data()
        for line in others + tagLines {
            output.append(contentsOf: line)
            output.append(UInt8(ascii: "\n"))
        }
        try output.write(to: url)
    }
}

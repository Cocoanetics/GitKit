import Foundation
import CGitKit

/// The refs a remote advertised, looked up by name as git compares ref
/// names: byte for byte (Swift's `String` equality is canonical, so `é`
/// composed and decomposed would be one key).
struct RemoteRefs {
    /// The names, in advertised order.
    private(set) var names: [String] = []
    private var objects: [[UInt8]: git_oid] = [:]

    var isEmpty: Bool { names.isEmpty }

    mutating func add(_ name: String, _ oid: git_oid) {
        guard objects.updateValue(oid, forKey: Array(name.utf8)) == nil else { return }
        names.append(name)
    }

    /// The object remote ref `name` points at, if the remote has it.
    func object(of name: String) -> git_oid? {
        objects[Array(name.utf8)]
    }

    /// The remote refs `name` abbreviates, as git counts them
    /// (`count_refspec_match` over `ref_rev_parse_rules`): a match that is
    /// a branch or a tag, or spelled from `refs/` on, wins over the others.
    func abbreviated(_ name: String) -> [String] {
        let rules = [name, "refs/\(name)", "refs/tags/\(name)", "refs/heads/\(name)",
                     "refs/remotes/\(name)", "refs/remotes/\(name)/HEAD"]
        let found = rules.filter { object(of: $0) != nil }
        let strong = found.filter {
            $0 == name || $0 == "refs/\(name)" || $0.hasPrefix("refs/heads/") || $0.hasPrefix("refs/tags/")
        }
        return strong.isEmpty ? found : strong
    }
}

/// One push's refspecs, sorted the way git reads them: some name a ref,
/// patterns (`refs/heads/*:refs/heads/*`) and the matching refspec `:`
/// stand for many, and negative ones (`^refs/heads/wip`) drop updates.
struct PushPlan {
    /// A refspec with one `*` on each side, standing for every local ref
    /// its source matches.
    struct Pattern {
        let force: Bool
        let source: String
        let destination: String

        /// Where the pattern sends local ref `name`, or `nil` if its
        /// source doesn't match `name`.
        func destination(for name: String) -> String? {
            PushPlan.wildcard(source, matching: name).map {
                destination.replacingOccurrences(of: "*", with: $0)
            }
        }
    }

    /// The refspecs that name their refs, qualified for libgit2 (`main`
    /// becomes `refs/heads/main:refs/heads/main`); a short destination
    /// waits for the remote's refs to be spelled out.
    var explicit: [String] = []
    /// How each explicit refspec's source was typed, by position.
    var explicitTypedSources: [String?] = []
    /// git's refusals of sources that match nothing, for the push to
    /// report before it connects.
    var refusals: [PushRefusedError.Refusal] = []
    /// How each explicit refspec's source was typed (`HEAD`, `main`),
    /// keyed by its destination ref's UTF-8 bytes, for the summary of
    /// what the remote reports on (which goes to the first update of a ref).
    var typedSources: [[UInt8]: String] = [:]
    /// The same, keyed by the qualified refspec (without `+`), for the
    /// summary lines of updates the remote never got to judge.
    var typedSourcesByRefspec: [[UInt8]: String] = [:]
    var patterns: [Pattern] = []
    /// Whether the matching refspec was given: `nil` if not, `true` if
    /// forced (`+:`).
    var matching: Bool?
    /// The negative refspecs, without their `^`: a ref name or a pattern.
    var negatives: [String] = []

    /// Whether a negative refspec drops updates to remote ref `name`.
    func excludes(_ name: String) -> Bool {
        negatives.contains { PushPlan.wildcard($0, matching: name) != nil }
    }

    /// What `*` stands for where `pattern` matches `name`; a pattern
    /// without `*` matches only itself. Like git, this compares bytes:
    /// Swift's `String` equality would also match a canonically
    /// equivalent Unicode spelling (`é` composed or decomposed).
    static func wildcard(_ pattern: String, matching name: String) -> String? {
        let pattern = Array(pattern.utf8), name = Array(name.utf8)
        guard let star = pattern.firstIndex(of: UInt8(ascii: "*")) else {
            return pattern == name ? "" : nil
        }
        let prefix = pattern[..<star]
        let suffix = pattern[(star + 1)...]
        guard name.count >= prefix.count + suffix.count,
              name.starts(with: prefix), name.reversed().starts(with: suffix.reversed())
        else { return nil }
        return String(decoding: name[prefix.count..<(name.count - suffix.count)], as: UTF8.self)
    }
}

extension Repository {

    /// Sort `refspecs` into a ``PushPlan``, qualifying the ones that name
    /// a ref the way the CLI accepts them (`main`, `HEAD:review`).
    func pushPlan(for refspecs: [String]) throws -> PushPlan {
        var plan = PushPlan()
        for refspec in refspecs {
            if refspec.hasPrefix("^") {
                // As in git: a ref name or a pattern, without a
                // destination; an empty one or an object ID won't do.
                let name = String(refspec.dropFirst())
                guard !name.contains(":"), !Self.isObjectID(name), isValidRefspecName(name)
                else { throw invalidRefspec(refspec) }
                plan.negatives.append(name)
                continue
            }
            let force = refspec.hasPrefix("+")
            let body = force ? String(refspec.dropFirst()) : refspec
            if body == ":" {
                plan.matching = (plan.matching ?? false) || force
            } else if body.contains("*") {
                plan.patterns.append(try pushPattern(body, force: force))
            } else {
                // git reports every source that matches nothing (or more
                // than one ref) once all refspecs have parsed
                // (check_push_refs).
                let qualified: String
                do {
                    qualified = try qualifiedPushRefspec(refspec)
                } catch let error as Libgit2Error where error.message.hasPrefix("src refspec ") {
                    plan.refusals.append(.init(error.message))
                    continue
                }
                plan.explicit.append(qualified)
                plan.explicitTypedSources.append(typedPushSource(refspec))
            }
        }
        recordTypedSources(in: &plan)
        return plan
    }

    /// The refspecs to hand libgit2: the explicit ones, then each local
    /// ref a pattern matches, then the branches the matching refspec
    /// pairs up with `remoteRefs`. As in git, a pattern or the matching
    /// refspec leaves alone a destination something else is already
    /// being pushed to (two explicit refspecs to one ref never get here:
    /// ``matchedExplicitRefspecs(_:remoteRefs:)`` refuses them). A
    /// negative refspec drops every update to a ref it names.
    func expandedPushRefspecs(_ plan: PushPlan, remoteRefs: [String]?) throws -> [String] {
        var refspecs = plan.explicit
        // Ref names as bytes, as git compares them.
        var claimed = Set(plan.explicit.compactMap {
            destinationRefName(fromPushRefspec: $0).map { Array($0.utf8) }
        })
        func expand(_ force: Bool, _ source: String, _ destination: String) {
            guard claimed.insert(Array(destination.utf8)).inserted else { return }
            refspecs.append("\(force ? "+" : "")\(source):\(destination)")
        }
        let needsLocalRefs = !plan.patterns.isEmpty || plan.matching != nil
        let localRefs = needsLocalRefs ? try localReferenceNames() : []
        for pattern in plan.patterns {
            for name in localRefs {
                guard let destination = pattern.destination(for: name) else { continue }
                expand(pattern.force, name, destination)
            }
        }
        if let force = plan.matching, let remoteRefs {
            // Ref names as bytes, as git compares them.
            let advertised = Set(remoteRefs.map { Array($0.utf8) })
            for name in localRefs
            where name.hasPrefix("refs/heads/") && advertised.contains(Array(name.utf8)) {
                expand(force, name, name)
            }
        }
        guard !plan.negatives.isEmpty else { return refspecs }
        return refspecs.filter { refspec in
            destinationRefName(fromPushRefspec: refspec).map { !plan.excludes($0) } ?? true
        }
    }

    /// The refs a connected remote advertises (`refs/…` only, without
    /// the peeled `^{}` entries of annotated tags, as git lists them),
    /// with the object each points at.
    func advertisedRefs(_ remote: OpaquePointer?) throws -> RemoteRefs {
        var heads: UnsafeMutablePointer<UnsafePointer<git_remote_head>?>?
        var count = 0
        try check(git_remote_ls(&heads, &count, remote))
        var refs = RemoteRefs()
        for index in 0..<count {
            guard let head = heads?[index]?.pointee, let name = head.name else { continue }
            let refname = String(cString: name)
            if refname.hasPrefix("refs/"), !refname.hasSuffix("^{}") { refs.add(refname, head.oid) }
        }
        return refs
    }

    /// An explicit refspec's destination spelled out the way git finds
    /// it once it has the remote's refs (`match_explicit`): a short one
    /// names the remote ref it abbreviates (``RemoteRefs/abbreviated(_:)``),
    /// else, for anything but a deletion, the source's kind prefixes it
    /// (`refs/heads/` or `refs/tags/`, `guess_ref`). git's refusal when it
    /// can do neither, or when the name is ambiguous.
    func qualifiedDestination(
        _ refspec: String, remoteRefs: RemoteRefs
    ) -> (refspec: String?, refusal: PushRefusedError.Refusal?) {
        let force = refspec.hasPrefix("+")
        let body = Self.unforced(refspec)
        guard let colon = body.firstIndex(of: ":") else { return (refspec, nil) }
        let source = String(body[..<colon])
        let name = String(body[body.index(after: colon)...])
        guard !name.isEmpty, !name.hasPrefix("refs/") else { return (refspec, nil) }
        let full: String
        let matches = remoteRefs.abbreviated(name)
        if matches.count > 1 {
            return (nil, .init("dst refspec \(name) matches more than one"))
        } else if let match = matches.first {
            full = match
        } else if source.isEmpty {
            return (nil, .init("unable to delete '\(name)': remote ref does not exist"))
        } else if let guessed = guessedDestination(name, from: source) {
            full = guessed
        } else {
            return (nil, unqualifiedDestination(name, source: source))
        }
        return ((force ? "+" : "") + source + ":" + full, nil)
    }

    /// git's `guess_ref`: `name` under the kind of ref `source` is
    /// (following a symbolic ref such as `HEAD`), `nil` for anything that
    /// isn't a branch or a tag.
    func guessedDestination(_ name: String, from source: String) -> String? {
        var resolved = source
        var reference: OpaquePointer?
        if git_reference_lookup(&reference, repo, source) == 0 {
            defer { git_reference_free(reference) }
            var target: OpaquePointer?
            if git_reference_resolve(&target, reference) == 0, let targetName = git_reference_name(target) {
                resolved = String(cString: targetName)
            }
            git_reference_free(target)
        }
        return ["refs/heads/", "refs/tags/"].first { resolved.hasPrefix($0) }.map { $0 + name }
    }

    /// git's refusal of a short destination it can't complete, with the
    /// hint for what the source is (`show_push_unqualified_ref_name_error`).
    private func unqualifiedDestination(_ name: String, source: String) -> PushRefusedError.Refusal {
        let message = """
            The destination you provided is not a full refname (i.e.,
            starting with "refs/"). We tried to guess what you meant by:

            - Looking for a ref that matches '\(name)' on the remote side.
            - Checking if the <src> being pushed ('\(source)')
              is a ref in "refs/{heads,tags}/". If so we add a corresponding
              refs/{heads,tags}/ prefix on the remote side.

            Neither worked, so we gave up. You must fully qualify the ref.
            """
        var object: OpaquePointer?
        defer { git_object_free(object) }
        guard git_revparse_single(&object, repo, source) == 0 else { return .init(message) }
        let (kind, verb, namespace) = switch git_object_type(object) {
        case GIT_OBJECT_COMMIT: ("commit", "create a new branch", "refs/heads/")
        case GIT_OBJECT_TAG: ("tag", "create a new tag", "refs/tags/")
        case GIT_OBJECT_TREE: ("tree", "tag a new tree", "refs/tags/")
        default: ("blob", "tag a new blob", "refs/tags/")
        }
        return .init(message, hint: [
            "The <src> part of the refspec is a \(kind) object.",
            "Did you mean to \(verb) by pushing to",
            "'\(source):\(namespace)\(name)'?"
        ], adviceKey: "pushUnqualifiedRefName")
    }

    /// `refspec` without its `+`.
    static func unforced(_ refspec: String) -> String {
        refspec.hasPrefix("+") ? String(refspec.dropFirst()) : refspec
    }

    /// The explicit refspecs as the remote's refs settle them, the way
    /// git matches them before sending anything (`match_explicit_refs`):
    /// destinations spelled out (``qualifiedDestination(_:remoteRefs:)``),
    /// and every refusal in refspec order — a destination git can't
    /// complete or finds ambiguous, a deletion of nothing, and a second
    /// refspec to a destination one already takes, new or not, whatever
    /// its source and whatever a negative refspec makes of it.
    func matchedExplicitRefspecs(
        _ explicit: [String], remoteRefs: RemoteRefs
    ) -> (refspecs: [String], refusals: [PushRefusedError.Refusal]) {
        var refspecs: [String] = []
        var refusals: [PushRefusedError.Refusal] = []
        var taken = Set<[UInt8]>()  // ref names as bytes, as git compares them
        for refspec in explicit {
            let (qualified, refusal) = qualifiedDestination(refspec, remoteRefs: remoteRefs)
            guard let qualified else {
                refusal.map { refusals.append($0) }
                continue
            }
            if let destination = destinationRefName(fromPushRefspec: qualified),
               !taken.insert(Array(destination.utf8)).inserted {
                refusals.append(.init("dst ref \(destination) receives from more than one src"))
            }
            refspecs.append(qualified)
        }
        return (refspecs, refusals)
    }

    /// The typed source of each explicit refspec, by its destination (the
    /// remote reports on a ref's first update) and by the refspec itself,
    /// for the summary lines.
    func recordTypedSources(in plan: inout PushPlan) {
        plan.typedSources = [:]
        plan.typedSourcesByRefspec = [:]
        for (refspec, typed) in zip(plan.explicit, plan.explicitTypedSources) {
            guard let typed else { continue }
            plan.typedSourcesByRefspec[Array(Self.unforced(refspec).utf8)] = typed
            if let destination = destinationRefName(fromPushRefspec: refspec),
               plan.typedSources[Array(destination.utf8)] == nil {
                plan.typedSources[Array(destination.utf8)] = typed
            }
        }
    }

    /// How git names `remote` in a push's output: a configured remote's
    /// push URL (else its URL), or the URL or path as given, without the
    /// credentials it may carry (`https://user:token@host/r` reads
    /// `https://host/r`, `git@host:r` reads `host:r`).
    public func displayName(ofRemote remote: String) -> String {
        var url = remote
        if let (handle, _) = try? lookupRemote(remote) {
            url = (git_remote_pushurl(handle) ?? git_remote_url(handle)).map { String(cString: $0) } ?? remote
            git_remote_free(handle)
        }
        return ProgressReporter.anonymizedURL(url)
    }

    /// Whether pushing `refspec` leaves the remote as it is: the remote
    /// ref already points at the source, or a deletion finds no ref.
    func isUpToDate(_ refspec: String, remoteRefs: RemoteRefs) -> Bool {
        guard let destination = destinationRefName(fromPushRefspec: refspec) else { return false }
        let body = refspec.hasPrefix("+") ? refspec.dropFirst() : Substring(refspec)
        let source = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard var remote = remoteRefs.object(of: destination) else { return source.isEmpty }
        var object: OpaquePointer?
        guard !source.isEmpty, git_revparse_single(&object, repo, String(source)) == 0 else {
            return false
        }
        defer { git_object_free(object) }
        guard var local = git_object_id(object)?.pointee else { return false }
        return git_oid_equal(&local, &remote) == 1
    }

    /// `refspecs` split by git's rules for an update without force: the
    /// ones to push, and the ones it refuses, with why.
    func partitionedPushRefspecs(
        _ refspecs: [String], remoteRefs: RemoteRefs
    ) throws -> (accepted: [String], rejected: [(refspec: String, reason: PushRejectedError.Reason)]) {
        var accepted: [String] = []
        var rejected: [(refspec: String, reason: PushRejectedError.Reason)] = []
        for refspec in refspecs {
            if let reason = try pushRejection(for: refspec, remoteRefs: remoteRefs) {
                rejected.append((refspec, reason))
            } else {
                accepted.append(refspec)
            }
        }
        return (accepted, rejected)
    }

    /// Why git would refuse `refspec` without force, given the remote's
    /// refs, or `nil` to push it. A new ref, a deletion, a forced update
    /// and a ref already up to date always go; otherwise a tag can't
    /// move, the remote's tip has to be here, both sides have to be
    /// commits, and the new commit has to descend from the old one.
    func pushRejection(
        for refspec: String, remoteRefs: RemoteRefs
    ) throws -> PushRejectedError.Reason? {
        guard !refspec.hasPrefix("+"),
              let destination = destinationRefName(fromPushRefspec: refspec),
              var old = remoteRefs.object(of: destination)
        else { return nil }
        let source = refspec.split(separator: ":", maxSplits: 1,
                                   omittingEmptySubsequences: false)[0]
        guard !source.isEmpty else { return nil }
        var object: OpaquePointer?
        try check(git_revparse_single(&object, repo, String(source)))
        defer { git_object_free(object) }
        guard var new = git_object_id(object)?.pointee else { return nil }
        if git_oid_equal(&old, &new) == 1 { return nil }
        if destination.hasPrefix("refs/tags/") { return .alreadyExists }

        var odb: OpaquePointer?
        try check(git_repository_odb(&odb, repo))
        defer { git_odb_free(odb) }
        guard git_odb_exists(odb, &old) == 1 else { return .fetchFirst }

        guard var oldCommit = peeledCommit(old), var newCommit = peeledCommit(new) else {
            return .needsForce
        }
        if git_oid_equal(&oldCommit, &newCommit) == 1 { return nil }
        return git_graph_descendant_of(repo, &newCommit, &oldCommit) == 1 ? nil : .nonFastForward
    }

    /// The commit `oid` is or, as a tag, points at; `nil` for anything else.
    private func peeledCommit(_ oid: git_oid) -> git_oid? {
        var oid = oid
        var object: OpaquePointer?
        guard git_object_lookup(&object, repo, &oid, GIT_OBJECT_ANY) == 0 else { return nil }
        defer { git_object_free(object) }
        var commit: OpaquePointer?
        guard git_object_peel(&commit, object, GIT_OBJECT_COMMIT) == 0 else { return nil }
        defer { git_object_free(commit) }
        return git_object_id(commit)?.pointee
    }

    /// `<src>:<dst>`, or `<src>` for both, each side a ref name with
    /// exactly one `*`, as git requires of a pattern.
    private func pushPattern(_ body: String, force: Bool) throws -> PushPlan.Pattern {
        let sides = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let source = String(sides[0])
        let destination = sides.count > 1 ? String(sides[1]) : source
        guard [source, destination].allSatisfy({ side in
            side.contains("*") && isValidRefspecName(side)
        }) else { throw invalidRefspec(body) }
        return PushPlan.Pattern(force: force, source: source, destination: destination)
    }

    /// Whether `name` is a ref name as git takes one in a refspec: a
    /// single level is fine, and so is one `*`, anywhere (`release-*`).
    /// libgit2's pattern flag wants the `*` to be a whole component, so
    /// the name is checked with a plain character in its place. libgit2
    /// also accepts a name it can tidy up (`refs/heads//x`), which git
    /// doesn't: the name has to come back from normalizing unchanged.
    private func isValidRefspecName(_ name: String) -> Bool {
        guard name.filter({ $0 == "*" }).count <= 1 else { return false }
        let plain = name.replacingOccurrences(of: "*", with: "x")
        // C enums import as Int32 on Windows, UInt32 elsewhere.
        let flags = UInt32(GIT_REFERENCE_FORMAT_ALLOW_ONELEVEL.rawValue)
        // Normalizing only ever shortens the name.
        var buffer = [CChar](repeating: 0, count: plain.utf8.count + 1)
        guard git_reference_normalize_name(&buffer, buffer.count, plain, flags) == 0 else {
            return false
        }
        return String(cString: buffer) == plain
    }

    /// A full object ID in hex, SHA-1 or SHA-256.
    private static func isObjectID(_ name: String) -> Bool {
        [40, 64].contains(name.count) && name.allSatisfy(\.isHexDigit)
    }

    private func invalidRefspec(_ refspec: String) -> Libgit2Error {
        Libgit2Error(
            code: GIT_EINVALIDSPEC.rawValue,
            klass: Int32(GIT_ERROR_INVALID.rawValue),
            message: "invalid refspec '\(refspec)'")
    }

    /// Every local ref's full name, sorted.
    private func localReferenceNames() throws -> [String] {
        var iterator: UnsafeMutablePointer<git_reference_iterator>?
        try check(git_reference_iterator_new(&iterator, repo))
        defer { git_reference_iterator_free(iterator) }
        var names: [String] = []
        var name: UnsafePointer<CChar>?
        while true {
            let rc = git_reference_next_name(&name, iterator)
            if rc == GIT_ITEROVER.rawValue { break }
            try check(rc)
            if let name { names.append(String(cString: name)) }
        }
        return names.sorted()
    }
}

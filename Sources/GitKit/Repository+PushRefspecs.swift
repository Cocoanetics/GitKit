import Foundation
import CGitKit

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
    /// becomes `refs/heads/main:refs/heads/main`).
    var explicit: [String] = []
    /// How each explicit refspec's source was typed (`HEAD`, `main`),
    /// keyed by its destination ref, for the summary.
    var typedSources: [String: String] = [:]
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
                let qualified = try qualifiedPushRefspec(refspec)
                plan.explicit.append(qualified)
                // The remote reports on the first update to a ref.
                if let destination = destinationRefName(fromPushRefspec: qualified),
                   plan.typedSources[destination] == nil,
                   let typed = typedPushSource(refspec) {
                    plan.typedSources[destination] = typed
                }
            }
        }
        return plan
    }

    /// The refspecs to hand libgit2: the explicit ones, then each local
    /// ref a pattern matches, then the branches the matching refspec
    /// pairs up with `remoteRefs`. As in git, a pattern
    /// or the matching refspec leaves alone a destination something else
    /// is already being pushed to, while explicit refspecs all go out
    /// (two to one ref, and the remote refuses both). A negative refspec
    /// drops every update to a ref it names.
    func expandedPushRefspecs(_ plan: PushPlan, remoteRefs: Set<String>) throws -> [String] {
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
        if let force = plan.matching {
            for name in localRefs where name.hasPrefix("refs/heads/") && remoteRefs.contains(name) {
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
    func advertisedRefs(_ remote: OpaquePointer?) throws -> [String: git_oid] {
        var heads: UnsafeMutablePointer<UnsafePointer<git_remote_head>?>?
        var count = 0
        try check(git_remote_ls(&heads, &count, remote))
        var refs: [String: git_oid] = [:]
        for index in 0..<count {
            guard let head = heads?[index]?.pointee, let name = head.name else { continue }
            let refname = String(cString: name)
            if refname.hasPrefix("refs/"), !refname.hasSuffix("^{}") { refs[refname] = head.oid }
        }
        return refs
    }

    /// A destination two of `refspecs` push to that the remote already
    /// has, which git refuses outright.
    func duplicatedDestination(in refspecs: [String], remoteRefs: [String: git_oid]) -> String? {
        var seen = Set<[UInt8]>()  // ref names as bytes, as git compares them
        for refspec in refspecs {
            guard let destination = destinationRefName(fromPushRefspec: refspec) else { continue }
            if !seen.insert(Array(destination.utf8)).inserted, remoteRefs[destination] != nil {
                return destination
            }
        }
        return nil
    }

    /// How git names `remote` in its output: a configured remote's URL,
    /// or the URL or path as given, without the credentials it may carry
    /// (`https://user:token@host/r` reads `https://host/r`, `git@host:r`
    /// reads `host:r`).
    public func displayName(ofRemote remote: String) -> String {
        var url = remote
        if let (handle, _) = try? lookupRemote(remote) {
            url = git_remote_url(handle).map { String(cString: $0) } ?? remote
            git_remote_free(handle)
        }
        return ProgressReporter.anonymizedURL(url)
    }

    /// Whether pushing `refspec` leaves the remote as it is: the remote
    /// ref already points at the source, or a deletion finds no ref.
    func isUpToDate(_ refspec: String, remoteRefs: [String: git_oid]) -> Bool {
        guard let destination = destinationRefName(fromPushRefspec: refspec) else { return false }
        let body = refspec.hasPrefix("+") ? refspec.dropFirst() : Substring(refspec)
        let source = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard var remote = remoteRefs[destination] else { return source.isEmpty }
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
        _ refspecs: [String], remoteRefs: [String: git_oid]
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
        for refspec: String, remoteRefs: [String: git_oid]
    ) throws -> PushRejectedError.Reason? {
        guard !refspec.hasPrefix("+"),
              let destination = destinationRefName(fromPushRefspec: refspec),
              var old = remoteRefs[destination]
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

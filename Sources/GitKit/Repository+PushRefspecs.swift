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

    /// What `*` stands for where `pattern` matches `name`; a pattern
    /// without `*` matches only itself.
    static func wildcard(_ pattern: String, matching name: String) -> String? {
        guard let star = pattern.firstIndex(of: "*") else {
            return pattern == name ? "" : nil
        }
        let prefix = pattern[..<star]
        let suffix = pattern[pattern.index(after: star)...]
        guard name.count >= prefix.count + suffix.count,
              name.hasPrefix(prefix), name.hasSuffix(suffix)
        else { return nil }
        return String(name.dropFirst(prefix.count).dropLast(suffix.count))
    }
}

extension Repository {

    /// Sort `refspecs` into a ``PushPlan``, qualifying the ones that name
    /// a ref the way the CLI accepts them (`main`, `HEAD:review`).
    func pushPlan(for refspecs: [String]) throws -> PushPlan {
        var plan = PushPlan()
        for refspec in refspecs {
            if refspec.hasPrefix("^") {
                plan.negatives.append(String(refspec.dropFirst()))
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
                if let destination = destinationRefName(fromPushRefspec: qualified),
                   let typed = typedPushSource(refspec) {
                    plan.typedSources[destination] = typed
                }
            }
        }
        return plan
    }

    /// The refspecs to hand libgit2: the explicit ones, then each local
    /// ref a pattern matches, then, once the remote's refs are known,
    /// the branches the matching refspec pairs up. As in git, a pattern
    /// or the matching refspec leaves alone a destination something else
    /// is already being pushed to, while explicit refspecs all go out
    /// (two to one ref, and the remote refuses both). A negative refspec
    /// drops every update to a ref it names.
    func expandedPushRefspecs(_ plan: PushPlan, remoteRefs: Set<String>?) throws -> [String] {
        var refspecs = plan.explicit
        var claimed = Set(plan.explicit.compactMap { destinationRefName(fromPushRefspec: $0) })
        func expand(_ force: Bool, _ source: String, _ destination: String) {
            guard claimed.insert(destination).inserted else { return }
            refspecs.append("\(force ? "+" : "")\(source):\(destination)")
        }
        let needsLocalRefs = !plan.patterns.isEmpty || (plan.matching != nil && remoteRefs != nil)
        let localRefs = needsLocalRefs ? try localReferenceNames() : []
        for pattern in plan.patterns {
            for name in localRefs {
                guard let destination = pattern.destination(for: name) else { continue }
                expand(pattern.force, name, destination)
            }
        }
        if let force = plan.matching, let remoteRefs {
            for name in localRefs where name.hasPrefix("refs/heads/") && remoteRefs.contains(name) {
                expand(force, name, name)
            }
        }
        guard !plan.negatives.isEmpty else { return refspecs }
        return refspecs.filter { refspec in
            guard let destination = destinationRefName(fromPushRefspec: refspec) else { return true }
            return !plan.negatives.contains { PushPlan.wildcard($0, matching: destination) != nil }
        }
    }

    /// The refs a connected remote advertises (`refs/…` only).
    func advertisedRefs(_ remote: OpaquePointer?) throws -> Set<String> {
        var heads: UnsafeMutablePointer<UnsafePointer<git_remote_head>?>?
        var count = 0
        try check(git_remote_ls(&heads, &count, remote))
        var names = Set<String>()
        for index in 0..<count {
            guard let name = heads?[index]?.pointee.name else { continue }
            let refname = String(cString: name)
            if refname.hasPrefix("refs/") { names.insert(refname) }
        }
        return names
    }

    /// `<src>:<dst>`, or `<src>` for both, with exactly one `*` on each
    /// side, as git requires of a pattern.
    private func pushPattern(_ body: String, force: Bool) throws -> PushPlan.Pattern {
        let sides = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let source = String(sides[0])
        let destination = sides.count > 1 ? String(sides[1]) : source
        guard source.filter({ $0 == "*" }).count == 1,
              destination.filter({ $0 == "*" }).count == 1
        else {
            throw Libgit2Error(
                code: GIT_EINVALIDSPEC.rawValue,
                klass: Int32(GIT_ERROR_INVALID.rawValue),
                message: "invalid refspec '\(body)'")
        }
        return PushPlan.Pattern(force: force, source: source, destination: destination)
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

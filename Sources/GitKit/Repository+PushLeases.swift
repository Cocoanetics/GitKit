import Foundation
import CGitKit

/// What `git push --force-with-lease` asks of the refs a push updates:
/// each ref a lease covers must still be where the lease expects it on
/// the remote, and is then forced; one that isn't is refused as
/// `stale info`, and the rest of the push goes ahead.
public struct PushLeases: Sendable, Equatable {
    /// Where a leased ref has to be on the remote.
    public enum Expectation: Sendable, Equatable {
        /// Where this repository's remote-tracking ref for it says, as
        /// the remote's fetch refspecs map it; with no such ref (or for a
        /// URL or path), absent.
        case tracking
        /// At this object ID, in full.
        case object(String)
        /// Not there at all.
        case absent
    }

    /// One `--force-with-lease=<ref>[:<expect>]`.
    public struct Lease: Sendable, Equatable {
        /// The remote ref, spelled as git takes it: `main` covers
        /// `refs/heads/main` (and `refs/tags/main`, as git matches
        /// abbreviations).
        public var ref: String
        public var expectation: Expectation

        public init(ref: String, expectation: Expectation) {
            self.ref = ref
            self.expectation = expectation
        }
    }

    /// The leases named, the first one that covers a ref applying to it.
    public var leases: [Lease]
    /// Whether every other ref pushed is leased on its remote-tracking
    /// ref: a bare `--force-with-lease`.
    public var trackingForRest: Bool

    public init(_ leases: [Lease] = [], trackingForRest: Bool = false) {
        self.leases = leases
        self.trackingForRest = trackingForRest
    }

    /// What remote ref `name` is expected to be, or `nil` if no lease
    /// covers it (git's `apply_cas`).
    func expectation(for name: String) -> Expectation? {
        if let lease = leases.first(where: { Self.abbreviation($0.ref, matches: name) }) {
            return lease.expectation
        }
        return trackingForRest ? .tracking : nil
    }

    /// Whether `abbreviation` names full ref `name` by one of git's
    /// rules for spelling a ref (`refname_match`), comparing bytes.
    static func abbreviation(_ abbreviation: String, matches name: String) -> Bool {
        let rules = [abbreviation, "refs/\(abbreviation)", "refs/tags/\(abbreviation)",
                     "refs/heads/\(abbreviation)", "refs/remotes/\(abbreviation)",
                     "refs/remotes/\(abbreviation)/HEAD"]
        return rules.contains { Array($0.utf8) == Array(name.utf8) }
    }
}

extension Repository {

    /// Push `refspecs` to `remote` in one operation, as
    /// ``push(remote:refspecs:setUpstream:connectingTo:credentials:progress:)`` does,
    /// with `git push --force-with-lease` semantics for the refs
    /// `leases` covers.
    ///
    /// As in git, each covered ref that is to change has to be on the
    /// remote where its lease expects it. If it is, the update is forced;
    /// if not, it is refused as `stale info` and the rest of the push
    /// goes ahead, the refusal reported in the ``PushRejectedError``
    /// thrown at the end. A refspec forced with `+` is forced all the
    /// same, as `git push --force` overrides a lease. The remote checks
    /// each update against the value the lease was checked against, so a
    /// ref that moves meanwhile is refused, not overwritten.
    ///
    /// - Parameters:
    ///   - remote: The remote to push to: a configured remote's name
    ///     (e.g. `"origin"`), or, as in git, a URL or path.
    ///   - refspecs: The refspecs to push, or none for the remote's own.
    ///   - setUpstream: When `true`, configure each pushed branch's
    ///     upstream afterwards, as `git push -u` does.
    ///   - leases: The `--force-with-lease` options given.
    ///   - location: Where to connect instead, as for
    ///     ``push(remote:refspecs:setUpstream:connectingTo:credentials:progress:)``.
    ///   - credentials: Invoked by the transport on auth challenges.
    ///   - progress: Sink for real-git-style progress lines (defaults to
    ///     the process's stderr).
    /// - Returns: The refspecs pushed, one per ref and fully qualified.
    @discardableResult
    public func push(
        remote: String,
        refspecs: [String],
        setUpstream: Bool,
        leases: PushLeases,
        connectingTo location: String? = nil,
        credentials: CredentialProvider? = nil,
        progress: @escaping @Sendable (String) -> Void = GitProgress.standardError
    ) throws -> [String] {
        try pushImpl(
            remote: remote, refspecs: refspecs, setUpstream: setUpstream,
            location: location, forceWithLease: nil, leases: leases,
            credentials: credentials, progress: progress)
    }

    /// `refspecs` as git settles them before a push: the leases force
    /// the updates they cover or refuse them as stale, git's rules refuse
    /// the other updates they would, and what's left goes in the order
    /// the remote reports on it, and git lists it (`match_push_refs`):
    /// the refs the remote has as it advertised them, then the new ones
    /// as the refspecs named them.
    func settledPushRefspecs(
        _ refspecs: [String], leases: PushLeases?, remoteRefs: RemoteRefs, remote: OpaquePointer?
    ) throws -> (accepted: [String], rejected: [(refspec: String, reason: PushRejectedError.Reason)]) {
        var leased = refspecs
        var stale: [(refspec: String, reason: PushRejectedError.Reason)] = []
        if let leases {
            (leased, stale) = try leasedPushRefspecs(
                refspecs, leases: leases, remoteRefs: remoteRefs, remote: remote)
        }
        let (accepted, rejected) = try partitionedPushRefspecs(leased, remoteRefs: remoteRefs)
        return (advertisedOrder(accepted, remoteRefs: remoteRefs), rejected + stale)
    }

    /// `refspecs` in git's order for a push's ref list: those updating a
    /// ref the remote has, by where it advertised the ref, then those
    /// creating one, as given.
    func advertisedOrder(_ refspecs: [String], remoteRefs: RemoteRefs) -> [String] {
        // Ref names as bytes, as git compares them.
        let positions = Dictionary(
            remoteRefs.names.enumerated().map { (Array($0.element.utf8), $0.offset) },
            uniquingKeysWith: { first, _ in first })
        return refspecs.enumerated()
            .map { entry -> (position: Int, offset: Int, refspec: String) in
                let destination = destinationRefName(fromPushRefspec: entry.element)
                let position = destination.flatMap { positions[Array($0.utf8)] } ?? Int.max
                return (position, entry.offset, entry.element)
            }
            .sorted { ($0.position, $0.offset) < ($1.position, $1.offset) }
            .map(\.refspec)
    }

    /// `refspecs` as `leases` settles them (git's `apply_cas` and
    /// `set_ref_status_for_push`): an update a lease covers is forced if
    /// the remote ref is where the lease expects it, and refused as
    /// stale if not; an update already forced, one that leaves the
    /// remote ref as it is, and one no lease covers stay as they are.
    func leasedPushRefspecs(
        _ refspecs: [String], leases: PushLeases, remoteRefs: RemoteRefs, remote: OpaquePointer?
    ) throws -> (refspecs: [String], stale: [(refspec: String, reason: PushRejectedError.Reason)]) {
        var settled: [String] = []
        var stale: [(refspec: String, reason: PushRejectedError.Reason)] = []
        for refspec in refspecs {
            guard !refspec.hasPrefix("+"),
                  let destination = destinationRefName(fromPushRefspec: refspec),
                  let expectation = leases.expectation(for: destination)
            else {
                settled.append(refspec)
                continue
            }
            let isDeletion = refspec.hasPrefix(":")
            if !isDeletion, isUpToDate(refspec, remoteRefs: remoteRefs) {
                settled.append(refspec)
                continue
            }
            let expected: git_oid?
            switch expectation {
            case .tracking:
                expected = try trackingRef(of: destination, remote: remote).flatMap(oidOfReference)
            case .object(let sha):
                var oid = git_oid()
                guard sha.withCString({ git_oid_fromstrp(&oid, $0) }) == 0 else {
                    throw Libgit2Error(
                        code: GIT_EINVALID.rawValue, klass: Int32(GIT_ERROR_INVALID.rawValue),
                        message: "cannot parse expected object name '\(sha)'")
                }
                expected = oid
            case .absent:
                expected = nil
            }
            let actual = remoteRefs.object(of: destination)
            let matches: Bool
            if var actual, var expected {
                matches = git_oid_equal(&actual, &expected) == 1
            } else {
                matches = actual == nil && expected == nil
            }
            if matches {
                settled.append("+\(refspec)")
            } else {
                stale.append((refspec, .stale))
            }
        }
        return (settled, stale)
    }

    /// The remote-tracking ref `remote`'s fetch refspecs map remote ref
    /// `name` to (git's `remote_tracking`), or `nil` when none does, as
    /// for a URL or path, which has no fetch refspecs.
    private func trackingRef(of name: String, remote: OpaquePointer?) throws -> String? {
        let specs = (0..<git_remote_refspec_count(remote)).compactMap { git_remote_get_refspec(remote, $0) }
            .filter { git_refspec_direction($0) == GIT_DIRECTION_FETCH }
        // A negative refspec keeps a ref from being tracked at all.
        if specs.contains(where: { spec in
            git_refspec_string(spec).map { String(cString: $0).hasPrefix("^") } == true
                && git_refspec_src_matches_negative(spec, name) == 1
        }) {
            return nil
        }
        for spec in specs {
            guard git_refspec_string(spec).map({ !String(cString: $0).hasPrefix("^") }) == true,
                  let dst = git_refspec_dst(spec), dst.pointee != 0,
                  git_refspec_src_matches(spec, name) == 1
            else { continue }
            var buffer = git_buf()
            defer { git_buf_dispose(&buffer) }
            try check(git_refspec_transform(&buffer, spec, name))
            return buffer.ptr.map { String(cString: $0) }
        }
        return nil
    }

    /// The object `name` points at, peeled through symbolic refs, or
    /// `nil` if there's no such ref.
    private func oidOfReference(_ name: String) throws -> git_oid? {
        var oid = git_oid()
        let rc = git_reference_name_to_id(&oid, repo, name)
        if rc == GIT_ENOTFOUND.rawValue { return nil }
        try check(rc)
        return oid
    }

}

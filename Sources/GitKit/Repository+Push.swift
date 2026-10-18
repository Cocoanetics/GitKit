import Foundation
import CGitKit

/// The lease expectation used by force-with-lease pushes.
public enum PushLease: Sendable, Equatable {
    /// Mirror `git push --force-with-lease`: expect the destination branch
    /// to match `refs/remotes/<remote>/<branch>`. If that tracking ref is
    /// absent, the remote branch must also be absent.
    case tracking
    /// Expect the destination ref to still point at this full 40-character
    /// object ID.
    case expecting(String)
}

extension Repository {

    /// Push `refspec` to `remote`. Mirrors `git push <remote> <refspec>`
    /// including its progress output and per-ref summary lines.
    ///
    /// - Parameters:
    ///   - remote: The remote to push to: a configured remote's name
    ///     (e.g. `"origin"`), or, as in git, a URL or path.
    ///   - refspec: The refspec to push (e.g. `"main"` or
    ///     `"refs/heads/main:refs/heads/main"`).
    ///   - setUpstream: When `true`, configure the pushed branch's upstream
    ///     afterwards — the `git push -u` semantics libgit2 doesn't bundle.
    ///   - credentials: Invoked by the transport on auth challenges.
    ///   - progress: Sink for real-git-style progress lines (defaults to
    ///     the process's stderr).
    public func push(
        remote: String,
        refspec: String,
        setUpstream: Bool,
        credentials: CredentialProvider? = nil,
        progress: @escaping @Sendable (String) -> Void = GitProgress.standardError
    ) throws {
        try pushImpl(
            remote: remote, refspecs: [refspec], setUpstream: setUpstream,
            forceWithLease: nil, credentials: credentials, progress: progress)
    }

    /// Push `refspecs` to `remote` in one operation — one connection, one
    /// pack, one summary — as `git push <remote> <refspec>…` does.
    ///
    /// Besides refspecs that name a ref, it takes the other kinds git
    /// takes:
    /// - a pattern, `refs/heads/*:refs/heads/*` (`+` to force), pushes
    ///   each local ref it matches;
    /// - the matching refspec `:` (`+:` to force) pushes every local
    ///   branch the remote also has, under the same name, which is what
    ///   `push.default=matching` pushes;
    /// - a negative refspec, `^refs/heads/wip` or `^refs/heads/wip/*`,
    ///   drops any update to a remote ref it matches.
    ///
    /// Empty `refspecs` pushes what the remote is configured to push
    /// (`remote.<name>.push`); without that there is nothing to push.
    ///
    /// - Parameters:
    ///   - remote: The remote to push to: a configured remote's name
    ///     (e.g. `"origin"`), or, as in git, a URL or path.
    ///   - refspecs: The refspecs to push, or none for the remote's own.
    ///   - setUpstream: When `true`, configure each pushed branch's
    ///     upstream afterwards, as `git push -u` does.
    ///   - credentials: Invoked by the transport on auth challenges.
    ///   - progress: Sink for real-git-style progress lines (defaults to
    ///     the process's stderr).
    /// - Returns: The refspecs pushed, one per ref and fully qualified
    ///   (`+refs/heads/main:refs/heads/main`), including refs that were
    ///   already up to date; empty when there was nothing to send.
    @discardableResult
    public func push(
        remote: String,
        refspecs: [String],
        setUpstream: Bool,
        credentials: CredentialProvider? = nil,
        progress: @escaping @Sendable (String) -> Void = GitProgress.standardError
    ) throws -> [String] {
        try pushImpl(
            remote: remote, refspecs: refspecs, setUpstream: setUpstream,
            forceWithLease: nil, credentials: credentials, progress: progress)
    }

    /// Push `refspec` to `remote` with `--force-with-lease` semantics.
    ///
    /// The refspec is force-pushed, but only after the remote advertises
    /// the expected destination ref value on the same push connection.
    /// This preserves the race protection of `git push --force-with-lease`.
    ///
    /// - Parameters:
    ///   - remote: The remote name to push to (e.g. `"origin"`).
    ///   - refspec: The refspec to push (e.g. `"main"` or
    ///     `"refs/heads/main:refs/heads/main"`).
    ///   - setUpstream: When `true`, configure the pushed branch's upstream
    ///     after a successful push.
    ///   - forceWithLease: The lease expectation to verify before sending
    ///     the forced update.
    ///   - credentials: Invoked by the transport on auth challenges.
    ///   - progress: Sink for real-git-style progress lines (defaults to
    ///     the process's stderr).
    public func push(
        remote: String,
        refspec: String,
        setUpstream: Bool,
        forceWithLease lease: PushLease,
        credentials: CredentialProvider? = nil,
        progress: @escaping @Sendable (String) -> Void = GitProgress.standardError
    ) throws {
        try pushImpl(
            remote: remote, refspecs: [refspec], setUpstream: setUpstream,
            forceWithLease: lease, credentials: credentials, progress: progress)
    }

    /// What a push came to: refs sent, or nothing to send.
    private enum PushOutcome {
        /// Pushed `accepted` (some may have been up to date already) and
        /// left alone the `rejected` ones git's rules refuse.
        case pushed(accepted: [String], rejected: [(refspec: String, reason: PushRejectedError.Reason)])
        /// Nothing to send to a remote that has refs.
        case nothingToSend
        /// Nothing to send to a remote without any refs, which git refuses.
        case noRefsInCommon
    }

    @discardableResult
    private func pushImpl(
        remote: String,
        refspecs requested: [String],
        setUpstream: Bool,
        forceWithLease lease: PushLease?,
        credentials: CredentialProvider?,
        progress: @escaping @Sendable (String) -> Void
    ) throws -> [String] {
        let (remoteHandle, isConfigured) = try lookupRemote(remote)
        defer { git_remote_free(remoteHandle) }

        let remoteURL = git_remote_url(remoteHandle).map { String(cString: $0) }
        var reporter = ProgressReporter(
            headerURL: remoteURL, direction: .push, output: progress)
        reporter.suppressTransferProgress =
            ProgressReporter.isLocalURL(remoteURL)

        let refspecs = requested.isEmpty
            ? try configuredPushRefspecs(remoteHandle)
            : requested
        var plan = try pushPlan(for: refspecs)
        let pushLease = try lease.map { lease -> PushLeaseCheck in
            guard plan.patterns.isEmpty, plan.matching == nil,
                  plan.explicit.count == 1
            else {
                throw Libgit2Error(
                    code: GIT_EINVALIDSPEC.rawValue,
                    klass: Int32(GIT_ERROR_INVALID.rawValue),
                    message: "force-with-lease requires a destination ref")
            }
            plan.explicit = plan.explicit.map(forcePushRefspec)
            return try pushLeaseCheck(
                lease, remote: remote, refspec: plan.explicit[0], isConfigured: isConfigured)
        }
        reporter.repository = repo
        reporter.abbreviation = summaryAbbreviation()
        reporter.typedSources = plan.typedSources

        var opts = git_push_options()
        try check(git_push_options_init(&opts, UInt32(GIT_PUSH_OPTIONS_VERSION)))
        let outcome = try withCallbacksPayload(
            credentials: credentials, reporter: reporter,
            pushLease: pushLease,
            {
                credCB, sidebandCB, _, _, pushRefCB, packCB,
                pushTransferCB, pushNegotiationCB, payload -> PushOutcome in
                opts.callbacks.credentials = credCB
                opts.callbacks.sideband_progress = sidebandCB
                opts.callbacks.push_update_reference = pushRefCB
                opts.callbacks.pack_progress = packCB
                opts.callbacks.push_transfer_progress = pushTransferCB
                opts.callbacks.push_negotiation = pushNegotiationCB
                opts.callbacks.payload = payload

                // The matching refspec, git's fast-forward rules and its
                // answer to a push with nothing to send all need the
                // remote's refs: connect and ask. The push then reuses
                // the connection.
                var callbacks = opts.callbacks
                try check(git_remote_connect(
                    remoteHandle, GIT_DIRECTION_PUSH, &callbacks, nil, nil))
                let remoteRefs = try advertisedRefs(remoteHandle)
                let pushRefspecs = try expandedPushRefspecs(plan, remoteRefs: Set(remoteRefs.keys))
                guard !pushRefspecs.isEmpty else {
                    git_remote_disconnect(remoteHandle)
                    // git refuses when the negative refspecs leave none
                    // of the remote's refs either.
                    let common = remoteRefs.keys.contains { !plan.excludes($0) }
                    return common ? .nothingToSend : .noRefsInCommon
                }
                // As git does, leave out the updates its rules refuse and
                // push the rest; libgit2 would fail the whole push.
                let (accepted, rejected) = try partitionedPushRefspecs(
                    pushRefspecs, remoteRefs: remoteRefs)
                guard !accepted.isEmpty else {
                    git_remote_disconnect(remoteHandle)
                    return .pushed(accepted: [], rejected: rejected)
                }
                try withCStringArray(accepted) { copies in
                    try copies.withUnsafeMutableBufferPointer { buffer in
                        var arr = git_strarray(strings: buffer.baseAddress, count: buffer.count)
                        let rc = git_remote_push(remoteHandle, &arr, &opts)
                        if rc < 0, let failure = pushLease?.failure {
                            throw failure
                        }
                        try check(rc)
                    }
                }
                return .pushed(accepted: accepted, rejected: rejected)
            },
            outReporter: { reporter = $0 })

        if case .noRefsInCommon = outcome {
            reporter.write("No refs in common and none specified; doing nothing.\n"
                           + "Perhaps you should specify a branch.\n")
            throw Libgit2Error(
                code: GIT_ERROR.rawValue,
                klass: Int32(GIT_ERROR_REFERENCE.rawValue),
                message: "failed to push some refs to "
                    + "'\(ProgressReporter.anonymizedURL(remoteURL ?? remote))'")
        }

        var pushed: [String] = []
        var rejections: [PushRejectedError.Rejection] = []
        if case .pushed(let accepted, let rejected) = outcome {
            (pushed, rejections) = settle(accepted, rejected: rejected, reporter: &reporter)
        }

        // Nothing to send: git says so instead of printing a summary.
        if reporter.refLines.isEmpty {
            reporter.write("Everything up-to-date\n")
        }
        let summary = reporter.refSummary
        reporter.flushRefLines()

        // libgit2 doesn't have a one-shot "push -u": after a push, write
        // the upstream config ourselves for every branch that went
        // through, as `git push --set-upstream` does.
        if setUpstream {
            for refspec in pushed {
                try setUpstreamForRefspec(
                    remote: remote, refspec: refspec, isConfigured: isConfigured)
            }
        }
        guard rejections.isEmpty else {
            throw PushRejectedError(
                url: ProgressReporter.anonymizedURL(remoteURL ?? remote),
                rejections: rejections, pushed: pushed, summary: summary)
        }
        return pushed
    }

    /// What came of a push's updates: the refspecs that went through
    /// (`accepted` but those the remote refused) and every rejection,
    /// git's rules' and the remote's. The rules' rejections get their
    /// summary lines in `reporter`; the remote's already have them.
    private func settle(
        _ accepted: [String],
        rejected: [(refspec: String, reason: PushRejectedError.Reason)],
        reporter: inout ProgressReporter
    ) -> (pushed: [String], rejections: [PushRejectedError.Rejection]) {
        var rejections: [PushRejectedError.Rejection] = []
        for (refspec, reason) in rejected {
            guard let destination = destinationRefName(fromPushRefspec: refspec) else { continue }
            reporter.refLines.append(rejectedSummaryLine(
                refspec, destination: destination, reason: reason,
                abbreviation: reporter.abbreviation))
            rejections.append(.init(remoteRef: destination, reason: reason))
        }
        let refusedByRemote = Set(reporter.remoteRejections.map(\.remoteRef))
        rejections += reporter.remoteRejections
        let pushed = accepted.filter {
            destinationRefName(fromPushRefspec: $0).map { !refusedByRemote.contains($0) } ?? true
        }
        return (pushed, rejections)
    }

    /// ` ! [rejected]        main -> main (fetch first)`: git's summary
    /// line for an update its rules refuse.
    private func rejectedSummaryLine(
        _ refspec: String, destination: String,
        reason: PushRejectedError.Reason, abbreviation: Int
    ) -> String {
        let body = refspec.hasPrefix("+") ? refspec.dropFirst() : Substring(refspec)
        let source = String(body.split(separator: ":", maxSplits: 1,
                                       omittingEmptySubsequences: false)[0])
        let refs = "\(shortRefName(source)) -> \(shortRefName(destination))"
        return pushSummaryLine("!", "[rejected]", "\(refs) (\(reason.summary))",
                               width: 2 * abbreviation + 3)
    }

    /// What `remote` is configured to push (`remote.<name>.push`).
    private func configuredPushRefspecs(_ remote: OpaquePointer?) throws -> [String] {
        var array = git_strarray()
        try check(git_remote_get_push_refspecs(&array, remote))
        defer { git_strarray_dispose(&array) }
        return (0..<array.count).compactMap { index in
            array.strings?[index].map { String(cString: $0) }
        }
    }

    /// The source of `refspec` as typed — `HEAD` in `HEAD:refs/heads/x`,
    /// `main` in `+main` — or `nil` for a deletion (`:dst`) or a pattern
    /// (`refs/heads/*`), whose updates each name their own source.
    func typedPushSource(_ refspec: String) -> String? {
        let body = refspec.hasPrefix("+") ? refspec.dropFirst() : Substring(refspec)
        let source = body.split(separator: ":", maxSplits: 1,
                                omittingEmptySubsequences: false).first ?? ""
        return source.isEmpty || source.contains("*") ? nil : String(source)
    }

    /// `core.abbrev` as git applies it to the push and fetch summaries: a number of
    /// hex digits (4–40), `no` for full IDs, else (unset, `auto`) git's
    /// default of 7.
    func summaryAbbreviation() -> Int {
        guard let value = try? configGet("core.abbrev")?.lowercased() else { return 7 }
        if let length = Int(value) { return min(max(length, 4), 40) }
        return ["no", "false", "off"].contains(value) ? 40 : 7
    }

    /// libgit2's push parser expects fully-qualified refs where the CLI
    /// accepts local branch shorthands like `main` or `topic:other`.
    func qualifiedPushRefspec(_ refspec: String) throws -> String {
        let force = refspec.hasPrefix("+")
        let body = force ? String(refspec.dropFirst()) : refspec
        let prefix = force ? "+" : ""

        let colon = body.firstIndex(of: ":")
        let src = colon.map { String(body[..<$0]) } ?? body
        guard !src.isEmpty, !src.hasPrefix("refs/") else { return refspec }

        let (qualifiedSrc, dstPrefix) = try qualifiedPushSource(src)
        guard let colon else {
            return "\(prefix)\(qualifiedSrc):\(qualifiedSrc)"
        }

        let dstStart = body.index(after: colon)
        let dst = String(body[dstStart...])
        let qualifiedDst = dst.isEmpty || dst.hasPrefix("refs/")
            ? dst
            : "\(dstPrefix)\(dst)"
        return "\(prefix)\(qualifiedSrc):\(qualifiedDst)"
    }

    private func forcePushRefspec(_ refspec: String) -> String {
        refspec.hasPrefix("+") ? refspec : "+\(refspec)"
    }

    private func pushLeaseCheck(
        _ lease: PushLease,
        remote: String,
        refspec: String,
        isConfigured: Bool
    ) throws -> PushLeaseCheck {
        guard let destination = destinationRefName(fromPushRefspec: refspec) else {
            throw Libgit2Error(
                code: GIT_EINVALIDSPEC.rawValue,
                klass: Int32(GIT_ERROR_INVALID.rawValue),
                message: "force-with-lease requires a destination ref")
        }

        let expectedOID: git_oid?
        switch lease {
        case .tracking:
            guard let branch = localBranchName(from: destination) else {
                throw Libgit2Error(
                    code: GIT_EINVALIDSPEC.rawValue,
                    klass: Int32(GIT_ERROR_INVALID.rawValue),
                    message: "force-with-lease tracking requires a branch destination")
            }
            // A URL or path has no remote-tracking refs, so the lease
            // expects the destination to be absent.
            expectedOID = isConfigured
                ? try oidForReference("refs/remotes/\(remote)/\(branch)")
                : nil
        case .expecting(let sha):
            expectedOID = try parseFullOID(sha, label: "force-with-lease expected oid")
        }

        return PushLeaseCheck(remoteRef: destination, expectedOID: expectedOID)
    }

    func destinationRefName(fromPushRefspec refspec: String) -> String? {
        let body = refspec.hasPrefix("+")
            ? String(refspec.dropFirst())
            : refspec

        guard let colon = body.firstIndex(of: ":") else {
            return body.isEmpty ? nil : body
        }

        let dstStart = body.index(after: colon)
        let dst = String(body[dstStart...])
        if !dst.isEmpty { return dst }

        let src = String(body[..<colon])
        return src.isEmpty ? nil : src
    }

    private func qualifiedPushSource(_ src: String) throws -> (String, String) {
        if src == "HEAD" {
            guard let branch = try currentBranch() else { return (src, "") }
            return ("refs/heads/\(branch)", "refs/heads/")
        }

        let branch = "refs/heads/\(src)"
        let tag = "refs/tags/\(src)"
        let hasBranch = try referenceExists(branch)
        let hasTag = try referenceExists(tag)

        if hasBranch && hasTag {
            throw Libgit2Error(
                code: GIT_ERROR.rawValue,
                klass: Int32(GIT_ERROR_REFERENCE.rawValue),
                message: "src refspec \(src) matches more than one")
        }
        if hasBranch { return (branch, "refs/heads/") }
        if hasTag { return (tag, "refs/tags/") }

        throw Libgit2Error(
            code: GIT_ERROR.rawValue,
            klass: Int32(GIT_ERROR_REFERENCE.rawValue),
            message: "src refspec \(src) does not match any")
    }

    private func referenceExists(_ name: String) throws -> Bool {
        var ref: OpaquePointer?
        let rc = git_reference_lookup(&ref, repo, name)
        if rc == 0 {
            git_reference_free(ref)
            return true
        }
        if rc == GIT_ENOTFOUND.rawValue { return false }
        try check(rc)
        return false
    }

    private func oidForReference(_ name: String) throws -> git_oid? {
        var ref: OpaquePointer?
        let rc = git_reference_lookup(&ref, repo, name)
        if rc == GIT_ENOTFOUND.rawValue { return nil }
        try check(rc)
        defer { git_reference_free(ref) }

        var resolved: OpaquePointer?
        try check(git_reference_resolve(&resolved, ref))
        defer { git_reference_free(resolved) }

        guard let target = git_reference_target(resolved) else { return nil }
        return target.pointee
    }

    private func parseFullOID(_ sha: String, label: String) throws -> git_oid {
        var oid = git_oid()
        let rc = sha.withCString { git_oid_fromstrp(&oid, $0) }
        if rc < 0 {
            throw Libgit2Error(
                code: GIT_EINVALID.rawValue,
                klass: Int32(GIT_ERROR_INVALID.rawValue),
                message: "invalid \(label): \(sha)")
        }
        return oid
    }

    /// `<src>:<dst>` form has both sides; bare ref like `main` means
    /// `refs/heads/main:refs/heads/main`. Use the local side as the branch
    /// being configured, and the destination side as its upstream merge ref.
    private func setUpstreamForRefspec(
        remote: String, refspec: String, isConfigured: Bool
    ) throws {
        let body = refspec.hasPrefix("+")
            ? String(refspec.dropFirst())
            : refspec

        let src: String
        let dst: String
        if let colon = body.firstIndex(of: ":") {
            src = String(body[..<colon])
            let dstStart = body.index(after: colon)
            dst = String(body[dstStart...])
        } else {
            src = body
            dst = body
        }

        guard let localBranch = localBranchName(from: src),
              let upstreamBranch = localBranchName(from: dst)
        else { return }

        // A URL or path has no remote-tracking branches to point at;
        // like git, record it as the upstream remote directly.
        guard isConfigured else {
            try configSet("branch.\(localBranch).remote", remote)
            try configSet("branch.\(localBranch).merge", "refs/heads/\(upstreamBranch)")
            return
        }

        var branch: OpaquePointer?
        let lookupRC = git_branch_lookup(&branch, repo, localBranch, GIT_BRANCH_LOCAL)
        guard lookupRC == 0 else { return }
        defer { git_reference_free(branch) }

        try check(git_branch_set_upstream(branch, "\(remote)/\(upstreamBranch)"))
    }

    private func localBranchName(from ref: String) -> String? {
        let prefix = "refs/heads/"
        if ref.hasPrefix(prefix) {
            let name = String(ref.dropFirst(prefix.count))
            return name.isEmpty ? nil : name
        }
        return ref.isEmpty || ref.hasPrefix("refs/") ? nil : ref
    }
}

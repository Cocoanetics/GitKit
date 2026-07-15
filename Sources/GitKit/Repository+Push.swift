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
    ///   - remote: The remote name to push to (e.g. `"origin"`).
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
            remote: remote, refspec: refspec, setUpstream: setUpstream,
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
            remote: remote, refspec: refspec, setUpstream: setUpstream,
            forceWithLease: lease, credentials: credentials, progress: progress)
    }

    private func pushImpl(
        remote: String,
        refspec: String,
        setUpstream: Bool,
        forceWithLease lease: PushLease?,
        credentials: CredentialProvider?,
        progress: @escaping @Sendable (String) -> Void
    ) throws {
        var remoteHandle: OpaquePointer?
        try check(git_remote_lookup(&remoteHandle, repo, remote))
        defer { git_remote_free(remoteHandle) }

        let remoteURL = git_remote_url(remoteHandle).map { String(cString: $0) }
        var reporter = ProgressReporter(
            headerURL: remoteURL, direction: .push, output: progress)
        reporter.suppressTransferProgress =
            ProgressReporter.isLocalURL(remoteURL)

        let qualifiedRefspec = try qualifiedPushRefspec(refspec)
        let pushRefspec = lease == nil
            ? qualifiedRefspec
            : forcePushRefspec(qualifiedRefspec)
        let pushLease = try lease.map {
            try pushLeaseCheck($0, remote: remote, refspec: pushRefspec)
        }

        try pushRefspec.withCString { cstr in
            var copy: UnsafeMutablePointer<CChar>? = strdup(cstr)
            defer { free(copy) }
            try withUnsafeMutablePointer(to: &copy) { copyPtr in
                var arr = git_strarray(strings: copyPtr, count: 1)
                var opts = git_push_options()
                try check(git_push_options_init(&opts, UInt32(GIT_PUSH_OPTIONS_VERSION)))
                try withCallbacksPayload(
                    credentials: credentials, reporter: reporter,
                    pushLease: pushLease,
                    {
                        credCB, sidebandCB, _, _, pushRefCB, packCB,
                        pushTransferCB, pushNegotiationCB, payload in
                        opts.callbacks.credentials = credCB
                        opts.callbacks.sideband_progress = sidebandCB
                        opts.callbacks.push_update_reference = pushRefCB
                        opts.callbacks.pack_progress = packCB
                        opts.callbacks.push_transfer_progress = pushTransferCB
                        opts.callbacks.push_negotiation = pushNegotiationCB
                        opts.callbacks.payload = payload
                        let rc = git_remote_push(remoteHandle, &arr, &opts)
                        if rc < 0, let failure = pushLease?.failure {
                            throw failure
                        }
                        try check(rc)
                    },
                    outReporter: { reporter = $0 })
            }
        }

        reporter.flushRefLines()

        // libgit2 doesn't have a one-shot "push -u": after a successful
        // push, write the upstream config ourselves to mirror the CLI's
        // `--set-upstream` semantics.
        if setUpstream {
            try setUpstreamForRefspec(remote: remote, refspec: pushRefspec)
        }
    }

    /// libgit2's push parser expects fully-qualified refs where the CLI
    /// accepts local branch shorthands like `main` or `topic:other`.
    private func qualifiedPushRefspec(_ refspec: String) throws -> String {
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
        refspec: String
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
            expectedOID = try oidForReference("refs/remotes/\(remote)/\(branch)")
        case .expecting(let sha):
            expectedOID = try parseFullOID(sha, label: "force-with-lease expected oid")
        }

        return PushLeaseCheck(remoteRef: destination, expectedOID: expectedOID)
    }

    private func destinationRefName(fromPushRefspec refspec: String) -> String? {
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
        if src == "HEAD" { return (src, "refs/heads/") }

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
    private func setUpstreamForRefspec(remote: String, refspec: String) throws {
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

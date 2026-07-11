import Foundation
import CGitKit

extension Repository {

    // MARK: Clone

    /// Clone `url` into `directory` and return the new repository open.
    ///
    /// - Parameters:
    ///   - depth: Limit history to the last `depth` commits per tip — a
    ///     shallow clone (`git clone --depth N`). `nil` (the default) or a
    ///     non-positive value clones full history. Deepen later with
    ///     ``unshallow(remote:refspec:credentials:progress:)``.
    ///   - singleBranch: Fetch only one branch's refs rather than every
    ///     remote branch (`git clone --single-branch`). The branch is
    ///     `branch` when given, otherwise the remote's default branch.
    ///   - branch: The branch to check out (`git clone --branch`); `nil`
    ///     uses the remote's default. Combine with `singleBranch` to also
    ///     restrict which refs are transferred.
    ///   - credentials: invoked by the transport on auth challenges.
    ///   - progress: sink for real-git-style transfer progress lines
    ///     (defaults to the process's stderr).
    @discardableResult
    public static func clone(
        from url: URL,
        to directory: URL,
        depth: Int? = nil,
        singleBranch: Bool = false,
        branch: String? = nil,
        credentials: CredentialProvider? = nil,
        progress: @escaping @Sendable (String) -> Void = GitProgress.standardError
    ) throws -> Repository {
        Libgit2.ensureInitialized()

        var opts = git_clone_options()
        try check(git_clone_options_init(&opts, UInt32(GIT_CLONE_OPTIONS_VERSION)))

        if let depth = normalizedDepth(depth) {
            opts.fetch_opts.depth = depth
        }

        var reporter = ProgressReporter(
            headerURL: url.absoluteString, direction: .fetch, output: progress)
        // Real git's local clone (file:// or bare path) skips the
        // `remote: …` / `Receiving objects: …` lines — match it.
        reporter.suppressTransferProgress =
            ProgressReporter.isLocalURL(url.absoluteString)

        // Single-branch installs a `remote_cb` whose payload must outlive
        // the `git_clone` call; retain it here and release on the way out.
        let singleBranchRaw: UnsafeMutableRawPointer? = singleBranch
            ? Unmanaged.passRetained(
                SingleBranchBox(branch: branch, credentials: credentials)).toOpaque()
            : nil
        defer {
            if let singleBranchRaw {
                Unmanaged<SingleBranchBox>.fromOpaque(singleBranchRaw).release()
            }
        }
        if let singleBranchRaw {
            opts.remote_cb = singleBranchRemoteTrampoline
            opts.remote_cb_payload = singleBranchRaw
        }

        var out: OpaquePointer?
        // libgit2 holds `checkout_branch` as a non-owning pointer for the
        // duration of the clone; keep the C string alive across the call.
        func runClone() throws {
            try withCallbacksPayload(
                credentials: credentials, reporter: reporter,
                { credCB, sidebandCB, transferCB, _, _, _, _, _, payload in
                    opts.fetch_opts.callbacks.credentials = credCB
                    opts.fetch_opts.callbacks.sideband_progress = sidebandCB
                    opts.fetch_opts.callbacks.transfer_progress = transferCB
                    opts.fetch_opts.callbacks.payload = payload

                    try check(git_clone(&out, url.absoluteString, directory.path, &opts))
                },
                outReporter: { reporter = $0 })
        }
        if let branch {
            try branch.withCString { cstr in
                opts.checkout_branch = cstr
                try runClone()
            }
        } else {
            try runClone()
        }
        // No `From`/per-ref block on clone — real git just prints
        // `Cloning into '…'` (handled by the CLI subcommand) plus the
        // transfer progress lines we already emitted.
        guard let out else {
            throw Libgit2Error(code: -1, klass: 0, message: "git_clone returned no repository")
        }
        return Repository(pointer: out)
    }

    // MARK: Fetch

    /// Fetch `refspec` from `remote`, updating remote-tracking refs.
    /// Mirrors `git fetch <remote> <refspec>` including its progress output.
    ///
    /// - Parameters:
    ///   - remote: The remote name to fetch from (e.g. `"origin"`).
    ///   - refspec: The refspec to fetch (e.g. `"main"` or
    ///     `"+refs/heads/*:refs/remotes/origin/*"`).
    ///   - depth: Limit the fetch to the last `depth` commits per tip — a
    ///     shallow fetch (`git fetch --depth N`). `nil` (the default) or a
    ///     non-positive value fetches full history.
    ///   - credentials: Invoked by the transport on auth challenges.
    ///   - progress: Sink for real-git-style progress lines (defaults to
    ///     the process's stderr).
    public func fetch(
        remote: String,
        refspec: String,
        depth: Int? = nil,
        credentials: CredentialProvider? = nil,
        progress: @escaping @Sendable (String) -> Void = GitProgress.standardError
    ) throws {
        try fetch(
            remote: remote, refspec: refspec,
            rawDepth: Repository.normalizedDepth(depth) ?? Int32(GIT_FETCH_DEPTH_FULL.rawValue),
            credentials: credentials, progress: progress)
    }

    /// Deepen a shallow clone back to full history — the libgit2 equivalent
    /// of `git fetch --unshallow`. Fetches `refspec` from `remote` with
    /// `GIT_FETCH_DEPTH_UNSHALLOW`, dropping the shallow boundary so the
    /// node that started minimal can pull the rest on demand.
    ///
    /// - Parameters:
    ///   - remote: The remote name to fetch from (e.g. `"origin"`).
    ///   - refspec: The refspec to unshallow (e.g.
    ///     `"+refs/heads/*:refs/remotes/origin/*"`).
    ///   - credentials: Invoked by the transport on auth challenges.
    ///   - progress: Sink for real-git-style progress lines (defaults to
    ///     the process's stderr).
    public func unshallow(
        remote: String,
        refspec: String,
        credentials: CredentialProvider? = nil,
        progress: @escaping @Sendable (String) -> Void = GitProgress.standardError
    ) throws {
        try fetch(
            remote: remote, refspec: refspec,
            rawDepth: Int32(GIT_FETCH_DEPTH_UNSHALLOW.rawValue),
            credentials: credentials, progress: progress)
    }

    private func fetch(
        remote: String,
        refspec: String,
        rawDepth: Int32,
        credentials: CredentialProvider?,
        progress: @escaping @Sendable (String) -> Void
    ) throws {
        var remoteHandle: OpaquePointer?
        try check(git_remote_lookup(&remoteHandle, repo, remote))
        defer { git_remote_free(remoteHandle) }

        // Pull the remote URL out of the handle for the `From <url>` header.
        let remoteURL = git_remote_url(remoteHandle).map { String(cString: $0) }
        var reporter = ProgressReporter(
            headerURL: remoteURL, direction: .fetch, output: progress)
        reporter.suppressTransferProgress =
            ProgressReporter.isLocalURL(remoteURL)

        try refspec.withCString { cstr in
            var copy: UnsafeMutablePointer<CChar>? = strdup(cstr)
            defer { free(copy) }
            try withUnsafeMutablePointer(to: &copy) { copyPtr in
                var arr = git_strarray(strings: copyPtr, count: 1)
                var opts = git_fetch_options()
                try check(git_fetch_options_init(&opts, UInt32(GIT_FETCH_OPTIONS_VERSION)))
                opts.depth = rawDepth
                try withCallbacksPayload(
                    credentials: credentials, reporter: reporter,
                    { credCB, sidebandCB, transferCB, updateCB, _, _, _, _, payload in
                        opts.callbacks.credentials = credCB
                        opts.callbacks.sideband_progress = sidebandCB
                        opts.callbacks.transfer_progress = transferCB
                        // `update_refs` is the modern slot; libgit2
                        // treats both update_refs and update_tips as
                        // valid but prefers update_refs.
                        opts.callbacks.update_refs = updateCB
                        opts.callbacks.payload = payload
                        try check(git_remote_fetch(remoteHandle, &arr, &opts, nil))
                    },
                    outReporter: { reporter = $0 })
            }
        }
        reporter.flushRefLines()
    }

    // MARK: Depth

    /// Map the public `depth: Int?` knob to libgit2's `int` depth field:
    /// `nil` or a non-positive value ⇒ `nil` (leave the option at its
    /// full-history default); a positive value is clamped into `Int32`
    /// range. Kept in one place so `clone` and `fetch` agree.
    static func normalizedDepth(_ depth: Int?) -> Int32? {
        guard let depth, depth > 0 else { return nil }
        return Int32(clamping: depth)
    }
}

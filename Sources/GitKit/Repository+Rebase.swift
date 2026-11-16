import Foundation
import CGitKit

/// Result of a rebase invocation.
public enum RebaseOutcome: Sendable {
    /// `<branch>` already contains every commit in `<upstream>` —
    /// libgit2 found zero rebase operations to apply.
    case alreadyUpToDate(branchRefName: String?)
    /// Every operation was applied and the branch now points at the
    /// new tip. Carries the count of commits replayed plus the final
    /// branch refname (e.g. `refs/heads/feature`) for the
    /// `Successfully rebased and updated <ref>.` line.
    case completed(branchRefName: String, commitsApplied: Int)
    /// The current operation produced a conflict. The rebase state is
    /// persisted in `.git/rebase-merge/`; the caller can resume with
    /// `rebaseContinue` after fixing the working tree, or wipe it with
    /// `rebaseAbort`. Carries the offending commit's SHA + subject and
    /// the conflicted paths so the CLI can format real-git's
    /// `error: could not apply <sha7>... <subject>` line.
    case conflict(commitSHA: String, commitSubject: String, paths: [String])
}

extension Repository {

    /// Replay the current branch's commits since its merge-base with
    /// `upstream` on top of `upstream` (or `onto` when supplied).
    /// Equivalent to `git rebase <upstream> [--onto <onto>]`.
    ///
    /// `sign` overrides `commit.gpgsign` for every replayed commit
    /// (`-S[<key>]` / `--no-gpg-sign`). An explicit choice is kept in
    /// `rebase-merge/gpg_sign_opt`, as git keeps it, so a later
    /// ``rebaseContinue(author:progress:env:sign:)`` or
    /// ``rebaseSkip(author:progress:env:sign:)`` signs the same way.
    /// `env` resolves the committer; each replayed commit keeps its author
    /// and author date. `author` overrides only that author's name/email.
    public func rebase(
        upstream upstreamSpec: String,
        onto ontoSpec: String? = nil,
        author: Signature? = nil,
        progress: (@Sendable (Int, Int) -> Void)? = nil,
        env: [String: String] = [:],
        sign: SignMode = .config
    ) throws -> RebaseOutcome {
        // Resolve the three annotated commits libgit2 needs: branch
        // (the work being moved — current HEAD), upstream (its
        // current base), onto (where we'll land — defaults to upstream).
        var branchAC: OpaquePointer?
        var head: OpaquePointer?
        try check(git_repository_head(&head, repo))
        defer { git_reference_free(head) }
        try check(git_annotated_commit_from_ref(&branchAC, repo, head))
        defer { git_annotated_commit_free(branchAC) }

        var upstreamAC: OpaquePointer?
        try check(git_annotated_commit_from_revspec(
            &upstreamAC, repo, upstreamSpec))
        defer { git_annotated_commit_free(upstreamAC) }

        var ontoAC: OpaquePointer?
        if let ontoSpec {
            try check(git_annotated_commit_from_revspec(
                &ontoAC, repo, ontoSpec))
        }
        defer { if ontoAC != nil { git_annotated_commit_free(ontoAC) } }

        // Pull current branch refname for the success/up-to-date line
        // before we hand control to the rebase machinery.
        let branchRefName: String? = {
            guard let cstr = git_reference_name(head) else { return nil }
            return String(cString: cstr)
        }()

        // Resolved before libgit2 writes any rebase state.
        let signing = try RebaseSigning(repository: self, sign: sign)
        let committer = try SignatureResolver.resolve(role: .committer, repo: repo, env: env)
        defer { git_signature_free(committer) }
        var rebase: OpaquePointer?
        var opts = try rebaseOptions(signing)
        try check(git_rebase_init(
            &rebase, repo, branchAC, upstreamAC, ontoAC, &opts))
        // Don't free until we know we're done — on conflict we leave
        // the rebase persisted on disk and free our handle (libgit2
        // separates in-memory rebase from on-disk state). The handle
        // holds the signing payload, so that lives as long.
        defer {
            if rebase != nil { git_rebase_free(rebase) }
            withExtendedLifetime(signing) {}
        }
        try restampLatestReflog("HEAD", committer: committer)

        let total = Int(git_rebase_operation_entrycount(rebase))
        if total == 0 {
            // libgit2 still wrote `.git/rebase-merge/`; clean up so
            // a follow-up `--continue` doesn't think we're paused.
            try check(git_rebase_abort(rebase))
            return .alreadyUpToDate(branchRefName: branchRefName)
        }
        try persistSignMode(sign)

        return try runRebaseLoop(
            rebase: rebase, repo: repo, total: total,
            author: author, progress: progress, env: env,
            branchRefName: branchRefName, signing: signing)
    }

    /// Continue a rebase paused on a conflict. The caller is expected to
    /// have resolved every conflicted file and `add`-staged the result.
    /// Throws if no rebase is in progress. `sign` other than `.config`
    /// overrides the signing choice the rebase was started with.
    public func rebaseContinue(
        author: Signature? = nil,
        progress: (@Sendable (Int, Int) -> Void)? = nil,
        env: [String: String] = [:],
        sign: SignMode = .config
    ) throws -> RebaseOutcome {
        let signing = try RebaseSigning(repository: self, sign: persistedSignMode(overriddenBy: sign))
        var rebase: OpaquePointer?
        var opts = try rebaseOptions(signing)
        let openRC = git_rebase_open(&rebase, repo, &opts)
        if openRC == GIT_ENOTFOUND.rawValue {
            throw Libgit2Error(code: -1, klass: 0,
                message: "no rebase in progress")
        }
        try check(openRC)
        defer {
            if rebase != nil { git_rebase_free(rebase) }
            withExtendedLifetime(signing) {}
        }

        // Commit the resolved conflict from the previous step before
        // resuming the loop. Skip when the index is empty (e.g. user
        // ran `--continue` after `--skip` shifted past everything).
        // Compare in `size_t` space and short-circuit on the
        // "no current operation" sentinel before narrowing to `Int`:
        // libgit2 returns `SIZE_MAX` (== `size_t.max`) here, which
        // overflows a signed `Int`. The Swift importer also drops
        // the `GIT_REBASE_NO_OPERATION` macro on the Android SDK
        // (`#define … SIZE_MAX` evaluates platform-dependently),
        // so we use `size_t.max` directly instead.
        let totalRaw = git_rebase_operation_entrycount(rebase)
        let currentRaw = git_rebase_operation_current(rebase)
        let total = Int(totalRaw)
        if currentRaw != size_t.max && currentRaw < totalRaw {
            try commitCurrent(rebase: rebase, repo: repo, author: author, env: env, signing: signing)
        }

        // Pick branch refname out of the rebase struct itself; HEAD
        // is detached during rebases so git_repository_head's
        // shorthand isn't useful.
        let branchRefName = git_rebase_orig_head_name(rebase)
            .map { String(cString: $0) }

        return try runRebaseLoop(
            rebase: rebase, repo: repo, total: total,
            author: author, progress: progress, env: env,
            branchRefName: branchRefName, signing: signing)
    }

    /// Skip the conflicting commit and resume the rebase. Resets the
    /// working tree + index to the rebase's last clean step, advances
    /// past the offending operation without committing it, and runs
    /// the loop until done or another conflict. `sign` other than
    /// `.config` overrides the signing choice the rebase was started with.
    public func rebaseSkip(
        author: Signature? = nil,
        progress: (@Sendable (Int, Int) -> Void)? = nil,
        env: [String: String] = [:],
        sign: SignMode = .config
    ) throws -> RebaseOutcome {
        let signing = try RebaseSigning(repository: self, sign: persistedSignMode(overriddenBy: sign))
        var rebase: OpaquePointer?
        var opts = try rebaseOptions(signing)
        let openRC = git_rebase_open(&rebase, repo, &opts)
        if openRC == GIT_ENOTFOUND.rawValue {
            throw Libgit2Error(code: -1, klass: 0,
                message: "no rebase in progress")
        }
        try check(openRC)
        defer {
            if rebase != nil { git_rebase_free(rebase) }
            withExtendedLifetime(signing) {}
        }

        // Force-checkout HEAD to clear conflict markers + the
        // partially-applied index so git_rebase_next can advance.
        var coOpts = git_checkout_options()
        try check(git_checkout_options_init(
            &coOpts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
        coOpts.checkout_strategy = UInt32(GIT_CHECKOUT_FORCE.rawValue)
        try check(git_checkout_head(repo, &coOpts))

        let total = Int(git_rebase_operation_entrycount(rebase))
        let branchRefName = git_rebase_orig_head_name(rebase)
            .map { String(cString: $0) }

        return try runRebaseLoop(
            rebase: rebase, repo: repo, total: total,
            author: author, progress: progress, env: env,
            branchRefName: branchRefName, signing: signing)
    }

    /// Wipe an in-progress rebase, restoring the working tree + HEAD to
    /// the state captured before `rebase` started. Throws when there's
    /// no rebase to abort.
    public func rebaseAbort() throws {
        var rebase: OpaquePointer?
        var opts = git_rebase_options()
        try check(git_rebase_options_init(
            &opts, UInt32(GIT_REBASE_OPTIONS_VERSION)))
        let openRC = git_rebase_open(&rebase, repo, &opts)
        if openRC == GIT_ENOTFOUND.rawValue {
            throw Libgit2Error(code: -1, klass: 0,
                message: "no rebase in progress")
        }
        try check(openRC)
        defer { if rebase != nil { git_rebase_free(rebase) } }
        try check(git_rebase_abort(rebase))
    }

    // MARK: Loop

    /// Drive `git_rebase_next` until it returns `GIT_ITEROVER`. Pauses
    /// at the first conflict and surfaces a `RebaseOutcome.conflict`.
    private func runRebaseLoop(
        rebase: OpaquePointer?,
        repo: OpaquePointer?,
        total: Int,
        author: Signature?,
        progress: ((Int, Int) -> Void)?,
        env: [String: String],
        branchRefName: String?,
        signing: RebaseSigning
    ) throws -> RebaseOutcome {
        var applied = 0
        while true {
            var operation: UnsafeMutablePointer<git_rebase_operation>?
            let rc = git_rebase_next(&operation, rebase)
            if rc == GIT_ITEROVER.rawValue { break }
            try check(rc)

            let current = Int(git_rebase_operation_current(rebase)) + 1
            progress?(current, total)

            // Real git's rebase machinery merges into the working tree
            // and writes index entries — same conflict surface as merge.
            var index: OpaquePointer?
            try check(git_repository_index(&index, repo))
            let hasConflicts = git_index_has_conflicts(index) != 0
            if hasConflicts {
                let paths = try conflictPaths(index: index)
                git_index_free(index)

                let info = try commitInfo(repo: repo, operation: operation)
                return .conflict(
                    commitSHA: info.shortSHA,
                    commitSubject: info.subject,
                    paths: paths)
            }
            git_index_free(index)

            try commitCurrent(rebase: rebase, repo: repo, author: author, env: env, signing: signing)
            applied += 1
        }

        // All operations applied — finalize: writes `refs/heads/<branch>`
        // to the new tip and removes `.git/rebase-merge/`.
        let finishSig = try SignatureResolver.resolve(role: .committer, repo: repo, env: env)
        defer { git_signature_free(finishSig) }
        try check(git_rebase_finish(rebase, finishSig))
        // libgit2 uses its default identity for the ref updates in finish,
        // even when given a signature (that argument only signs notes).
        try restampLatestReflog("HEAD", committer: finishSig)
        if let branchRefName { try restampLatestReflog(branchRefName, committer: finishSig) }

        return .completed(
            branchRefName: branchRefName ?? "HEAD",
            commitsApplied: applied)
    }

    /// Commit the current rebase step. Reuses the cherry-picked
    /// commit's author + message (we just supply the committer).
    private func commitCurrent(
        rebase: OpaquePointer?,
        repo: OpaquePointer?,
        author: Signature?,
        env: [String: String],
        signing: RebaseSigning
    ) throws {
        let sig = try SignatureResolver.resolve(role: .committer, repo: repo, env: env)
        defer { git_signature_free(sig) }
        var authorSig: UnsafeMutablePointer<git_signature>?
        if let author {
            let current = git_rebase_operation_current(rebase)
            guard let operation = git_rebase_operation_byindex(rebase, current) else {
                throw Libgit2Error(code: -1, klass: 0, message: "no current rebase operation")
            }
            var original: OpaquePointer?
            var originalOID = operation.pointee.id
            try check(git_commit_lookup(&original, repo, &originalOID))
            defer { git_commit_free(original) }
            let date = ResolvedSignature(git_commit_author(original))
            let offset = abs(Int(date.offsetMinutes))
            let zone = String(format: "%@%02d%02d", date.offsetMinutes < 0 ? "-" : "+", offset / 60, offset % 60)
            authorSig = try SignatureResolver.resolve(role: .author, override: author, repo: repo,
                env: ["GIT_AUTHOR_DATE": "\(date.time) \(zone)"])
        }
        defer { git_signature_free(authorSig) }

        var oid = git_oid()
        // Pass nil author/message_encoding/message → libgit2 reuses the
        // original commit's author and message verbatim.
        let rc = git_rebase_commit(&oid, rebase, authorSig, sig, nil, nil)
        // The signer's own error, not libgit2's GIT_EUSER.
        if let error = signing.error {
            signing.error = nil
            throw error
        }
        try check(rc)
    }

    // MARK: Signing

    /// `git_rebase_options` whose commit callback signs through
    /// `signing`, which must outlive the rebase handle.
    private func rebaseOptions(_ signing: RebaseSigning) throws -> git_rebase_options {
        var opts = git_rebase_options()
        try check(git_rebase_options_init(
            &opts, UInt32(GIT_REBASE_OPTIONS_VERSION)))
        opts.payload = Unmanaged.passUnretained(signing).toOpaque()
        opts.commit_create_cb = { out, author, committer, encoding, message, tree, count, parents, payload in
            guard let out, let message, let payload else { return GIT_PASSTHROUGH.rawValue }
            let signing = Unmanaged<RebaseSigning>.fromOpaque(payload).takeUnretainedValue()
            guard signing.enabled else { return GIT_PASSTHROUGH.rawValue }
            do {
                // Only the object: libgit2 moves HEAD and writes the reflog.
                // The message goes on as raw bytes, whatever its encoding.
                let parents = (0..<count).map { parents?[$0] }
                out.pointee = try signing.repository.createCommit(
                    updateRef: nil, author: author, committer: committer,
                    encoding: encoding.map { String(cString: $0) }, message: message,
                    tree: tree, parents: parents, sign: signing.sign)
                return 0
            } catch {
                signing.error = error
                return GIT_EUSER.rawValue
            }
        }
        return opts
    }

    private var gpgSignOptURL: URL {
        URL(fileURLWithPath: String(cString: git_repository_path(repo)))
            .appendingPathComponent("rebase-merge/gpg_sign_opt")
    }

    /// Keep an explicit signing choice for a later continue or skip, as
    /// git's `-S[<key>]` does. `.config` is read again when resuming.
    private func persistSignMode(_ sign: SignMode) throws {
        let option: String
        switch sign {
        case .config: return
        case .sign(let key): option = "-S" + (key ?? "")
        case .noSign: option = "--no-gpg-sign"
        }
        try Data((option + "\n").utf8).write(to: gpgSignOptURL)
    }

    /// The signing choice a rebase was started with, unless `sign` is
    /// an explicit override.
    private func persistedSignMode(overriddenBy sign: SignMode) -> SignMode {
        guard sign == .config, let data = FileManager.default.contents(atPath: gpgSignOptURL.path) else {
            return sign
        }
        let option = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        if option == "--no-gpg-sign" { return .noSign }
        guard option.hasPrefix("-S") else { return .config }
        let key = String(option.dropFirst(2))
        return .sign(keyID: key.isEmpty ? nil : key)
    }

    /// SHA + subject of the commit being cherry-picked in `operation` —
    /// the strings that go into real-git's
    /// `error: could not apply <sha7>... <subject>` line.
    private func commitInfo(
        repo: OpaquePointer?,
        operation: UnsafeMutablePointer<git_rebase_operation>?
    ) throws -> (shortSHA: String, subject: String) {
        guard let op = operation else {
            return (shortSHA: "0000000", subject: "")
        }
        var oid = op.pointee.id
        var commit: OpaquePointer?
        try check(git_commit_lookup(&commit, repo, &oid))
        defer { git_commit_free(commit) }

        let sha = formatOID(&oid)
        let shortSHA = String(sha.prefix(7))
        let messagePtr = git_commit_message(commit)
        let full = messagePtr.map { String(cString: $0) } ?? ""
        let subject = full.split(separator: "\n").first.map(String.init) ?? ""
        return (shortSHA, subject)
    }

    /// Walk the conflict iterator, returning paths that need resolution.
    /// Same shape as the merge implementation's helper.
    private func conflictPaths(index: OpaquePointer?) throws -> [String] {
        var iter: OpaquePointer?
        try check(git_index_conflict_iterator_new(&iter, index))
        defer { git_index_conflict_iterator_free(iter) }

        var paths: [String] = []
        while true {
            var ancestor: UnsafePointer<git_index_entry>?
            var ours: UnsafePointer<git_index_entry>?
            var theirs: UnsafePointer<git_index_entry>?
            let rc = git_index_conflict_next(&ancestor, &ours, &theirs, iter)
            if rc == GIT_ITEROVER.rawValue { break }
            try check(rc)
            let entry = ours ?? theirs ?? ancestor
            if let p = entry?.pointee.path {
                paths.append(String(cString: p))
            }
        }
        return paths
    }
}

/// What a rebase's `commit_create_cb` needs, and the signer error it
/// hands back across the C call.
private final class RebaseSigning {
    let repository: Repository
    let sign: SignMode
    /// Resolved once per operation; off leaves the commit to libgit2.
    let enabled: Bool
    var error: Error?

    init(repository: Repository, sign: SignMode) throws {
        self.repository = repository
        self.sign = sign
        enabled = try SigningConfig.resolve(sign, repository: repository) != nil
    }
}

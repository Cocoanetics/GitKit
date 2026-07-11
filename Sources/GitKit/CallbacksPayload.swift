import Foundation
import CGitKit

/// Combined heap-allocated box held by every libgit2 callback during a
/// fetch/clone/push. libgit2's `git_remote_callbacks` has one `payload`
/// pointer that's passed to *every* callback — credentials, sideband,
/// transfer, update_refs, push_update_reference, etc. — so we have to
/// stuff every Swift-side state in one shared bag.
final class CallbackBox {
    let credentialsProvider: CredentialProvider?
    var reporter: ProgressReporter?
    let pushLease: PushLeaseCheck?

    init(
        credentials: CredentialProvider?,
        reporter: ProgressReporter?,
        pushLease: PushLeaseCheck? = nil
    ) {
        self.credentialsProvider = credentials
        self.reporter = reporter
        self.pushLease = pushLease
    }
}

final class PushLeaseCheck {
    let remoteRef: String
    let expectedOID: git_oid?
    var failure: Libgit2Error?

    init(remoteRef: String, expectedOID: git_oid?) {
        self.remoteRef = remoteRef
        self.expectedOID = expectedOID
    }

    func verify(
        updates: UnsafeMutablePointer<UnsafePointer<git_push_update>?>?,
        count: Int
    ) -> Int32 {
        guard let updates else {
            failure = leaseError(message: "force-with-lease rejected \(remoteRef): push did not negotiate updates")
            return GIT_EMODIFIED.rawValue
        }

        for i in 0..<count {
            guard let update = updates[i],
                  let dstRefname = update.pointee.dst_refname
            else { continue }

            let candidate = String(cString: dstRefname)
            guard candidate == remoteRef else { continue }

            var actual = update.pointee.src
            var desired = update.pointee.dst
            if git_oid_cmp(&actual, &desired) == 0 { return 0 }

            if let expectedOID {
                var expected = expectedOID
                if git_oid_cmp(&actual, &expected) == 0 { return 0 }
            } else if git_oid_is_zero(&actual) != 0 {
                return 0
            }

            failure = leaseError(
                message: "force-with-lease rejected \(remoteRef): expected "
                    + "\(expectedDescription), found \(oidDescription(&actual))")
            return GIT_EMODIFIED.rawValue
        }

        failure = leaseError(message: "force-with-lease rejected \(remoteRef): push did not update that ref")
        return GIT_EMODIFIED.rawValue
    }

    private var expectedDescription: String {
        guard var expected = expectedOID else { return "missing" }
        return oidDescription(&expected)
    }

    private func leaseError(message: String) -> Libgit2Error {
        Libgit2Error(
            code: GIT_EMODIFIED.rawValue,
            klass: Int32(GIT_ERROR_REFERENCE.rawValue),
            message: message)
    }
}

private func oidDescription(_ oid: inout git_oid) -> String {
    if git_oid_is_zero(&oid) != 0 { return "missing" }
    let buf = UnsafeMutablePointer<CChar>.allocate(capacity: 41)
    defer { buf.deallocate() }
    buf.initialize(repeating: 0, count: 41)
    _ = git_oid_tostr(buf, 41, &oid)
    return String(cString: buf)
}

/// Run `body` with a shared raw payload pointer plus the C trampolines
/// each callback slot wants. The reporter's final state is synced back
/// to `outReporter` so the caller can flush pending lines.
///
/// Pass `credentials: nil` and `reporter: nil` to get null trampolines
/// (no callbacks installed).
func withCallbacksPayload<T>(
    credentials: CredentialProvider?,
    reporter: ProgressReporter?,
    pushLease: PushLeaseCheck? = nil,
    _ body: (
        _ credentialsCB: git_credential_acquire_cb?,
        _ sidebandCB: git_transport_message_cb?,
        _ transferCB: git_indexer_progress_cb?,
        _ updateRefsCB: ((@convention(c) (
            UnsafePointer<CChar>?, UnsafePointer<git_oid>?, UnsafePointer<git_oid>?,
            OpaquePointer?, UnsafeMutableRawPointer?) -> Int32))?,
        _ pushRefCB: git_push_update_reference_cb?,
        _ packCB: git_packbuilder_progress?,
        _ pushTransferCB: git_push_transfer_progress_cb?,
        _ pushNegotiationCB: git_push_negotiation?,
        _ payload: UnsafeMutableRawPointer?
    ) throws -> T,
    outReporter: (inout ProgressReporter) -> Void = { _ in }
) rethrows -> T {
    if credentials == nil && reporter == nil && pushLease == nil {
        return try body(nil, nil, nil, nil, nil, nil, nil, nil, nil)
    }
    let box = CallbackBox(
        credentials: credentials, reporter: reporter, pushLease: pushLease)
    let raw = Unmanaged.passRetained(box).toOpaque()
    defer {
        if var r = box.reporter { outReporter(&r); box.reporter = r }
        Unmanaged<CallbackBox>.fromOpaque(raw).release()
    }

    let credCB = credentials != nil ? combinedCredentialsTrampoline : nil
    let sidebandCB = reporter != nil ? combinedSidebandTrampoline : nil
    let transferCB = reporter != nil ? combinedTransferTrampoline : nil
    let updateCB = reporter != nil ? combinedUpdateRefsTrampoline : nil
    let pushRefCB = reporter != nil ? combinedPushRefTrampoline : nil
    let packCB = reporter != nil ? combinedPackProgressTrampoline : nil
    let pushTransferCB = reporter != nil ? combinedPushTransferTrampoline : nil
    let pushNegotiationCB = pushLease != nil ? combinedPushNegotiationTrampoline : nil
    return try body(credCB, sidebandCB, transferCB, updateCB, pushRefCB,
                    packCB, pushTransferCB, pushNegotiationCB, raw)
}

// MARK: Single-branch clone

/// Heap-allocated payload for the `remote_cb` a single-branch clone
/// installs. It carries the branch to restrict the clone to (or `nil`
/// to mean the remote's default branch, resolved on the fly) plus the
/// credentials the pre-flight connection needs when the default branch
/// has to be discovered from a private remote.
final class SingleBranchBox {
    /// The branch shorthand (e.g. `"main"`) to restrict the fetch
    /// refspec to, or `nil` to use the remote's advertised default.
    let branch: String?
    let credentialsProvider: CredentialProvider?

    init(branch: String?, credentials: CredentialProvider?) {
        self.branch = branch
        self.credentialsProvider = credentials
    }
}

/// `remote_cb` for `git_clone`: create the `origin` remote with a fetch
/// refspec restricted to a single branch, so only that branch's refs are
/// negotiated and transferred (real git's `--single-branch`). Without
/// this, `git_clone` writes the catch-all `+refs/heads/*:…` refspec and
/// pulls every branch even when `checkout_branch` is set.
let singleBranchRemoteTrampoline: git_remote_create_cb = {
    out, repo, name, url, payload in
    guard let out, let repo, let name, let url, let payload else { return -1 }
    let box = Unmanaged<SingleBranchBox>.fromOpaque(payload).takeUnretainedValue()

    // Resolve the concrete branch the refspec should name. An explicit
    // branch wins; otherwise ask the remote for its default.
    let branchShort: String
    if let requested = box.branch {
        branchShort = requested
    } else if let resolved = resolveDefaultBranch(url: url, box: box) {
        branchShort = resolved
    } else {
        return -1
    }

    let remoteName = String(cString: name)
    let refspec = "+refs/heads/\(branchShort):refs/remotes/\(remoteName)/\(branchShort)"
    return refspec.withCString { rs in
        git_remote_create_with_fetchspec(out, repo, name, url, rs)
    }
}

/// Peek a remote's default branch (its `HEAD` target) without a full
/// clone: spin up a detached remote, connect, ask, tear down. Returns the
/// branch shorthand (`"main"`), or `nil` on any failure.
private func resolveDefaultBranch(
    url: UnsafePointer<CChar>, box: SingleBranchBox
) -> String? {
    var tmp: OpaquePointer?
    guard git_remote_create_detached(&tmp, url) == 0 else { return nil }
    defer { git_remote_free(tmp) }

    var cbs = git_remote_callbacks()
    guard git_remote_init_callbacks(
        &cbs, UInt32(GIT_REMOTE_CALLBACKS_VERSION)) == 0 else { return nil }
    if box.credentialsProvider != nil {
        cbs.credentials = singleBranchCredentialsTrampoline
        cbs.payload = Unmanaged.passUnretained(box).toOpaque()
    }
    guard git_remote_connect(
        tmp, GIT_DIRECTION_FETCH, &cbs, nil, nil) == 0 else { return nil }
    defer { git_remote_disconnect(tmp) }

    var buf = git_buf()
    defer { git_buf_dispose(&buf) }
    guard git_remote_default_branch(&buf, tmp) == 0, let ptr = buf.ptr else {
        return nil
    }
    let full = String(cString: ptr)   // e.g. "refs/heads/main"
    let prefix = "refs/heads/"
    return full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : full
}

/// Credentials trampoline for the default-branch pre-flight connection.
/// Mirrors ``combinedCredentialsTrampoline`` but reads a
/// ``SingleBranchBox`` payload (the connection is separate from the clone
/// fetch and so carries its own payload).
private let singleBranchCredentialsTrampoline: git_credential_acquire_cb = {
    outPtr, urlCStr, userCStr, allowedTypes, payload in
    guard let payload, let outPtr else { return -1 }
    let box = Unmanaged<SingleBranchBox>.fromOpaque(payload).takeUnretainedValue()
    guard let provider = box.credentialsProvider else { return -30 }

    let url: URL = {
        if let urlCStr, let parsed = URL(string: String(cString: urlCStr)) {
            return parsed
        }
        return URL(string: "about:blank")!
    }()
    let usernameFromURL: String? = userCStr.map { String(cString: $0) }
    let allowed = CredentialKind(rawValue: allowedTypes)

    guard let creds = provider(url, usernameFromURL, allowed) else {
        return -30  // GIT_PASSTHROUGH
    }
    return buildCredentialPayload(into: outPtr, from: creds)
}

// MARK: Trampolines

private let combinedCredentialsTrampoline: git_credential_acquire_cb = {
    outPtr, urlCStr, userCStr, allowedTypes, payload in
    guard let payload, let outPtr else { return -1 }
    let box = Unmanaged<CallbackBox>.fromOpaque(payload).takeUnretainedValue()
    guard let provider = box.credentialsProvider else { return -30 }

    let url: URL = {
        if let urlCStr, let parsed = URL(string: String(cString: urlCStr)) {
            return parsed
        }
        return URL(string: "about:blank")!
    }()
    let usernameFromURL: String? = userCStr.map { String(cString: $0) }
    let allowed = CredentialKind(rawValue: allowedTypes)

    guard let creds = provider(url, usernameFromURL, allowed) else {
        return -30  // GIT_PASSTHROUGH
    }
    return buildCredentialPayload(into: outPtr, from: creds)
}

private let combinedSidebandTrampoline: git_transport_message_cb = {
    strPtr, len, payload in
    guard let payload, let strPtr else { return 0 }
    let box = Unmanaged<CallbackBox>.fromOpaque(payload).takeUnretainedValue()
    guard box.reporter != nil,
          !(box.reporter!.suppressTransferProgress) else { return 0 }
    var copy = [UInt8](repeating: 0, count: Int(len))
    copy.withUnsafeMutableBufferPointer { buf in
        // Linux/Glibc imports memcpy with non-optional pointers, so
        // `buf.baseAddress` (Optional) and `strPtr` (Optional) need
        // explicit unwrapping. Apple's libc imports them as Optional.
        if let dest = buf.baseAddress {
            _ = memcpy(dest, strPtr, Int(len))
        }
    }
    let chunk = String(decoding: copy, as: UTF8.self)

    // libgit2 may split the server's output across multiple callback
    // invocations; we have to track whether we're mid-line so we
    // don't re-prefix `remote: ` on every continuation chunk. Within
    // one chunk, `\r` and `\n` close the current line.
    var current = ""
    for ch in chunk {
        if ch == "\r" || ch == "\n" {
            // Flush whatever we accumulated, prefixing only if this is
            // a fresh line (i.e. the prior chunk ended at a terminator).
            if !box.reporter!.sidebandLineOpen {
                box.reporter!.write("remote: \(current)\(ch)")
            } else {
                box.reporter!.write("\(current)\(ch)")
            }
            current = ""
            box.reporter!.sidebandLineOpen = false
        } else {
            current.append(ch)
        }
    }
    if !current.isEmpty {
        if !box.reporter!.sidebandLineOpen {
            box.reporter!.write("remote: \(current)")
        } else {
            box.reporter!.write(current)
        }
        box.reporter!.sidebandLineOpen = true
    }
    return 0
}

private let combinedTransferTrampoline: git_indexer_progress_cb = {
    statsPtr, payload in
    guard let payload, let stats = statsPtr?.pointee else { return 0 }
    let box = Unmanaged<CallbackBox>.fromOpaque(payload).takeUnretainedValue()
    guard box.reporter != nil,
          !(box.reporter!.suppressTransferProgress) else { return 0 }

    let total = Int(stats.total_objects)
    let received = Int(stats.received_objects)

    if total > 0 && received <= total {
        let pct = (received * 100) / max(total, 1)
        if pct != box.reporter!.lastTransferPct || received == total {
            box.reporter!.lastTransferPct = pct
            let line = "Receiving objects: \(pct)% (\(received)/\(total))"
            if received == total {
                box.reporter!.write(line + ", done.\n")
            } else {
                box.reporter!.write(line + "\r")
            }
        }
    }

    let totalDeltas = Int(stats.total_deltas)
    let indexedDeltas = Int(stats.indexed_deltas)
    if totalDeltas > 0 && received >= total {
        let pct = (indexedDeltas * 100) / max(totalDeltas, 1)
        if pct != box.reporter!.lastDeltaPct || indexedDeltas == totalDeltas {
            box.reporter!.lastDeltaPct = pct
            let line = "Resolving deltas: \(pct)% (\(indexedDeltas)/\(totalDeltas))"
            if indexedDeltas == totalDeltas {
                box.reporter!.write(line + ", done.\n")
            } else {
                box.reporter!.write(line + "\r")
            }
        }
    }
    return 0
}

private let combinedUpdateRefsTrampoline: @convention(c) (
    UnsafePointer<CChar>?,
    UnsafePointer<git_oid>?,
    UnsafePointer<git_oid>?,
    OpaquePointer?,
    UnsafeMutableRawPointer?
) -> Int32 = { refnamePtr, aOid, bOid, _, payload in
    guard let payload, let refnamePtr else { return 0 }
    let box = Unmanaged<CallbackBox>.fromOpaque(payload).takeUnretainedValue()
    guard box.reporter != nil else { return 0 }
    let refname = String(cString: refnamePtr)

    let isNew = aOid.map { isAllZero($0.pointee) } ?? true
    let dst = stripRemotesPrefix(refname)
    let local = sourceShorthand(refname)

    let line: String
    if isNew {
        line = " * [new branch]      \(pad(local, to: 11))-> \(dst)"
    } else if let aOid, let bOid {
        let oldSha = shortSHA(aOid.pointee)
        let newSha = shortSHA(bOid.pointee)
        line = "   \(oldSha)..\(newSha)  \(pad(local, to: 11))-> \(dst)"
    } else {
        line = "   \(local) -> \(dst)"
    }
    box.reporter!.refLines.append(line)
    return 0
}

/// `pack_progress`: server-side pack-builder phases for push.
/// Stage 0 = `Counting objects`, stage 1 = `Compressing objects`.
/// Real git emits `\r`-overwrite progress per stage and a `, done.\n`
/// terminator on stage completion (current == total).
private let combinedPackProgressTrampoline: git_packbuilder_progress = {
    stage, current, total, payload in
    guard let payload else { return 0 }
    let box = Unmanaged<CallbackBox>.fromOpaque(payload).takeUnretainedValue()
    guard box.reporter != nil,
          !(box.reporter!.suppressTransferProgress) else { return 0 }

    let totalI = Int(total)
    let currentI = Int(current)
    if totalI == 0 { return 0 }

    let pct = (currentI * 100) / totalI
    // Stage transition resets the throttle so we always emit the first
    // line of each stage.
    if stage != box.reporter!.lastPackStage {
        box.reporter!.lastPackStage = stage
        box.reporter!.lastPackPct = -1
    }
    if pct == box.reporter!.lastPackPct && currentI != totalI { return 0 }
    box.reporter!.lastPackPct = pct

    let label: String
    switch stage {
    case Int32(GIT_PACKBUILDER_ADDING_OBJECTS.rawValue):
        label = "Counting objects"
    case Int32(GIT_PACKBUILDER_DELTAFICATION.rawValue):
        label = "Compressing objects"
    default:
        label = "Stage \(stage)"
    }

    let line = "\(label): \(pct)% (\(currentI)/\(totalI))"
    if currentI == totalI {
        box.reporter!.write(line + ", done.\n")
    } else {
        box.reporter!.write(line + "\r")
    }
    return 0
}

/// `push_transfer_progress`: client uploading the pack. Real git
/// formats `Writing objects: <pct>% (<sent>/<total>), <bytes>` with
/// `\r` overwrites and `, done.\n` on completion.
private let combinedPushTransferTrampoline: git_push_transfer_progress_cb = {
    current, total, bytes, payload in
    guard let payload else { return 0 }
    let box = Unmanaged<CallbackBox>.fromOpaque(payload).takeUnretainedValue()
    guard box.reporter != nil,
          !(box.reporter!.suppressTransferProgress) else { return 0 }

    let totalI = Int(total)
    let currentI = Int(current)
    if totalI == 0 { return 0 }
    let pct = (currentI * 100) / totalI

    if pct == box.reporter!.lastPushTransferPct && currentI != totalI { return 0 }
    box.reporter!.lastPushTransferPct = pct

    let bytesStr = humanBytes(Int(bytes))
    let line = "Writing objects: \(pct)% (\(currentI)/\(totalI)), \(bytesStr)"
    if currentI == totalI {
        box.reporter!.write(line + ", done.\n")
    } else {
        box.reporter!.write(line + "\r")
    }
    return 0
}

private let combinedPushNegotiationTrampoline: git_push_negotiation = {
    updates, len, payload in
    guard let payload else { return 0 }
    let box = Unmanaged<CallbackBox>.fromOpaque(payload).takeUnretainedValue()
    guard let pushLease = box.pushLease else { return 0 }
    return pushLease.verify(updates: updates, count: Int(len))
}

private func humanBytes(_ bytes: Int) -> String {
    let kib = 1024.0
    let mib = kib * 1024.0
    let gib = mib * 1024.0
    let b = Double(bytes)
    if b >= gib { return String(format: "%.2f GiB", b / gib) }
    if b >= mib { return String(format: "%.2f MiB", b / mib) }
    if b >= kib { return String(format: "%.2f KiB", b / kib) }
    return "\(bytes) bytes"
}

private let combinedPushRefTrampoline: git_push_update_reference_cb = {
    refnamePtr, statusPtr, payload in
    guard let payload, let refnamePtr else { return 0 }
    let box = Unmanaged<CallbackBox>.fromOpaque(payload).takeUnretainedValue()
    guard box.reporter != nil else { return 0 }
    let refname = String(cString: refnamePtr)
    let status = statusPtr.map { String(cString: $0) } ?? ""
    let short = stripHeadsPrefix(refname)

    let line: String
    if status.isEmpty {
        // Real git's push summary doesn't pad the ref column when
        // there's only one ref — keep it tight to match.
        line = " * [new branch]      \(short) -> \(short)"
    } else {
        line = " ! [rejected]        \(short) -> \(short) (\(status))"
    }
    box.reporter!.refLines.append(line)
    return status.isEmpty ? 0 : -1
}

// MARK: Credential builder (extracted from CredentialsBridge so the
//       combined trampoline can share it)

private func buildCredentialPayload(
    into out: UnsafeMutablePointer<UnsafeMutablePointer<git_credential>?>,
    from creds: Credentials
) -> Int32 {
    switch creds {
    case .userPassword(let username, let password):
        return username.withCString { u in
            password.withCString { p in
                git_credential_userpass_plaintext_new(out, u, p)
            }
        }
    case .token(let token, let username):
        return username.withCString { u in
            token.withCString { p in
                git_credential_userpass_plaintext_new(out, u, p)
            }
        }
    case .sshKey(let username, let publicKey, let privateKey, let passphrase):
        let pubPath = publicKey?.path
        return username.withCString { u in
            optionalCString(pubPath) { pub in
                privateKey.path.withCString { priv in
                    optionalCString(passphrase) { pass in
                        git_credential_ssh_key_new(out, u, pub, priv, pass)
                    }
                }
            }
        }
    case .sshAgent(let username):
        return username.withCString { u in
            git_credential_ssh_key_from_agent(out, u)
        }
    case .username(let username):
        return username.withCString { u in
            git_credential_username_new(out, u)
        }
    case .default:
        return git_credential_default_new(out)
    }
}

private func optionalCString<T>(
    _ s: String?, _ body: (UnsafePointer<CChar>?) -> T
) -> T {
    if let s { return s.withCString { body($0) } }
    return body(nil)
}

// MARK: OID + ref helpers

private func isAllZero(_ oid: git_oid) -> Bool {
    var oid = oid
    return withUnsafeBytes(of: &oid) { bytes in
        bytes.allSatisfy { $0 == 0 }
    }
}

private func shortSHA(_ oid: git_oid) -> String {
    var oid = oid
    let buf = UnsafeMutablePointer<CChar>.allocate(capacity: 41)
    defer { buf.deallocate() }
    buf.initialize(repeating: 0, count: 41)
    _ = git_oid_tostr(buf, 41, &oid)
    return String(String(cString: buf).prefix(7))
}

private func stripRemotesPrefix(_ refname: String) -> String {
    let prefix = "refs/remotes/"
    return refname.hasPrefix(prefix)
        ? String(refname.dropFirst(prefix.count))
        : refname
}

private func sourceShorthand(_ refname: String) -> String {
    let prefix = "refs/remotes/"
    guard refname.hasPrefix(prefix) else { return refname }
    let trimmed = refname.dropFirst(prefix.count)
    if let slash = trimmed.firstIndex(of: "/") {
        return String(trimmed[trimmed.index(after: slash)...])
    }
    return String(trimmed)
}

private func stripHeadsPrefix(_ refname: String) -> String {
    let prefix = "refs/heads/"
    return refname.hasPrefix(prefix)
        ? String(refname.dropFirst(prefix.count))
        : refname
}

private func pad(_ s: String, to width: Int) -> String {
    if s.count >= width { return s + " " }
    return s + String(repeating: " ", count: width - s.count)
}

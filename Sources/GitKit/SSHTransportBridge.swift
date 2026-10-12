import Foundation
import CGitKit

/// Heap-allocated box holding the registered Swift provider. We pass a
/// raw pointer to this box as the `git_smart_subtransport_definition`'s
/// `param`, retained for as long as the provider stays registered.
final class SSHProviderBox {
    let provider: any GitSSHTransportProvider
    init(_ provider: any GitSSHTransportProvider) { self.provider = provider }
}

/// Per-connection state for one `git_smart_subtransport` instance.
///
/// `git_smart_subtransport` has no user-data slot of its own (unlike
/// `git_smart_subtransport_stream`, which at least points back to its
/// owning subtransport), so we key this context by the subtransport's
/// own address in ``SSHSubtransportRegistry`` instead of storing it
/// inline — mirroring how libgit2's own `ssh_exec` subtransport keeps
/// its process and current stream in a C struct that extends
/// `git_smart_subtransport`.
///
/// One channel (and one libgit2 stream wrapping it) lives at a time,
/// spanning the "ls" probe and the actual upload-pack/receive-pack
/// action that follows it over the same connection — libgit2 guarantees
/// a `close()` between any other pair of `action()` calls.
final class SSHSubtransportContext {
    let provider: any GitSSHTransportProvider
    var channel: GitSSHChannel?
    var currentStream: UnsafeMutablePointer<git_smart_subtransport_stream>?
    var action: git_smart_service_t?

    init(provider: any GitSSHTransportProvider) {
        self.provider = provider
    }
}

/// Maps a live `git_smart_subtransport*` to its Swift-side context.
/// libgit2 calls into one subtransport from a single thread at a time,
/// but distinct subtransports (concurrent operations on different
/// repositories) can be live on different threads simultaneously, so
/// access to the map itself is locked.
final class SSHSubtransportRegistry: @unchecked Sendable {
    static let shared = SSHSubtransportRegistry()

    private let lock = NSLock()
    private var contexts: [UnsafeRawPointer: SSHSubtransportContext] = [:]

    func register(_ pointer: UnsafeRawPointer, context: SSHSubtransportContext) {
        lock.lock(); defer { lock.unlock() }
        contexts[pointer] = context
    }

    func context(for pointer: UnsafeRawPointer) -> SSHSubtransportContext? {
        lock.lock(); defer { lock.unlock() }
        return contexts[pointer]
    }

    func remove(_ pointer: UnsafeRawPointer) {
        lock.lock(); defer { lock.unlock() }
        contexts.removeValue(forKey: pointer)
    }
}

/// `host`/`port`/`user`/`path` parsed out of an `ssh://` (or
/// `ssh+git://` / `git+ssh://`) URL or a scp-style `user@host:path`
/// remote — whichever libgit2 hands the subtransport's `action()`.
struct ParsedGitSSHURL {
    let user: String?
    let host: String
    let port: Int?
    let path: String
}

enum GitSSHURL {
    private static let schemes = ["ssh", "ssh+git", "git+ssh"]

    static func parse(_ raw: String) -> ParsedGitSSHURL? {
        parseHierarchical(raw) ?? parseSCP(raw)
    }

    /// `ssh://[user@]host[:port]/path`, `ssh+git://…`, `git+ssh://…`.
    private static func parseHierarchical(_ raw: String) -> ParsedGitSSHURL? {
        guard let schemeEnd = raw.range(of: "://") else { return nil }
        let scheme = raw[..<schemeEnd.lowerBound].lowercased()
        guard schemes.contains(scheme) else { return nil }
        guard let components = URLComponents(string: raw),
              let host = components.host, !host.isEmpty
        else { return nil }
        return ParsedGitSSHURL(
            user: components.user, host: host, port: components.port,
            path: components.path)
    }

    /// `[user@]host:path` — git's scp-style shorthand. Unlike the
    /// hierarchical form, a port can't be expressed here (matching real
    /// `ssh`/`git`: scp-style syntax never carries one).
    private static func parseSCP(_ raw: String) -> ParsedGitSSHURL? {
        guard !raw.contains("://"), let colon = raw.firstIndex(of: ":") else { return nil }
        let hostPart = raw[..<colon]
        let path = String(raw[raw.index(after: colon)...])
        guard !hostPart.isEmpty, !path.isEmpty else { return nil }

        if let at = hostPart.firstIndex(of: "@") {
            let user = String(hostPart[..<at])
            let host = String(hostPart[hostPart.index(after: at)...])
            guard !user.isEmpty, !host.isEmpty else { return nil }
            return ParsedGitSSHURL(user: user, host: host, port: nil, path: path)
        }
        return ParsedGitSSHURL(user: nil, host: String(hostPart), port: nil, path: path)
    }
}

private func setSSHTransportError(_ message: String) {
    _ = message.withCString { git_error_set_str(Int32(GIT_ERROR_NET.rawValue), $0) }
}

private func describe(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? String(describing: error)
}

// MARK: Subtransport factory

/// `git_smart_subtransport_cb`: libgit2 calls this (via
/// `git_transport_smart`, which we pass as the `git_transport_cb` to
/// `git_transport_register`) once per remote connection attempt.
let gitkitSSHSubtransportCreate: git_smart_subtransport_cb = { outPtr, _, param in
    guard let outPtr, let param else { return -1 }
    let providerBox = Unmanaged<SSHProviderBox>.fromOpaque(param).takeUnretainedValue()

    let subtransport = UnsafeMutablePointer<git_smart_subtransport>.allocate(capacity: 1)
    subtransport.pointee = git_smart_subtransport()
    subtransport.pointee.action = gitkitSSHSubtransportAction
    subtransport.pointee.close = gitkitSSHSubtransportClose
    subtransport.pointee.free = gitkitSSHSubtransportFree

    let context = SSHSubtransportContext(provider: providerBox.provider)
    SSHSubtransportRegistry.shared.register(UnsafeRawPointer(subtransport), context: context)

    outPtr.pointee = subtransport
    return 0
}

// MARK: Subtransport callbacks

private let gitkitSSHSubtransportAction: @convention(c) (
    UnsafeMutablePointer<UnsafeMutablePointer<git_smart_subtransport_stream>?>?,
    UnsafeMutablePointer<git_smart_subtransport>?,
    UnsafePointer<CChar>?,
    git_smart_service_t
) -> Int32 = { outPtr, transportPtr, urlCStr, action in
    guard let outPtr, let transportPtr, let urlCStr else { return -1 }
    guard let context = SSHSubtransportRegistry.shared.context(for: UnsafeRawPointer(transportPtr)) else {
        setSSHTransportError("ssh subtransport has no registered context")
        return -1
    }

    let isLS = action.rawValue == GIT_SERVICE_UPLOADPACK_LS.rawValue
        || action.rawValue == GIT_SERVICE_RECEIVEPACK_LS.rawValue

    if isLS {
        guard let parsed = GitSSHURL.parse(String(cString: urlCStr)) else {
            setSSHTransportError("unparsable ssh remote URL")
            return -1
        }
        let command: GitSSHCommand = action.rawValue == GIT_SERVICE_UPLOADPACK_LS.rawValue
            ? .uploadPack(path: parsed.path)
            : .receivePack(path: parsed.path)

        do {
            context.channel = try context.provider.openChannel(
                host: parsed.host, port: parsed.port, user: parsed.user, command: command)
        } catch {
            setSSHTransportError(describe(error))
            return -1
        }

        let stream = UnsafeMutablePointer<git_smart_subtransport_stream>.allocate(capacity: 1)
        stream.pointee = git_smart_subtransport_stream()
        stream.pointee.subtransport = transportPtr
        stream.pointee.read = gitkitSSHStreamRead
        stream.pointee.write = gitkitSSHStreamWrite
        stream.pointee.free = gitkitSSHStreamFree
        context.currentStream = stream
    } else {
        let expectedLS: git_smart_service_t = action.rawValue == GIT_SERVICE_UPLOADPACK.rawValue
            ? GIT_SERVICE_UPLOADPACK_LS : GIT_SERVICE_RECEIVEPACK_LS
        guard context.currentStream != nil,
              context.action?.rawValue == expectedLS.rawValue
                  || context.action?.rawValue == action.rawValue
        else {
            setSSHTransportError("invalid ssh transport state")
            return -1
        }
    }

    context.action = action
    outPtr.pointee = context.currentStream
    return 0
}

private let gitkitSSHSubtransportClose: @convention(c) (
    UnsafeMutablePointer<git_smart_subtransport>?
) -> Int32 = { transportPtr in
    guard let transportPtr else { return 0 }
    if let context = SSHSubtransportRegistry.shared.context(for: UnsafeRawPointer(transportPtr)) {
        context.channel?.close()
        context.channel = nil
        context.action = nil
    }
    return 0
}

private let gitkitSSHSubtransportFree: @convention(c) (
    UnsafeMutablePointer<git_smart_subtransport>?
) -> Void = { transportPtr in
    guard let transportPtr else { return }
    SSHSubtransportRegistry.shared.remove(UnsafeRawPointer(transportPtr))
    transportPtr.deallocate()
}

// MARK: Stream callbacks

private func context(
    forStream streamPtr: UnsafeMutablePointer<git_smart_subtransport_stream>
) -> SSHSubtransportContext? {
    guard let subtransportPtr = streamPtr.pointee.subtransport else { return nil }
    return SSHSubtransportRegistry.shared.context(for: UnsafeRawPointer(subtransportPtr))
}

private let gitkitSSHStreamRead: @convention(c) (
    UnsafeMutablePointer<git_smart_subtransport_stream>?,
    UnsafeMutablePointer<CChar>?,
    Int,
    UnsafeMutablePointer<Int>?
) -> Int32 = { streamPtr, buffer, bufSize, bytesReadPtr in
    guard let streamPtr, let buffer, let bytesReadPtr,
          let context = context(forStream: streamPtr),
          let channel = context.channel
    else {
        setSSHTransportError("ssh stream is not open")
        return -1
    }
    do {
        let raw = UnsafeMutableRawBufferPointer(start: buffer, count: bufSize)
        bytesReadPtr.pointee = try channel.read(into: raw)
        return 0
    } catch {
        setSSHTransportError(describe(error))
        return -1
    }
}

private let gitkitSSHStreamWrite: @convention(c) (
    UnsafeMutablePointer<git_smart_subtransport_stream>?,
    UnsafePointer<CChar>?,
    Int
) -> Int32 = { streamPtr, buffer, len in
    guard let streamPtr, let buffer,
          let context = context(forStream: streamPtr),
          let channel = context.channel
    else {
        setSSHTransportError("ssh stream is not open")
        return -1
    }
    do {
        let raw = UnsafeRawBufferPointer(start: buffer, count: len)
        try channel.write(raw)
        return 0
    } catch {
        setSSHTransportError(describe(error))
        return -1
    }
}

private let gitkitSSHStreamFree: @convention(c) (
    UnsafeMutablePointer<git_smart_subtransport_stream>?
) -> Void = { streamPtr in
    guard let streamPtr else { return }
    if let context = context(forStream: streamPtr), context.currentStream == streamPtr {
        context.currentStream = nil
    }
    streamPtr.deallocate()
}

import Foundation
import CGitKit

/// The remote git command one SSH operation runs, together with the
/// repository path to run it against — mirrors the three commands real
/// `ssh` invokes: `git-upload-pack`, `git-receive-pack`,
/// `git-upload-archive`.
public enum GitSSHCommand: Sendable, Hashable {
    /// `git-upload-pack '<path>'` — serves objects for fetch/clone.
    case uploadPack(path: String)
    /// `git-receive-pack '<path>'` — accepts objects for push.
    case receivePack(path: String)
    /// `git-upload-archive '<path>'` — serves `git archive --remote`.
    /// libgit2's smart protocol never issues this itself; it exists so a
    /// provider built on the same channel can serve archive requests too.
    case uploadArchive(path: String)
}

/// A bidirectional byte stream one SSH operation runs over. A
/// ``GitSSHTransportProvider`` opens one of these per ``GitSSHCommand``;
/// libgit2's smart protocol then reads and writes it directly.
///
/// ## Threading contract
///
/// libgit2 calls `read`/`write`/`close` **synchronously, on whatever
/// thread is driving the git operation** (the thread that called
/// `fetch`/`clone`/`push`) — there is no dedicated I/O thread for a
/// custom transport. Each call must block until it can make progress
/// (or fail); returning early with no data to be retried later is not
/// part of this contract.
///
/// An async provider (e.g. one built on SwiftNIO) must bridge this by
/// blocking the calling thread until its async operation completes —
/// a semaphore or a blocking wait on a future — rather than handing
/// work to its event loop and returning immediately. In particular,
/// never `await` a Swift Concurrency task from inside these methods:
/// that hops off the calling thread, which libgit2 does not expect.
public protocol GitSSHChannel: AnyObject {
    /// Reads at least one byte into `buffer`, blocking until data is
    /// available. Returns the number of bytes read, or `0` at EOF.
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int

    /// Writes the entirety of `buffer`, blocking until every byte has
    /// been accepted or an error occurs.
    func write(_ buffer: UnsafeRawBufferPointer) throws

    /// Closes the channel. Called at most once per channel, always
    /// after the last `read`/`write`.
    func close()
}

/// Opens the byte stream that carries one git-over-ssh operation.
/// Authentication is entirely the provider's business — libgit2 never
/// sees credentials for a registered SSH transport.
///
/// See ``GitSSHChannel`` for the threading contract its channels must
/// honor.
public protocol GitSSHTransportProvider: Sendable {
    /// Opens a channel to `host` and starts `command` on it (as `ssh`
    /// would run it on the remote: `<command> '<path>'`).
    ///
    /// - parameter host: The remote host, parsed from the URL.
    /// - parameter port: The port, if the URL specified one.
    /// - parameter user: The remote username, if the URL specified one.
    /// - parameter command: The git command to run, with its path.
    func openChannel(
        host: String,
        port: Int?,
        user: String?,
        command: GitSSHCommand
    ) throws -> GitSSHChannel
}

/// Registers a custom SSH transport that carries GitKit's `ssh://`,
/// `ssh+git://`, `git+ssh://` and scp-style (`user@host:path`) fetches
/// and pushes over a provider-supplied ``GitSSHChannel``, instead of
/// libgit2's built-in `ssh_exec` transport (which spawns `/usr/bin/ssh`
/// for every operation and can't run on iOS).
///
/// With no provider registered, behaviour is unchanged: libgit2 uses
/// `ssh_exec` exactly as it always has. ``unregister()`` restores that
/// default.
public enum GitSSHTransport {
    private static let lock = NSLock()
    /// Guarded exclusively by `lock` — never touched outside it.
    nonisolated(unsafe) private static var state: RegisteredState?

    private struct RegisteredState {
        let prefixes: [String]
        let providerBox: Unmanaged<SSHProviderBox>
        let definition: UnsafeMutablePointer<git_smart_subtransport_definition>
    }

    /// The URL schemes a registered provider carries. libgit2 maps
    /// scp-style `user@host:path` remotes onto `ssh://` internally when
    /// no built-in transport claims them, so registering `"ssh"` covers
    /// both forms.
    private static let schemes = ["ssh", "ssh+git", "git+ssh"]

    /// Registers `provider` as the transport for `ssh://`, `ssh+git://`,
    /// `git+ssh://` and scp-style remotes. Only one provider may be
    /// registered at a time; call ``unregister()`` first to replace one.
    public static func register(_ provider: any GitSSHTransportProvider) throws {
        Libgit2.ensureInitialized()
        lock.lock()
        defer { lock.unlock() }

        guard state == nil else {
            throw Libgit2Error(
                code: GIT_EEXISTS.rawValue, klass: 0,
                message: "an SSH transport provider is already registered")
        }

        let box = SSHProviderBox(provider)
        let raw = Unmanaged.passRetained(box)
        let definition = UnsafeMutablePointer<git_smart_subtransport_definition>.allocate(capacity: 1)
        definition.pointee = git_smart_subtransport_definition(
            callback: gitkitSSHSubtransportCreate,
            rpc: 0,
            param: raw.toOpaque())

        var registered: [String] = []
        for scheme in schemes {
            let rc = scheme.withCString {
                git_transport_register($0, git_transport_smart, definition)
            }
            if rc < 0 {
                for done in registered {
                    _ = done.withCString { git_transport_unregister($0) }
                }
                definition.deallocate()
                raw.release()
                throw Libgit2Error.last(code: rc)
            }
            registered.append(scheme)
        }

        state = RegisteredState(prefixes: registered, providerBox: raw, definition: definition)
    }

    /// Unregisters the current provider, if any, restoring libgit2's
    /// default `ssh_exec` behaviour for `ssh://` and friends. A no-op if
    /// no provider is registered.
    public static func unregister() {
        lock.lock()
        defer { lock.unlock() }
        guard let state else { return }
        for prefix in state.prefixes {
            _ = prefix.withCString { git_transport_unregister($0) }
        }
        state.definition.deallocate()
        state.providerBox.release()
        self.state = nil
    }
}

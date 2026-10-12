// Shared serialization for every test that touches libgit2's `ssh://`
// transport dispatch: both `RepositorySSHExecTests` and
// `GitSSHTransportTests` mutate process-wide state — `core.sshCommand`
// interacting with the single `ssh://` scheme libgit2 dispatches on, and
// `GitSSHTransport.register`/`unregister`'s custom-transport registration.
//
// Swift Testing's `.serialized` suite trait only serializes tests
// *within* that suite; these two suites live in separate files and can
// still be scheduled concurrently by the test runner, which would let a
// registered fake provider intercept the other suite's `ssh_exec` fetch
// (or vice versa). Every test that needs exclusive access to this global
// state must run its body inside `SSHTransportTestLock.shared.withLock`.
#if os(macOS) || os(Linux)
import Foundation

final class SSHTransportTestLock: @unchecked Sendable {
    static let shared = SSHTransportTestLock()

    private let lock = NSLock()
    private init() {}

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
#endif

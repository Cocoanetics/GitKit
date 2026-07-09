import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#elseif canImport(Bionic)
import Bionic
#endif
import CGitKit

/// Process-wide libgit2 init / shutdown bookkeeping.
///
/// `git_libgit2_init()` is reference-counted by libgit2 itself; we just
/// have to make sure it's been called once before any other git_* call.
/// On POSIX hosts, we also ignore `SIGPIPE` once so libgit2's socket
/// transport reports `EPIPE` instead of terminating the process.
/// We intentionally never call `git_libgit2_shutdown()` - the library is
/// meant to live for the duration of the process, and shutting down
/// while another thread is mid-operation is unsafe.
public enum Libgit2 {
    private static let sigpipeIgnored: Bool = {
#if canImport(Darwin) || canImport(Glibc) || canImport(Musl) || canImport(Android) || canImport(Bionic)
        _ = signal(SIGPIPE, SIG_IGN)
#endif
        return true
    }()

    private static let initialized: Bool = {
        ignoreSIGPIPE()
        let rc = git_libgit2_init()
        precondition(rc >= 0, "git_libgit2_init failed with \(rc)")
        return true
    }()

    static func ignoreSIGPIPE() {
        _ = sigpipeIgnored
    }

    /// Public so hosts that poke libgit2's process-global state *before*
    /// any `Repository` call (e.g. option bridges setting search paths)
    /// can guarantee the library is initialized first.
    public static func ensureInitialized() {
        _ = initialized
    }
}

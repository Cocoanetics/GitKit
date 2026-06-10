import Foundation
import CGitKit

/// Wraps a non-zero return code from a `git_*` C call.
///
/// libgit2 stores the actual error message in thread-local state via
/// `git_error_last()`; we snapshot it at throw time so the `Error` is
/// safe to hand off across threads.
public struct Libgit2Error: Error, LocalizedError, Sendable {
    /// The failing `git_*` return code (negative, e.g.
    /// `GIT_ENOTFOUND`) exactly as the C call returned it.
    public let code: Int32
    /// libgit2 error class (`git_error_t`, e.g. `GIT_ERROR_REFERENCE`)
    /// naming the subsystem that failed; `0` when unknown.
    public let klass: Int32
    /// Message snapshotted from `git_error_last()` at throw time.
    public let message: String

    /// Memberwise init — also used by SDK code to raise git-shaped
    /// errors that don't originate in a C call (pass `klass: 0`).
    public init(code: Int32, klass: Int32, message: String) {
        self.code = code
        self.klass = klass
        self.message = message
    }

    /// `LocalizedError` text: `libgit2 error (<code>/<klass>): <message>`.
    public var errorDescription: String? {
        "libgit2 error (\(code)/\(klass)): \(message)"
    }

    static func last(code: Int32) -> Libgit2Error {
        if let raw = git_error_last(), let msg = raw.pointee.message {
            return Libgit2Error(
                code: code,
                klass: raw.pointee.klass,
                message: String(cString: msg))
        }
        return Libgit2Error(code: code, klass: 0, message: "unknown error")
    }
}

/// Throws ``Libgit2Error`` if `rc < 0`. Returns `rc` otherwise so the
/// caller can use it (some libgit2 APIs return the count on success).
///
/// Public because ``Repository/pointer`` is a deliberate escape hatch:
/// embedders calling raw `git_*` API through it want the same rc-to-error
/// translation the SDK uses.
@discardableResult
public func check(_ rc: Int32) throws -> Int32 {
    if rc < 0 { throw Libgit2Error.last(code: rc) }
    return rc
}

import Foundation

/// A push that left some refs as they were. Each refused ref's summary
/// line (` ! [rejected]        main -> main (fetch first)`) has been
/// printed; the error carries git's verdict, `failed to push some refs
/// to '<url>'`, and what git needs to pick its advice.
public struct PushRejectedError: Error, LocalizedError, Sendable, Equatable {
    /// Why a ref was left alone, as git words it in the summary.
    public enum Reason: Sendable, Equatable {
        /// The remote has commits this repository doesn't (`fetch first`).
        case fetchFirst
        /// The update would drop commits the remote has
        /// (`non-fast-forward`).
        case nonFastForward
        /// The tag already exists on the remote (`already exists`).
        case alreadyExists
        /// The old or the new value isn't a commit (`needs force`).
        case needsForce
        /// The remote refused the update, for this reason.
        case remoteRejected(String)

        /// The parenthesised reason in the summary line.
        var summary: String {
            switch self {
            case .fetchFirst: "fetch first"
            case .nonFastForward: "non-fast-forward"
            case .alreadyExists: "already exists"
            case .needsForce: "needs force"
            case .remoteRejected(let message): message
            }
        }
    }

    /// One ref the push left alone.
    public struct Rejection: Sendable, Equatable {
        /// The remote ref, e.g. `refs/heads/main`.
        public let remoteRef: String
        public let reason: Reason
    }

    /// The remote's URL or path, as git names it in the verdict.
    public let url: String
    public let rejections: [Rejection]
    /// The refspecs that did go through (or were up to date), one per
    /// ref and fully qualified, as a successful push returns them.
    public let pushed: [String]
    /// The push's summary as printed: `To <url>` and a line per ref.
    /// git prints it on failure even with `--quiet`, so a caller that
    /// silenced the progress output can still show it.
    public let summary: String

    public var errorDescription: String? {
        "failed to push some refs to '\(url)'"
    }
}

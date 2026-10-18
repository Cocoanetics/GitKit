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
        /// The remote didn't report on the update (`remote failed to
        /// report status`), as when two updates target one new ref.
        case remoteFailure

        /// The parenthesised reason in the summary line.
        var summary: String {
            switch self {
            case .fetchFirst: "fetch first"
            case .nonFastForward: "non-fast-forward"
            case .alreadyExists: "already exists"
            case .needsForce: "needs force"
            case .remoteRejected(let message): message
            case .remoteFailure: "remote failed to report status"
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

/// A push git refused before sending anything: a source that matches no
/// ref (or more than one), two refspecs to one ref, a deletion of a ref
/// the remote doesn't have, a destination git can't complete. Nothing
/// was pushed. git prints an `error:` for each refusal, in order, some
/// with a hint, then its verdict.
public struct PushRefusedError: Error, LocalizedError, Sendable, Equatable {
    /// One refspec git refused.
    public struct Refusal: Sendable, Equatable {
        /// git's message, which can run over several lines.
        public let message: String
        /// git's hint for it, line by line; empty when it has none.
        public let hint: [String]
        /// The `advice.*` key that turns the hint off.
        public let adviceKey: String?

        init(_ message: String, hint: [String] = [], adviceKey: String? = nil) {
            self.message = message
            self.hint = hint
            self.adviceKey = adviceKey
        }
    }

    /// The remote's (push) URL or path, as git names it in the verdict.
    public let url: String
    public let refusals: [Refusal]

    public var errorDescription: String? {
        (refusals.map(\.message) + ["failed to push some refs to '\(url)'"])
            .joined(separator: "\n")
    }
}

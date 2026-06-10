import Foundation

/// Author / committer identity for commit-creating operations.
///
/// The core SDK's own value type — deliberately independent of any host
/// framework so the module stays a pure libgit2 wrapper. Hosts that have
/// their own signature type (e.g. ForgeKit's `GitSignature`) map at the
/// boundary; the two fields are all there is.
public struct Signature: Sendable, Equatable {
    /// Display-name half of the `Name <email>` commit header — what
    /// real git takes from `user.name`.
    public let name: String
    /// Address half of the `Name <email>` commit header — what real
    /// git takes from `user.email`.
    public let email: String

    /// Create an identity. Stored verbatim — trimming/validation
    /// happens at the C boundary when libgit2 builds the
    /// `git_signature`.
    public init(name: String, email: String) {
        self.name = name
        self.email = email
    }
}

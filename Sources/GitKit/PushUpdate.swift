/// One ref update a push is about to send, as git hands it to its
/// pre-push hook (`<local ref> <local oid> <remote ref> <remote oid>`):
/// what the update sends, and where the remote ref is now, as the remote
/// advertised it on the push's connection.
public struct PushUpdate: Sendable, Equatable {
    /// The object ID git writes for an object that isn't there: forty
    /// zeros, for a deletion's local side and a remote ref that doesn't
    /// exist yet.
    public static let nullOID = String(repeating: "0", count: 40)

    /// The source as the refspec gives it (`refs/heads/main`, or a
    /// revision such as `HEAD~1`), or `(delete)` for a deletion.
    public let localRef: String
    /// The object the remote ref is set to; ``nullOID`` for a deletion.
    public let localOID: String
    /// The remote ref updated (`refs/heads/main`).
    public let remoteRef: String
    /// The object the remote ref points at now; ``nullOID`` when the
    /// remote doesn't have it.
    public let remoteOID: String

    public init(localRef: String, localOID: String, remoteRef: String, remoteOID: String) {
        self.localRef = localRef
        self.localOID = localOID
        self.remoteRef = remoteRef
        self.remoteOID = remoteOID
    }
}

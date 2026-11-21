import CGitKit

extension Repository {

    /// Hands `beforeSending` the updates `accepted` sends, if there is a
    /// callback; if it throws, disconnects `remote` and rethrows, so
    /// nothing is sent.
    func announce(
        _ accepted: [String], remoteRefs: RemoteRefs,
        to beforeSending: (([PushUpdate]) throws -> Void)?, remote: OpaquePointer?
    ) throws {
        guard let beforeSending else { return }
        do {
            try beforeSending(try pushUpdates(for: accepted, remoteRefs: remoteRefs))
        } catch {
            git_remote_disconnect(remote)
            throw error
        }
    }

    /// The updates `accepted` sends, as git hands them to its pre-push
    /// hook (`run_pre_push_hook`): a ref already up to date is left out,
    /// a deletion sends `(delete)` and the null object ID, and a remote
    /// ref the remote doesn't have is at the null object ID.
    func pushUpdates(for accepted: [String], remoteRefs: RemoteRefs) throws -> [PushUpdate] {
        try accepted.compactMap { refspec -> PushUpdate? in
            guard let destination = destinationRefName(fromPushRefspec: refspec),
                  !isUpToDate(refspec, remoteRefs: remoteRefs)
            else { return nil }
            let body = refspec.hasPrefix("+") ? refspec.dropFirst() : Substring(refspec)
            let source = String(body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)[0])
            let remoteOID = remoteRefs.object(of: destination).map(Self.hex) ?? PushUpdate.nullOID
            guard !source.isEmpty else {
                return PushUpdate(
                    localRef: "(delete)", localOID: PushUpdate.nullOID,
                    remoteRef: destination, remoteOID: remoteOID)
            }
            var object: OpaquePointer?
            try check(git_revparse_single(&object, repo, source))
            defer { git_object_free(object) }
            let localOID = git_object_id(object).map { Self.hex($0.pointee) } ?? PushUpdate.nullOID
            return PushUpdate(
                localRef: source, localOID: localOID, remoteRef: destination, remoteOID: remoteOID)
        }
    }
}

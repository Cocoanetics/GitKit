import CGitKit

extension Repository {

    /// Hands `beforeSending` the updates `accepted` sends, if there is a
    /// callback, and returns refspecs frozen at the announced object IDs.
    /// If it throws, disconnects `remote` and rethrows, so nothing is sent.
    func announce(
        _ accepted: [String], remoteRefs: RemoteRefs,
        to beforeSending: (([PushUpdate]) throws -> Void)?, remote: OpaquePointer?,
        payload: UnsafeMutableRawPointer?
    ) throws -> [String] {
        guard let beforeSending else { return accepted }
        do {
            let (refspecs, updates) = try preparedPush(for: accepted, remoteRefs: remoteRefs)
            // libgit2 will report OID sources; summaries still name the
            // original refs, including ones expanded from patterns.
            if let payload {
                let box = Unmanaged<CallbackBox>.fromOpaque(payload).takeUnretainedValue()
                for refspec in accepted {
                    guard let destination = destinationRefName(fromPushRefspec: refspec),
                          box.reporter?.typedSources[Array(destination.utf8)] == nil else { continue }
                    box.reporter?.typedSources[Array(destination.utf8)] = String(
                        Self.unforced(refspec).split(separator: ":", maxSplits: 1,
                                                    omittingEmptySubsequences: false)[0])
                }
            }
            try beforeSending(updates)
            return refspecs
        } catch {
            git_remote_disconnect(remote)
            throw error
        }
    }

    /// Freeze every source, including refs already up to date, so a ref
    /// moved during the callback cannot change what libgit2 sends. Keep
    /// the original source names in the updates git hands its pre-push
    /// hook (`run_pre_push_hook`): a ref already up to date is left out,
    /// a deletion sends `(delete)` and the null object ID, and a remote
    /// ref the remote doesn't have is at the null object ID.
    func preparedPush(
        for accepted: [String], remoteRefs: RemoteRefs
    ) throws -> (refspecs: [String], updates: [PushUpdate]) {
        var refspecs: [String] = []
        var updates: [PushUpdate] = []
        for refspec in accepted {
            guard let destination = destinationRefName(fromPushRefspec: refspec) else { continue }
            let body = refspec.hasPrefix("+") ? refspec.dropFirst() : Substring(refspec)
            let source = String(body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)[0])
            let remoteOID = remoteRefs.object(of: destination).map(Self.hex) ?? PushUpdate.nullOID
            let localOID: String
            if source.isEmpty {
                localOID = PushUpdate.nullOID
                refspecs.append(refspec)
            } else {
                var object: OpaquePointer?
                try check(git_revparse_single(&object, repo, source))
                defer { git_object_free(object) }
                localOID = git_object_id(object).map { Self.hex($0.pointee) } ?? PushUpdate.nullOID
                refspecs.append("\(refspec.hasPrefix("+") ? "+" : "")\(localOID):\(destination)")
            }
            guard localOID != remoteOID else { continue }
            updates.append(PushUpdate(
                localRef: source.isEmpty ? "(delete)" : source,
                localOID: localOID, remoteRef: destination, remoteOID: remoteOID))
        }
        return (refspecs, updates)
    }
}

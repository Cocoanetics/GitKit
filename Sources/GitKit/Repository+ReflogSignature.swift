import CGitKit

extension Repository {
    /// libgit2's generic ref updates use config, rather than the operation's
    /// committer. Reuse amend's locked replacement, preserving the ids/message.
    func restampLatestReflog(_ name: String, committer: UnsafeMutablePointer<git_signature>?) throws {
        let exists = git_reference_has_log(repo, name)
        try check(min(exists, 0))
        guard exists == 1 else { return }
        var log: OpaquePointer?
        try check(git_reflog_read(&log, repo, name))
        defer { git_reflog_free(log) }
        guard let entry = git_reflog_entry_byindex(log, 0),
              let old = git_reflog_entry_id_old(entry), let new = git_reflog_entry_id_new(entry),
              let message = git_reflog_entry_message(entry) else { return }
        do {
            try restampReflog(name, old: old.pointee, new: new.pointee, committer: committer,
                             message: Self.bytes(message))
        } catch let error as Libgit2Error where error.code == GIT_ELOCKED.rawValue {
            // The ref update has already succeeded. Another writer's
            // reflog lock must not turn the completed operation into an error.
        }
    }
}

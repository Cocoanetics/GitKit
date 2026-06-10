import Foundation
import CGitKit

/// One entry in a ref's reflog. Refs have a per-ref reflog stored in
/// `.git/logs/refs/heads/<branch>` (or `.git/logs/HEAD` for HEAD).
public struct ReflogEntry: Sendable {
    /// SHA the ref pointed at before the change.
    public let oldSHA: String
    /// SHA after the change.
    public let newSHA: String
    /// Name of the user who made the ref update (git takes it from
    /// `user.name`).
    public let committerName: String
    /// Email of the user who made the ref update (from `user.email`),
    /// without the `<>` brackets.
    public let committerEmail: String
    /// When the ref update was recorded, in Unix seconds.
    public let time: TimeInterval
    /// Timezone of the entry as minutes east of UTC (e.g. 120 = +0200).
    public let offsetMinutes: Int
    /// The action message ("commit:", "merge:", "rebase…", etc).
    public let message: String
}

extension Repository {

    /// Read the reflog for `refName` (default `HEAD`). Newest entries
    /// come first — matches `git reflog`.
    public func reflog(refName: String = "HEAD") throws -> [ReflogEntry] {
        var log: OpaquePointer?
        try check(refName.withCString { name in
            git_reflog_read(&log, repo, name)
        })
        defer { git_reflog_free(log) }

        let count = Int(git_reflog_entrycount(log))
        var entries: [ReflogEntry] = []
        entries.reserveCapacity(count)
        for i in 0..<count {
            try Task.checkCancellation()
            guard let entry = git_reflog_entry_byindex(log, i) else { continue }

            var oldOID = git_reflog_entry_id_old(entry)?.pointee ?? git_oid()
            var newOID = git_reflog_entry_id_new(entry)?.pointee ?? git_oid()
            let oldSHA = formatOID(&oldOID)
            let newSHA = formatOID(&newOID)
            let sig = git_reflog_entry_committer(entry)?.pointee
            let msg = git_reflog_entry_message(entry).map { String(cString: $0) } ?? ""

            entries.append(ReflogEntry(
                oldSHA: oldSHA, newSHA: newSHA,
                committerName: sig?.name.map { String(cString: $0) } ?? "",
                committerEmail: sig?.email.map { String(cString: $0) } ?? "",
                time: TimeInterval(sig?.when.time ?? 0),
                offsetMinutes: Int(sig?.when.offset ?? 0),
                message: msg))
        }
        return entries
    }
}

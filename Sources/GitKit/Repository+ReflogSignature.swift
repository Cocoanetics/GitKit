import CGitKit

struct ReflogRestamp {
    let name: String
    let old: git_oid?
    let message: [UInt8]?
}

extension Repository {
    /// libgit2's generic ref updates use config, rather than the operation's
    /// committer. Replace their reflog entries only while every affected ref
    /// is locked and the updated ref still has the operation's expected tip.
    func restampReflogs(
        afterUpdating reference: String,
        to expectedNew: git_oid,
        entries: [ReflogRestamp],
        committer: UnsafeMutablePointer<git_signature>?
    ) throws {
        var locks: [OpaquePointer?] = []
        defer { locks.forEach { gitkit_lockfile_release($0) } }
        for name in entries.map(\.name).uniqued() {
            var lock: OpaquePointer?
            let rc = gitkit_lockfile_acquire(&lock, reflogRefPath(name))
            if rc == GIT_ELOCKED.rawValue { return }
            try check(rc)
            locks.append(lock)
        }

        var actual = git_oid()
        var expectedNew = expectedNew
        guard git_reference_name_to_id(&actual, repo, reference) == 0,
              git_oid_equal(&actual, &expectedNew) != 0,
              reference == "HEAD" || !entries.contains(where: { $0.name == "HEAD" })
                || symbolicHeadTarget() == reference
        else { return }

        for expected in entries {
            do {
                try restampLatestReflog(expected, new: expectedNew, committer: committer)
            } catch let error as Libgit2Error where error.code == GIT_ELOCKED.rawValue {
                // The ref update has already succeeded. A log lock held by
                // another writer must not turn the completed operation into
                // an error; the ref locks still prevent a lost append here.
            }
        }
    }

    private func restampLatestReflog(
        _ expected: ReflogRestamp,
        new: git_oid,
        committer: UnsafeMutablePointer<git_signature>?
    ) throws {
        var new = new
        let exists = git_reference_has_log(repo, expected.name)
        try check(min(exists, 0))
        guard exists == 1 else { return }
        var log: OpaquePointer?
        try check(git_reflog_read(&log, repo, expected.name))
        defer { git_reflog_free(log) }
        guard let entry = git_reflog_entry_byindex(log, 0),
              let old = git_reflog_entry_id_old(entry),
              let loggedNew = git_reflog_entry_id_new(entry),
              git_oid_equal(loggedNew, &new) != 0,
              expected.old.map({ expectedOld in
                  var expectedOld = expectedOld
                  return git_oid_equal(old, &expectedOld) != 0
              }) ?? true,
              let message = git_reflog_entry_message(entry),
              expected.message.map({ expectedMessage in
                  Self.bytes(message) == expectedMessage
              }) ?? true
        else { return }
        try restampReflog(expected.name, old: old.pointee, new: new, committer: committer,
                         message: Self.bytes(message))
    }

    private func reflogRefPath(_ name: String) -> String {
        let directory = name == "HEAD" ? git_repository_path(repo) : git_repository_commondir(repo)
        return (directory.map { String(cString: $0) } ?? "") + name
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

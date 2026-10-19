import Foundation
import CGitKit

/// Why ``Repository/amendDetailed(message:author:resetAuthor:allowEmpty:env:)``
/// refused to amend. ``description`` is real git's wording; the cases
/// note the stream and exit status `git commit --amend` uses.
public enum CommitAmendError: Error, Equatable, CustomStringConvertible {
    /// HEAD is unborn: `fatal: You have nothing to amend.`, exit 128.
    case nothingToAmend
    /// `MERGE_HEAD` exists:
    /// `fatal: You are in the middle of a merge -- cannot amend.`, exit 128.
    case mergeInProgress
    /// `CHERRY_PICK_HEAD` exists:
    /// `fatal: You are in the middle of a cherry-pick -- cannot amend.`, exit 128.
    case cherryPickInProgress
    /// The index has conflicts at these paths. Git prints
    /// `error: Committing is not possible because you have unmerged files.`,
    /// two `hint:` lines, `fatal: Exiting because of an unresolved conflict.`
    /// and `U\t<path>` per path; exit 128.
    case unmergedFiles([String])
    /// The new commit's tree would equal its first parent's (the empty
    /// tree for a root commit) and neither `allowEmpty` nor a merge commit
    /// excuses it. Git prints ``emptyAmendAdvice`` to stderr, then the
    /// short status (`On branch main` … `No changes`) to stdout; exit 1.
    case wouldBeEmpty

    /// Real git's advice for an amend that would leave the commit empty.
    public static let emptyAmendAdvice = """
        You asked to amend the most recent commit, but doing so would make
        it empty. You can repeat your command with --allow-empty, or you can
        remove the commit entirely with "git reset HEAD^".

        """

    public var description: String {
        switch self {
        case .nothingToAmend: return "You have nothing to amend."
        case .mergeInProgress: return "You are in the middle of a merge -- cannot amend."
        case .cherryPickInProgress: return "You are in the middle of a cherry-pick -- cannot amend."
        case .unmergedFiles: return "Committing is not possible because you have unmerged files."
        case .wouldBeEmpty: return Self.emptyAmendAdvice
        }
    }
}

extension Repository {

    /// Replace HEAD's tip commit with a new one recording exactly what's
    /// staged — `git commit --amend`. The new commit keeps the old one's
    /// parents; the committer is resolved as for a new commit (`env` feeds
    /// `GIT_COMMITTER_*`, see ``SignatureResolver``). HEAD (or the branch
    /// it names) moves with the reflog message `commit (amend): <subject>`,
    /// as git writes it, then clears a concluded revert's state
    /// (`REVERT_HEAD`, `MERGE_MSG`) as git's commit does.
    ///
    /// - Parameters:
    ///   - message: The new message (`-m`); nil keeps the old one
    ///     (`--no-edit`), re-encoded as git does when the old commit has a
    ///     different `encoding` header than `i18n.commitEncoding` asks for.
    ///   - author: `--author`: replaces name and email but keeps the old
    ///     author date. Nil keeps the old author entirely; `GIT_AUTHOR_*`
    ///     doesn't apply, as in git.
    ///   - resetAuthor: `--reset-author`: resolve the author like a new
    ///     commit's (config, `GIT_AUTHOR_*`, now), with `author` if given.
    ///   - allowEmpty: `--allow-empty`: allow a tree equal to the first
    ///     parent's. A merge commit may always keep its first parent's tree.
    /// - Throws: ``CommitAmendError`` where git refuses; ``Libgit2Error``
    ///   otherwise — ``Libgit2Error/isLocked`` when another process holds
    ///   `index.lock` (git's "Unable to create '…/index.lock'").
    ///
    /// Stage first for `commit -a --amend` (``stageTrackedChanges()``).
    /// The result's diffstat is against the first parent, like git's
    /// summary; ``Libgit2CommitDetails/isRoot`` is false (git prints no
    /// `(root-commit)` for an amend).
    public func amendDetailed(
        message: String? = nil,
        author: Signature? = nil,
        resetAuthor: Bool = false,
        allowEmpty: Bool = false,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Libgit2CommitDetails {
        let old = try commitToAmend()
        defer { git_commit_free(old) }
        // Git checks the state before the index, in this order.
        if FileManager.default.fileExists(atPath: gitDirPath + "MERGE_HEAD") {
            throw CommitAmendError.mergeInProgress
        }
        if FileManager.default.fileExists(atPath: gitDirPath + "CHERRY_PICK_HEAD") {
            throw CommitAmendError.cherryPickInProgress
        }

        // Like git, hold index.lock from before reading the index until
        // HEAD has moved; another process holding it fails the amend
        // (``Libgit2Error/isLocked``).
        var lock: OpaquePointer?
        try check(gitkit_index_lock_acquire(&lock, repo))
        defer { gitkit_index_lock_release(lock) }
        var index: OpaquePointer?
        try check(git_repository_index(&index, repo))
        defer { git_index_free(index) }
        // Record the index as it is on disk now, as git does, even if
        // another process changed it since this handle last read it.
        try check(git_index_read(index, 0))
        let unmerged = try unmergedPaths(in: index)
        if !unmerged.isEmpty { throw CommitAmendError.unmergedFiles(unmerged) }

        var treeOID = git_oid()
        try check(git_index_write_tree(&treeOID, index))
        var newTree: OpaquePointer?
        try check(git_tree_lookup(&newTree, repo, &treeOID))
        defer { git_tree_free(newTree) }

        let parentCount = git_commit_parentcount(old)
        var parents: [OpaquePointer?] = []
        defer { for parent in parents { git_commit_free(parent) } }
        for i in 0..<parentCount {
            var parent: OpaquePointer?
            try check(git_commit_parent(&parent, old, i))
            parents.append(parent)
        }

        // The first parent's tree (none for a root commit: the empty
        // tree) is what git's empty rule and summary compare against.
        var baseTree: OpaquePointer?
        if let first = parents.first {
            try check(git_commit_tree(&baseTree, first))
        }
        defer { if baseTree != nil { git_tree_free(baseTree) } }

        if !allowEmpty, parentCount < 2 {
            let empty = baseTree.map { git_oid_equal(git_tree_id($0), &treeOID) != 0 }
                ?? (git_tree_entrycount(newTree) == 0)
            if empty { throw CommitAmendError.wouldBeEmpty }
        }
        let stats = try commitStats(from: baseTree, to: newTree)

        let authorSig = try amendAuthor(of: old, override: author, reset: resetAuthor, env: env)
        defer { git_signature_free(authorSig) }
        let committerSig = try SignatureResolver.resolve(
            role: .committer, override: nil, repo: repo, env: env)
        defer { git_signature_free(committerSig) }

        let encoding = try configGet("i18n.commitEncoding").flatMap { Self.isUTF8($0) ? nil : $0 }
        var text = message.map { Array($0.utf8) } ?? oldMessage(of: old, encoding: encoding)
        text.append(0)

        var commitOID = git_oid()
        _ = try parents.withUnsafeMutableBufferPointer { buffer in
            try text.withUnsafeBufferPointer { bytes in
                try bytes.withMemoryRebound(to: CChar.self) { msg in
                    try check(git_commit_create(
                        &commitOID, repo, nil, authorSig, committerSig, encoding,
                        msg.baseAddress, newTree, buffer.count, buffer.baseAddress))
                }
            }
        }

        // The subject's bytes as they are, in whatever encoding the
        // commit has: git logs them unconverted.
        let subject = text.dropLast().prefix { $0 != UInt8(ascii: "\n") }
        guard let oldOID = git_commit_id(old)?.pointee else {
            throw Libgit2Error(code: -1, klass: 0, message: "commit to amend has no id")
        }
        try moveHead(from: oldOID, to: commitOID, committer: committerSig,
                     reflog: Self.reflogMessage(Array("commit (amend): ".utf8) + subject))
        removeCommitState()

        let sha = formatOID(&commitOID)
        return Libgit2CommitDetails(
            sha: sha,
            shortSHA: String(sha.prefix(7)),
            branchName: currentBranchShorthand(),
            isRoot: false,
            filesChanged: stats.filesChanged,
            insertions: stats.insertions,
            deletions: stats.deletions,
            addedFiles: stats.added,
            deletedFiles: stats.deleted,
            author: ResolvedSignature(authorSig),
            committer: ResolvedSignature(committerSig),
            showsAuthorDate: !resetAuthor)
    }

    /// HEAD's commit, or ``CommitAmendError/nothingToAmend`` when HEAD
    /// is unborn.
    private func commitToAmend() throws -> OpaquePointer? {
        var oid = git_oid()
        let rc = git_reference_name_to_id(&oid, repo, "HEAD")
        if rc == GIT_ENOTFOUND.rawValue || rc == GIT_EUNBORNBRANCH.rawValue {
            throw CommitAmendError.nothingToAmend
        }
        try check(rc)
        var commit: OpaquePointer?
        try check(git_commit_lookup(&commit, repo, &oid))
        return commit
    }

    private var gitDirPath: String {
        git_repository_path(repo).map { String(cString: $0) } ?? ""
    }

    /// The conflicted paths in `index`, sorted.
    private func unmergedPaths(in index: OpaquePointer?) throws -> [String] {
        guard git_index_has_conflicts(index) != 0 else { return [] }
        var iterator: OpaquePointer?
        try check(git_index_conflict_iterator_new(&iterator, index))
        defer { git_index_conflict_iterator_free(iterator) }
        var paths = Set<String>()
        while true {
            var ancestor: UnsafePointer<git_index_entry>?
            var ours: UnsafePointer<git_index_entry>?
            var theirs: UnsafePointer<git_index_entry>?
            let rc = git_index_conflict_next(&ancestor, &ours, &theirs, iterator)
            if rc == GIT_ITEROVER.rawValue { break }
            try check(rc)
            if let entry = ancestor ?? ours ?? theirs, let path = entry.pointee.path {
                paths.insert(String(cString: path))
            }
        }
        return paths.sorted()
    }

    /// The amended commit's author: the old one (date included), with
    /// `override`'s name and email; or, for `reset`, a new commit's.
    private func amendAuthor(
        of commit: OpaquePointer?, override: Signature?, reset: Bool, env: [String: String]
    ) throws -> UnsafeMutablePointer<git_signature>? {
        if reset {
            return try SignatureResolver.resolve(role: .author, override: override, repo: repo, env: env)
        }
        guard let old = git_commit_author(commit) else {
            throw Libgit2Error(code: -1, klass: 0, message: "commit to amend has no author")
        }
        var sig: UnsafeMutablePointer<git_signature>?
        if let override {
            try check(git_signature_new(&sig, override.name, override.email,
                                        old.pointee.when.time, old.pointee.when.offset))
            sig?.pointee.when.sign = old.pointee.when.sign
        } else {
            try check(git_signature_dup(&sig, old))
        }
        return sig
    }

    /// The old commit's raw message, re-encoded from its `encoding` header
    /// to the new commit's (`i18n.commitEncoding`, else UTF-8) with iconv,
    /// as git does; verbatim where that fails, as git keeps a message it
    /// can't convert. Without iconv (Windows, Android before API 28) only
    /// the charsets Foundation names convert.
    private func oldMessage(of commit: OpaquePointer?, encoding: String?) -> [UInt8] {
        guard let raw = git_commit_message(commit) else { return [] }
        let bytes = Array(UnsafeBufferPointer(
            start: UnsafeRawPointer(raw).assumingMemoryBound(to: UInt8.self), count: strlen(raw)))
        let source = git_commit_message_encoding(commit).map { String(cString: $0) } ?? "UTF-8"
        let target = encoding ?? "UTF-8"
        if Self.sameEncoding(source, target) { return bytes }
        switch Self.iconv(bytes, from: source, to: target) {
        case .converted(let converted): return converted
        case .failed: return bytes
        case .unsupported: break
        }
        guard let from = Self.stringEncoding(source), let to = Self.stringEncoding(target),
              let decoded = String(data: Data(bytes), encoding: from),
              let encoded = decoded.data(using: to) else { return bytes }
        return Array(encoded)
    }

    private enum Reencoding {
        case converted([UInt8])
        /// iconv knows both charsets but the bytes don't convert.
        case failed
        /// No iconv, or one that doesn't know the pair.
        case unsupported
    }

    /// git's `reencode_string_len()`: `bytes` from charset `from` to `to`.
    private static func iconv(_ bytes: [UInt8], from: String, to: String) -> Reencoding {
        // iconv spells UTF-8 one way; git accepts the others too.
        let from = isUTF8(from) ? "UTF-8" : from
        let to = isUTF8(to) ? "UTF-8" : to
        var out: UnsafeMutablePointer<CChar>?
        var count = 0
        let rc = bytes.withUnsafeBufferPointer { buffer in
            buffer.withMemoryRebound(to: CChar.self) {
                gitkit_reencode(&out, &count, $0.baseAddress, $0.count, to, from)
            }
        }
        defer { free(out) }
        switch rc {
        case 0:
            guard let out else { return .failed }
            return .converted(Array(UnsafeRawBufferPointer(start: out, count: count)))
        case -1: return .failed
        default: return .unsupported
        }
    }

    /// `message` as git logs it (`copy_reflog_msg`): leading and trailing
    /// whitespace dropped, each run inside collapsed to one space. Bytes,
    /// not a string: a subject in the commit's encoding is logged as is.
    static func reflogMessage(_ message: [UInt8]) -> [UInt8] {
        let space: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        return Array(message.split(whereSeparator: space.contains).joined(separator: [0x20]))
    }

    /// What a successful commit clears, as git does: the merge and squash
    /// leftovers (`MERGE_MSG`, `MERGE_MODE`, `SQUASH_MSG`, `AUTO_MERGE`)
    /// and a concluded revert's `REVERT_HEAD`, with the sequencer's state
    /// once that was its last pick. Rebase state stays.
    private func removeCommitState() {
        let fm = FileManager.default
        let dir = gitDirPath
        for name in ["MERGE_MSG", "MERGE_MODE", "SQUASH_MSG", "AUTO_MERGE"] {
            try? fm.removeItem(atPath: dir + name)
        }
        guard fm.fileExists(atPath: dir + "REVERT_HEAD") else { return }
        try? fm.removeItem(atPath: dir + "REVERT_HEAD")
        // git's have_finished_the_last_pick(): a todo of one line.
        guard let todo = fm.contents(atPath: dir + "sequencer/todo") else { return }
        let lines = todo.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if lines.count == 1 || (lines.count == 2 && lines[1].isEmpty) {
            try? fm.removeItem(atPath: dir + "sequencer")
        }
    }

    private static func normalized(_ name: String) -> String {
        name.lowercased().filter { $0 != "-" && $0 != "_" }
    }

    static func isUTF8(_ name: String) -> Bool { normalized(name) == "utf8" }

    private static func sameEncoding(_ lhs: String, _ rhs: String) -> Bool {
        normalized(lhs) == normalized(rhs)
    }

    /// The Foundation encoding for an IANA charset name git accepts.
    private static func stringEncoding(_ name: String) -> String.Encoding? {
        switch normalized(name) {
        case "utf8": return .utf8
        case "iso88591", "latin1": return .isoLatin1
        case "iso88592", "latin2": return .isoLatin2
        case "usascii", "ascii": return .ascii
        case "cp1250", "windows1250": return .windowsCP1250
        case "cp1251", "windows1251": return .windowsCP1251
        case "cp1252", "windows1252": return .windowsCP1252
        case "cp1253", "windows1253": return .windowsCP1253
        case "cp1254", "windows1254": return .windowsCP1254
        case "shiftjis", "sjis": return .shiftJIS
        case "eucjp": return .japaneseEUC
        case "utf16": return .utf16
        default: return nil
        }
    }

    /// Move HEAD — the branch it names, or HEAD itself when detached —
    /// from `old` to `new`, logging `reflog` under the committer's
    /// identity and date as git does.
    private func moveHead(
        from old: git_oid, to new: git_oid,
        committer: UnsafeMutablePointer<git_signature>?, reflog: [UInt8]
    ) throws {
        let detached = git_repository_head_detached(repo) == 1
        var name = "HEAD"
        if !detached {
            var head: OpaquePointer?
            try check(git_repository_head(&head, repo))
            defer { git_reference_free(head) }
            name = String(cString: git_reference_name(head))
        }
        var expected = old
        var target = new
        var moved: OpaquePointer?
        try Self.withCString(reflog) { message in
            try check(git_reference_create_matching(&moved, repo, name, &target, 1, &expected, message))
        }
        git_reference_free(moved)
        // libgit2 logs the update under the config identity and "now";
        // git logs a commit's ref update under its committer.
        for log in detached ? ["HEAD"] : [name, "HEAD"] {
            try restampReflog(log, old: old, new: new, committer: committer, message: reflog)
        }
    }

    /// Replace `name`'s newest reflog entry — the `old` → `new` update
    /// just logged with `message` — by the same entry under `committer`.
    /// A ref without a reflog (`core.logAllRefUpdates=false`) is left
    /// without one.
    private func restampReflog(
        _ name: String, old: git_oid, new: git_oid,
        committer: UnsafeMutablePointer<git_signature>?, message: [UInt8]
    ) throws {
        // Reading a missing reflog would create it, empty.
        let exists = git_reference_has_log(repo, name)
        try check(min(exists, 0))
        guard exists == 1 else { return }
        var log: OpaquePointer?
        try check(git_reflog_read(&log, repo, name))
        defer { git_reflog_free(log) }
        var old = old
        var new = new
        // `append` takes the old id from the entry before, so restamp only
        // where that is the update's own.
        guard let entry = git_reflog_entry_byindex(log, 0),
              git_oid_equal(git_reflog_entry_id_new(entry), &new) != 0,
              git_oid_equal(git_reflog_entry_id_old(entry), &old) != 0,
              let logged = git_reflog_entry_message(entry),
              Self.withCString(message, { strcmp(logged, $0) }) == 0,
              let previous = git_reflog_entry_byindex(log, 1),
              git_oid_equal(git_reflog_entry_id_new(previous), &old) != 0
        else { return }
        try check(git_reflog_drop(log, 0, 0))
        try Self.withCString(message) { try check(git_reflog_append(log, &new, committer, $0)) }
        try check(git_reflog_write(log))
    }

    /// `bytes`, NUL-terminated, as a C string.
    private static func withCString<R>(
        _ bytes: [UInt8], _ body: (UnsafePointer<CChar>) throws -> R
    ) rethrows -> R {
        try (bytes + [0]).withUnsafeBufferPointer { buffer in
            try buffer.withMemoryRebound(to: CChar.self) { try body($0.baseAddress!) }
        }
    }
}

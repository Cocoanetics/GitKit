import Foundation
import CGitKit

/// One hunk returned by ``Repository/blame(path:)``. Each line in a
/// blamed file falls into exactly one hunk; `linesInHunk` tells you
/// how many consecutive lines starting at `startLine` share the same
/// last-changed commit.
public struct BlameHunk: Sendable {
    /// Full 40-char SHA of the commit that last changed these lines.
    public let commitSHA: String
    /// First 7 characters of ``commitSHA``.
    public let shortSHA: String
    /// Author name of the blamed commit.
    public let authorName: String
    /// Author email of the blamed commit, without the `<>` brackets.
    public let authorEmail: String
    /// Author timestamp of the blamed commit, in Unix seconds.
    public let authorTime: TimeInterval
    /// First line of the blamed commit's message (the `summary` field
    /// in `git blame --porcelain` output).
    public let summary: String
    /// 1-based line number in the final version of the file where
    /// this hunk starts.
    public let startLine: Int
    /// Number of consecutive lines, starting at ``startLine``,
    /// attributed to ``commitSHA``.
    public let linesInHunk: Int
}

extension Repository {

    /// Walk `path`'s last-changed-commit hunks. Equivalent of
    /// `git blame <path>` minus the per-line text rendering — the CLI
    /// pairs this output with the file's lines to produce real-git's
    /// formatted output.
    public func blame(path: String) throws -> [BlameHunk] {
        var opts = git_blame_options()
        try check(git_blame_options_init(&opts, UInt32(GIT_BLAME_OPTIONS_VERSION)))

        var blame: OpaquePointer?
        try check(path.withCString { p in
            git_blame_file(&blame, repo, p, &opts)
        })
        defer { git_blame_free(blame) }

        let count = Int(git_blame_get_hunk_count(blame))
        var hunks: [BlameHunk] = []
        hunks.reserveCapacity(count)
        for i in 0..<count {
            try Task.checkCancellation()
            guard let h = git_blame_get_hunk_byindex(blame, UInt32(i))?.pointee
            else { continue }
            var oid = h.final_commit_id
            let sha = formatOID(&oid)

            // Lookup commit for the summary line — the blame hunk
            // doesn't carry the message itself, just the OID.
            var summary = ""
            var commit: OpaquePointer?
            if git_commit_lookup(&commit, repo, &oid) == 0 {
                defer { git_commit_free(commit) }
                let msg = git_commit_message(commit).map { String(cString: $0) } ?? ""
                summary = msg.split(separator: "\n").first.map(String.init) ?? ""
            }

            let sig = h.final_signature?.pointee
            hunks.append(BlameHunk(
                commitSHA: sha,
                shortSHA: String(sha.prefix(7)),
                authorName: sig?.name.map { String(cString: $0) } ?? "",
                authorEmail: sig?.email.map { String(cString: $0) } ?? "",
                authorTime: TimeInterval(sig?.when.time ?? 0),
                summary: summary,
                startLine: Int(h.final_start_line_number),
                linesInHunk: Int(h.lines_in_hunk)))
        }
        return hunks
    }
}

import Foundation
import CGitKit

// The per-ref lines of a fetch summary (builtin/fetch.c's
// update_local_ref and format_display), and the ancestry test the push
// summary shares.

/// git's line for a local ref a fetch changed (`update_local_ref`): new
/// refs by the kind of remote ref, fast-forwards as `old..new`, other
/// moves as forced, a moved tag as `[tag update]`, a pruned ref as
/// `[deleted]`.
func fetchLine(
    refname: String, old: git_oid?, new: git_oid?, spec: OpaquePointer?,
    reporter: ProgressReporter
) -> FetchSummaryLine {
    let local = shortRefName(refname)
    guard let new else {
        return .init(kind: .deleted, flag: "-", summary: "[deleted]",
                     remoteRef: "", remote: "(none)", localRef: refname, local: local)
    }
    // The refspec maps the local ref back to the remote one. A tag libgit2
    // followed comes with whatever refspec it was working through, which
    // doesn't map it: such a tag maps onto itself.
    let remoteRef = remoteRefName(of: refname, through: spec) ?? refname
    let remote = shortRefName(remoteRef)
    guard let old else {
        let kind = remoteRef.hasPrefix("refs/tags/") ? "[new tag]"
            : remoteRef.hasPrefix("refs/heads/") ? "[new branch]" : "[new ref]"
        return .init(kind: .update, flag: "*", summary: kind,
                     remoteRef: remoteRef, remote: remote, localRef: refname, local: local)
    }
    if refname.hasPrefix("refs/tags/") {
        return .init(kind: .update, flag: "t", summary: "[tag update]",
                     remoteRef: remoteRef, remote: remote, localRef: refname, local: local)
    }
    // git shows the old side as the commit it peels to (update_local_ref's
    // `current`), the new side as it is.
    let oldShown = reporter.repository.flatMap { peeledCommitID(old, in: $0) } ?? old
    let oldID = abbreviated(oldShown, minimum: reporter.abbreviation, in: reporter.repository)
    let newID = abbreviated(new, minimum: reporter.abbreviation, in: reporter.repository)
    // With fetch.showForcedUpdates off, git skips the ancestry walk and
    // shows every update as a fast-forward.
    if !reporter.showForcedUpdates || isFastForward(from: old, to: new, in: reporter.repository) {
        return .init(kind: .update, flag: " ", summary: "\(oldID)..\(newID)",
                     remoteRef: remoteRef, remote: remote, localRef: refname, local: local)
    }
    return .init(kind: .update, flag: "+", summary: "\(oldID)...\(newID)",
                 remoteRef: remoteRef, remote: remote, localRef: refname, local: local,
                 note: "forced update")
}

/// The remote ref `spec` maps onto local ref `refname`, if it does.
private func remoteRefName(of refname: String, through spec: OpaquePointer?) -> String? {
    guard let spec else { return nil }
    var buffer = git_buf()
    defer { git_buf_dispose(&buffer) }
    guard git_refspec_rtransform(&buffer, spec, refname) == 0, let pointer = buffer.ptr else {
        return nil
    }
    return String(cString: pointer)
}

/// Whether moving a ref from `old` to `new` is a fast-forward: `new`'s
/// commit is `old`'s or descends from it, annotated tags peeled to the
/// commits they point at (as git's `in_merge_bases` sees them).
func isFastForward(from old: git_oid, to new: git_oid, in repository: OpaquePointer?) -> Bool {
    guard let repository,
          var old = peeledCommitID(old, in: repository),
          var new = peeledCommitID(new, in: repository)
    else { return false }
    return git_oid_equal(&old, &new) == 1 || git_graph_descendant_of(repository, &new, &old) == 1
}

/// The commit `oid` is or, as an annotated tag, points at; `nil` for
/// anything else, or an object the repository doesn't have.
private func peeledCommitID(_ oid: git_oid, in repository: OpaquePointer) -> git_oid? {
    var oid = oid
    var object: OpaquePointer?
    guard git_object_lookup(&object, repository, &oid, GIT_OBJECT_ANY) == 0 else { return nil }
    defer { git_object_free(object) }
    var commit: OpaquePointer?
    guard git_object_peel(&commit, object, GIT_OBJECT_COMMIT) == 0 else { return nil }
    defer { git_object_free(commit) }
    return git_object_id(commit)?.pointee
}

import Foundation

/// The heads `git merge` records as a merge's parents, after dropping
/// those already reachable from HEAD or from another head
/// (`reduce_heads`).
public struct MergeHeads: Sendable, Equatable {
    /// The heads still to merge, as given, in the order given.
    public let heads: [String]
    /// Whether HEAD is reachable from one of them, so that a merge
    /// commit leaves it out of its parents unless `--no-ff` asks.
    public let headSubsumed: Bool
}

/// One head as git's octopus strategy (`git-merge-octopus`) took it.
public struct OctopusMergeStep: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// `Already up to date with <head>`: HEAD's side already has it.
        case alreadyUpToDate
        /// `Fast-forwarding to: <head>`: nothing merged so far was not
        /// already in it.
        case fastForward
        /// `Trying simple merge with <head>`.
        case merge
    }

    /// The head as it was given.
    public let head: String
    public let kind: Kind
    /// For a merge the trivial (`read-tree --aggressive`) merge couldn't
    /// do, the paths the automatic merge (`git-merge-one-file`) went
    /// over, in index order; `nil` when the trivial merge did it, or when
    /// the step failed before merging.
    public let automatic: [OctopusPathMerge]?
}

/// What `git-merge-one-file` did with one path both sides changed.
public enum OctopusPathMerge: Sendable, Equatable {
    /// `Auto-merging <path>`, merged cleanly.
    case merged(path: String)
    /// `Auto-merging <path>`, then `ERROR: content conflict in <path>`.
    case conflict(path: String)
    /// `Added <path> in both, but differently.`, then `ERROR: content
    /// conflict in <path>`. git-merge-one-file reads the empty blob for
    /// the missing ancestor without writing it, so when the repository
    /// lacks it git first says `fatal: unable to read blob object
    /// e69de29bb2d1d6434b8b29ae775ad8c2e48c5391` and `error: Could not
    /// stat : No such file or directory`. The path keeps our content.
    case addedInBoth(path: String, emptyBlobMissing: Bool)
    /// `ERROR: <path>: Not handling case <base> -> <ours> -> <theirs>`,
    /// each an object name or empty where that side has no such path.
    case notHandled(path: String, base: String, ours: String, theirs: String)
    /// `Adding <path>`, a path their side adds where a file and a
    /// directory meet (one side's file where the other has a directory,
    /// or below a file the base had), then git's update-index refusing
    /// each of `files`, the paths below a file that stays (none when the
    /// file is gone or unmerged, and the path was added):
    /// `error: '<file>' appears as both a file and as a directory`,
    /// `error: <file>: cannot add to the index - missing --add option?`
    /// and `fatal: git update-index: --cacheinfo cannot add <file>`.
    case addedOverDirectory(path: String, files: [String])
    /// Nothing said: git-merge-one-file removes a file our side deleted
    /// where it keeps a directory, which read-tree leaves to it.
    case removed(path: String)
    /// `ERROR: File <path> added identically in both branches,` and
    /// `ERROR: but permissions conflict <ours>-><theirs>.`: the same
    /// content, added with different modes (octal, as `100644`).
    case addedWithDifferentModes(path: String, ours: String, theirs: String)
    /// `Adding <path>`, then `ERROR: untracked <path> is overwritten by
    /// the merge.`: their side adds a path where a directory replaces
    /// a file or submodule, and a file the index doesn't track is there.
    case addedOverUntracked(path: String)
    /// `warning: unable to rmdir '<path>': Directory not empty`: read-tree
    /// removed a submodule whose directory still holds files.
    case submoduleDirectoryKept(path: String)
    /// `ERROR: File <path> deleted on one branch but had its` and
    /// `ERROR: permissions changed on the other.`: one side deleted it,
    /// the other kept its content but changed its mode.
    case deletedWithModeChange(path: String)
    /// `Auto-merging <path>`, then `ERROR: permissions conflict: <base>-><ours>,<theirs> in <path>`
    /// (`content conflict, permissions conflict: …` when the content
    /// conflicts too): both sides changed it and their modes (octal, as
    /// `100644`) differ. The merged content, if any, is in the work tree.
    case permissionsConflict(path: String, base: String, ours: String, theirs: String, contentConflict: Bool)
    /// `ERROR: <path>: Not merging symbolic link changes.`: both sides
    /// changed it, one to a symbolic link. Ours stays in the work tree.
    case symlink(path: String)
    /// `ERROR: <path>: Not merging conflicting submodule changes.`: both
    /// sides changed it, one to a submodule (gitlink).
    case submodule(path: String)

    public var path: String {
        switch self {
        case .merged(let path), .conflict(let path), .addedInBoth(let path, _),
             .notHandled(let path, _, _, _), .addedOverDirectory(let path, _), .symlink(let path),
             .submodule(let path), .addedWithDifferentModes(let path, _, _), .removed(let path),
             .permissionsConflict(let path, _, _, _, _), .deletedWithModeChange(let path),
             .addedOverUntracked(let path), .submoduleDirectoryKept(let path):
            return path
        }
    }

    /// Whether the path was left unmerged.
    public var failed: Bool {
        switch self {
        case .merged, .removed, .submoduleDirectoryKept: return false
        case .addedOverDirectory(_, let files): return !files.isEmpty
        default: return true
        }
    }
}

/// Why an octopus merge gave up, leaving HEAD, the index and the
/// working tree as they were (git's `Merge with strategy octopus
/// failed.`, exit 2).
public enum OctopusMergeFailure: Sendable, Equatable {
    /// `Error: Your local changes to the following files would be
    /// overwritten by merge`: the index differs from HEAD at these paths.
    case localChanges(paths: [String])
    /// `error: Entry '<path>' not uptodate. Cannot merge.`
    case notUpToDate(path: String)
    /// `error: Untracked working tree file '<path>' would be overwritten by merge.`
    case untrackedWouldBeOverwritten(path: String)
    /// `error: Updating '<path>' would lose untracked files in it`: the
    /// merge puts a file where untracked files sit in a directory.
    case untrackedFilesInDirectory(path: String)
    /// `Unable to find common commit with <head>`.
    case noCommonCommit(head: String)
    /// `Automated merge did not work.` / `Should not be doing an
    /// octopus.`: a head other than the last left conflicts.
    case conflictsBeforeLastHead
}

/// How an octopus merge ended.
public enum OctopusMergeOutcome: Sendable, Equatable {
    /// `Merge made by the 'octopus' strategy.`: the merge commit, and the
    /// diff stat from the old HEAD to it.
    /// `summaryLines` are git's ` create mode …`, ` delete mode …`,
    /// ` rename old => new (N%)` and ` mode change …` lines, in git's order.
    case mergeCommit(sha: String, statSummary: String, addedFiles: [String], deletedFiles: [String],
                     summaryLines: [String])
    /// The last head left conflicts, which are in the index and the
    /// working tree for the user to resolve, with `MERGE_HEAD`,
    /// `MERGE_MSG` and `MERGE_MODE` written for the commit that
    /// concludes the merge.
    case conflicts(paths: [String])
    /// The merge gave up and changed nothing.
    case failed(OctopusMergeFailure)
    /// The merge is made and checked out, but HEAD's ref couldn't move:
    /// its lock, `lockFile`, couldn't be created, for `reason` (as
    /// strerror says it: `File exists` where another process holds it,
    /// `Permission denied`, …). As git leaves it, the merged tree is
    /// staged with `MERGE_HEAD`, `MERGE_MSG` and `MERGE_MODE` written,
    /// for `git commit` to conclude.
    case headNotUpdated(lockFile: String, reason: String)
    /// The merge is made and checked out, but HEAD's ref no longer
    /// points at `expected`, the commit the merge began at: something
    /// moved it to `actual` meanwhile, and it is left there. As git
    /// leaves it, the merged tree is staged with `MERGE_HEAD`,
    /// `MERGE_MSG` and `MERGE_MODE` written.
    case headMoved(expected: String, actual: String)
    /// The merge is made and checked out, but `ref`, the branch HEAD
    /// names, went away meanwhile. As git leaves it, the merged tree is
    /// staged with `MERGE_HEAD`, `MERGE_MSG` and `MERGE_MODE` written.
    case headMissing(ref: String)
}

/// An octopus merge's steps and how it ended.
public struct OctopusMergeResult: Sendable, Equatable {
    public let steps: [OctopusMergeStep]
    public let outcome: OctopusMergeOutcome
}

import Foundation
import CGitKit

/// Options controlling a non-mutating tree or commit merge performed by
/// ``Repository/mergeTree(ours:theirs:options:)`` or
/// ``Repository/mergeTree(base:ours:theirs:options:)``.
public struct MergeTreeOptions: Sendable, Equatable {

    /// Controls whether newly created merge blobs and trees stay in memory
    /// or are persisted into the repository's object database.
    public enum Objects: Sendable, Equatable {
        /// Run the merge against a private in-memory pack layered over the
        /// repository's object database as read-only alternates.
        ///
        /// No object files are created and existing object/pack timestamps are
        /// not touched. A clean result's tree OID is the exact Git tree OID
        /// that writing the merge would produce, but newly synthesised blobs
        /// and trees exist only for the duration of the call and may not exist
        /// in the caller's object database afterwards.
        case inMemory

        /// Persist newly created merge blobs and trees as loose, unreferenced
        /// objects in the repository's object database, matching
        /// `git merge-tree --write-tree`.
        ///
        /// Existing refs, reflogs, `HEAD`, index, and working-tree files are
        /// never modified; the unreferenced objects remain eligible for Git GC.
        /// If a merge hits conflicts, blobs already synthesised for cleanly
        /// merged files during that merge pass may have been written.
        case write
    }

    /// How conflicting content regions are handled during file-level merging.
    ///
    /// Any value other than ``normal`` overrides `.gitattributes` merge drivers
    /// and uses libgit2's built-in text merge driver with the requested favor,
    /// matching libgit2's `git_merge_file_favor_t` semantics.
    public enum Favor: Sendable, Equatable {
        /// Record conflicting regions as conflicts (default).
        case normal
        /// Prefer the `ours` side for conflicting regions.
        case ours
        /// Prefer the `theirs` side for conflicting regions.
        case theirs
        /// Keep lines from both sides for conflicting regions.
        case union

        var libgit2: git_merge_file_favor_t {
            switch self {
            case .normal: GIT_MERGE_FILE_FAVOR_NORMAL
            case .ours: GIT_MERGE_FILE_FAVOR_OURS
            case .theirs: GIT_MERGE_FILE_FAVOR_THEIRS
            case .union: GIT_MERGE_FILE_FAVOR_UNION
            }
        }
    }

    /// Rename detection policy for the merge.
    public enum Renames: Sendable, Equatable {
        /// Detect renames with a similarity threshold percentage in `1...100`
        /// (default `50`). Candidate limits are read from `merge.renameLimit`
        /// / `diff.renameLimit` in the repository's configuration.
        case detect(threshold: Int = 50)
        /// Disable rename detection.
        case off
    }

    /// Where repository-tree `.gitattributes` files are read from during the merge.
    ///
    /// Attributes are never read from the caller's live index or working tree,
    /// so uncommitted or staged `.gitattributes` edits cannot perturb the
    /// result. This intentionally diverges from `git merge-tree` in a non-bare
    /// checkout.
    ///
    /// In all modes, libgit2's repository-level and external attribute files
    /// still apply in standard precedence:
    /// 1. `$GIT_COMMON_DIR/info/attributes`
    /// 2. `.gitattributes` from the selected tree (omitted for ``none``)
    /// 3. `core.attributesFile` from the repository's config snapshot (or XDG
    ///    `git/attributes` when unset)
    /// 4. system `gitattributes`
    public enum AttributeSource: Sendable, Equatable {
        /// Read repository `.gitattributes` from the resolved `ours` tree via
        /// a private in-memory index.
        case ours
        /// Read repository `.gitattributes` from the tree resolved from `spec`
        /// (pinned once at call start) via a private in-memory index.
        case tree(String)
        /// Do not read any repository-tree `.gitattributes` files (uses an
        /// empty in-memory index). `$GIT_COMMON_DIR/info/attributes`,
        /// `core.attributesFile` / XDG, and system attributes still apply.
        case none
    }

    public var objects: Objects
    public var favor: Favor
    public var renames: Renames
    public var attributes: AttributeSource
    /// When `true` (default), commit merges with multiple merge bases build a
    /// recursive virtual base in memory; when `false` (`GIT_MERGE_NO_RECURSIVE`),
    /// only the first merge base is used. Ignored by the explicit-tree overload.
    public var recursiveBases: Bool

    public init(
        objects: Objects = .inMemory,
        favor: Favor = .normal,
        renames: Renames = .detect(),
        attributes: AttributeSource = .ours,
        recursiveBases: Bool = true
    ) {
        self.objects = objects
        self.favor = favor
        self.renames = renames
        self.attributes = attributes
        self.recursiveBases = recursiveBases
    }
}

/// One unresolved conflict left by a merge-tree operation.
public struct MergeTreeConflict: Sendable, Equatable {

    /// One side (ancestor, ours, or theirs) of a conflicted entry.
    public struct Side: Sendable, Equatable {
        public let path: String
        public let oid: String
        public let mode: UInt32

        public init(path: String, oid: String, mode: UInt32) {
            self.path = path
            self.oid = oid
            self.mode = mode
        }
    }

    /// Best path representing the conflict, following Git/libgit2's selection
    /// order.
    public let path: String
    public let ancestor: Side?
    public let ours: Side?
    public let theirs: Side?

    public init(path: String, ancestor: Side?, ours: Side?, theirs: Side?) {
        self.path = path
        self.ancestor = ancestor
        self.ours = ours
        self.theirs = theirs
    }
}

/// Typed value result of a non-mutating merge-tree operation.
public struct MergeTreeResult: Sendable, Equatable {

    /// Whether the merge produced a clean tree or left unresolved conflicts.
    public enum Outcome: Sendable, Equatable {
        case clean(tree: String)
        case conflicted([MergeTreeConflict])
    }

    /// The resolved OID actually merged as `ours` (commit OID for the commit
    /// form, tree OID for the tree form), pinned once at call start.
    public let ours: String
    /// The resolved OID actually merged as `theirs` (commit OID for the commit
    /// form, tree OID for the tree form), pinned once at call start.
    public let theirs: String
    /// Merge base OIDs: all best common ancestor commit OIDs for the commit
    /// form (empty for unrelated histories), or `[baseTreeOID]` / `[]` for the
    /// explicit-tree form.
    public let mergeBases: [String]
    /// Clean merged tree OID or sorted unresolved conflicts.
    public let outcome: Outcome

    /// Convenience accessor for the merged tree OID when ``outcome`` is
    /// ``Outcome/clean(tree:)``; `nil` when conflicted.
    public var cleanTree: String? {
        if case .clean(let tree) = outcome { return tree }
        return nil
    }

    public init(ours: String, theirs: String, mergeBases: [String], outcome: Outcome) {
        self.ours = ours
        self.theirs = theirs
        self.mergeBases = mergeBases
        self.outcome = outcome
    }
}

/// Errors thrown when a merge-tree operation refuses an invalid input or an
/// unsupported Git merge feature rather than producing a divergent result.
public enum MergeTreeError: Error, Sendable, Equatable, LocalizedError {
    /// `merge.renormalize` is enabled in repository configuration; libgit2
    /// does not perform line-ending renormalization during merge.
    case unsupportedRenormalize
    /// A path participating in the merge (including any recursive virtual-base
    /// step) selects a custom merge driver configured via
    /// `merge.<driver>.driver`; GitKit never executes external merge drivers.
    case externalMergeDriver(path: String, driver: String)
    /// The revision spec resolved to an object that does not peel to a commit.
    case notACommit(String)
    /// The revision spec resolved to an object that does not peel to a tree.
    case notATree(String)
    /// `MergeTreeOptions.Renames.detect(threshold:)` received a value outside
    /// `1...100`.
    case invalidRenameThreshold(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedRenormalize:
            return "mergeTree does not support merge.renormalize=true"
        case .externalMergeDriver(let path, let driver):
            return "mergeTree cannot invoke external merge driver '\(driver)' for '\(path)'"
        case .notACommit(let spec):
            return "'\(spec)' does not peel to a commit"
        case .notATree(let spec):
            return "'\(spec)' does not peel to a tree"
        case .invalidRenameThreshold(let threshold):
            return "rename threshold \(threshold) is outside the valid range 1...100"
        }
    }
}

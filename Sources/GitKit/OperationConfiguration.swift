import Foundation
import CGitKit

/// Config levels for one operation — git's `GIT_CONFIG_GLOBAL`,
/// `GIT_CONFIG_SYSTEM` and `-c` / `GIT_CONFIG_COUNT` — for every repository
/// libgit2 opens while ``Repository/withOperationConfiguration(_:_:)`` runs,
/// including the ones it opens internally: a submodule's during status and
/// diff, submodule sync, staging a gitlink, worktree checks, a local clone.
///
/// A level replaces the user's or system file of the same level, which is
/// then not read at all (nor are its includes), as git reads no
/// `~/.gitconfig` under `GIT_CONFIG_GLOBAL`. Precedence is git's: an
/// ``ConfigLevel/app`` level is read over a repository's own config, a
/// ``ConfigLevel/global`` or ``ConfigLevel/system`` one under it. Writes
/// keep going to the repository's own config file.
///
/// A level never sets what git reads from the repository's own config only
/// — `core.repositoryformatversion`, `core.bare`, `core.worktree`,
/// `extensions.*`: an entries level naming one is refused, and a file
/// level's, or a file it includes, are not read, so a level never changes a
/// repository's format or layout.
public struct OperationConfiguration: Sendable {

    /// One level of the operation's config.
    public enum Level: Sendable {
        /// The config file at the URL, as `level`. A missing file reads as
        /// empty. The file is read by each open; its includes go through
        /// the include policy in force. Repository-only settings in it or
        /// its includes are skipped.
        case file(URL, ConfigLevel)
        /// `entries`, in order, as an in-memory `level`; `name` is the
        /// backend type reported for them (`git_config_entry.backend_type`).
        /// An `include.path` among them is stored, not followed.
        case entries([ConfigEntry], ConfigLevel = .app, name: String = "command line")
    }

    /// The levels, applied in order; a later level replaces an earlier one
    /// of the same ``ConfigLevel``.
    public var levels: [Level]

    /// The policy for the include files read by repositories opened during
    /// the operation that have no policy of their own — every one libgit2
    /// opens internally. `nil` keeps the calling thread's (a policy an outer
    /// ``Repository/open(at:includePolicy:)`` or host scope set) or else
    /// the process default.
    public var includePolicy: ConfigIncludePolicy?

    public init(levels: [Level], includePolicy: ConfigIncludePolicy? = nil) {
        self.levels = levels
        self.includePolicy = includePolicy
    }
}

extension Repository {

    /// Runs `body` with `configuration`'s levels part of the config of
    /// every repository opened on this thread meanwhile, from the open on —
    /// before anything libgit2 derives from the config: the format checks,
    /// the cached `core.*` values, a submodule's index, filters and
    /// attributes. With `includePolicy`, it also authorises their includes.
    ///
    /// The scope is the calling thread's, for the synchronous `body` only:
    /// another thread, including one a callback hands work to, does not
    /// see it, and the previous scope (an outer call's, or none) is back
    /// when this returns or throws. Nested in an outer call, its levels
    /// replace the outer ones of the same ``ConfigLevel`` only; the outer
    /// call's other levels stay in force, as does its `includePolicy`
    /// when `configuration` has none. Nothing global changes: no environment
    /// variable, search path or config file is written; the levels are
    /// copied, so nothing the caller holds is lent to libgit2.
    ///
    /// It applies to opens only. A `Repository` opened before keeps the
    /// config it has; add the levels to it with
    /// ``addConfigFile(at:level:)`` / ``addConfigEntries(_:level:name:)``.
    /// One opened during the operation keeps the levels after it (an
    /// explicit `.global` / `.system` ``ConfigScope`` then names the
    /// operation's file, as after ``addConfigFile(at:level:)``), and reads
    /// a file level's file again when it changes, with the include policy
    /// of the repository or process. Not covered: the configs libgit2
    /// reads without opening a repository — an init's template directory
    /// and `init.defaultBranch`, a detached remote's config.
    ///
    /// libgit2 clears the error of a repository it fails to open for
    /// itself and carries on: a refused include or unreadable level would
    /// leave a submodule reported changed with no error. Such a failure is
    /// recorded, and when `body` returns normally the first one not
    /// already thrown to `body` by a GitKit call is thrown instead of its
    /// result. When `body` throws, its error is thrown.
    ///
    /// - Throws: `GIT_EINVALIDSPEC` before `body` runs, for an entry that
    ///   is not a valid config entry or names a setting git reads from the
    ///   repository's own config only — `core.repositoryformatversion`,
    ///   `core.bare`, `core.worktree`, `extensions.*`; a recorded failure;
    ///   or what `body` throws.
    public static func withOperationConfiguration<T>(
        _ configuration: OperationConfiguration, _ body: () throws -> T
    ) throws -> T {
        Libgit2.ensureInitialized()
        let scope = try OperationConfigurationScope(configuration.levels)

        let restoreThreadPolicy = configuration.includePolicy
            .map(ConfigIncludePolicyBox.init)?.setForCurrentThread()
        defer { restoreThreadPolicy?() }

        try check(gitkit_config_scope_push(scope.pointer))
        let result: T
        do {
            defer { scope.pop() }
            result = try body()
        }
        if let failure = scope.firstFailure() { throw failure }
        return result
    }
}

/// Owns the C scope of one ``Repository/withOperationConfiguration(_:_:)``.
final class OperationConfigurationScope {
    let pointer: OpaquePointer

    init(_ levels: [OperationConfiguration.Level]) throws {
        var scope: OpaquePointer?
        try check(gitkit_config_scope_new(&scope))
        guard let scope else {
            throw Libgit2Error(code: -1, klass: 0, message: "gitkit_config_scope_new returned no scope")
        }
        pointer = scope

        for item in levels {
            switch item {
            case let .file(url, level):
                try check(gitkit_config_scope_add_file(pointer, level.libgit2, url.path))
            case let .entries(entries, level, name):
                try Self.rejectRepositoryOnly(entries)
                let text = try ConfigEntryText.serialize(entries)
                guard !name.utf8.contains(0) else {
                    throw ConfigEntryText.invalid("backend name contains a NUL character")
                }
                try check(gitkit_config_scope_add_entries(
                    pointer, level.libgit2, text, text.utf8.count, name))
            }
        }
    }

    deinit {
        gitkit_config_scope_free(pointer)
    }

    func pop() {
        // Pushed on this thread by the caller's frame, so innermost.
        let rc = gitkit_config_scope_pop(pointer)
        precondition(rc == 0, "operation configuration scope popped out of order")
    }

    func firstFailure() -> Libgit2Error? {
        var code: Int32 = 0
        var klass: Int32 = 0
        var message: UnsafePointer<CChar>?
        guard gitkit_config_scope_first_failure(pointer, &code, &klass, &message) == 1 else { return nil }
        return Libgit2Error(code: code, klass: klass, message: message.map { String(cString: $0) } ?? "unknown error")
    }

    /// A GitKit call throwing `error` hands back the failure the calling
    /// thread's scope recorded for it, if that is the error.
    static func markReported(_ error: Libgit2Error) {
        gitkit_config_scope_mark_reported(error.klass, error.message)
    }

    /// git reads the repository format and layout from the repository's
    /// own config; libgit2 would read them from the merged config at open.
    private static func rejectRepositoryOnly(_ entries: [ConfigEntry]) throws {
        for entry in entries {
            let name = entry.name.lowercased()
            let section = name.prefix { $0 != "." }
            let variable = String(name.split(separator: ".", omittingEmptySubsequences: false).last ?? "")
            let unscoped = name.filter { $0 == "." }.count == 1
            if section == "extensions" || (section == "core" && unscoped
                && ["repositoryformatversion", "bare", "worktree"].contains(variable)) {
                throw ConfigEntryText.invalid(
                    "'\(entry.name)' is read from the repository's own config, not an operation level")
            }
        }
    }
}

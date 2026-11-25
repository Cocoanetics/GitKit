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
        /// empty; one that exists but cannot be read is an error — thrown
        /// before the body runs, or by an open that finds it so later (git
        /// skips an unreadable search-path file; a level the host named is
        /// not skipped). The file is read by each open; its includes go through
        /// the include policy in force. Repository-only settings in it or
        /// its includes are skipped.
        case file(URL, ConfigLevel)
        /// `entries`, in order, as an in-memory `level`; `name` is the
        /// backend type reported for them (`git_config_entry.backend_type`).
        /// An `include.path` among them is stored, not followed; to read the
        /// file in its place, as git's `-c include.path=<file>` does, use
        /// ``OperationConfiguration/layers``.
        case entries([ConfigEntry], ConfigLevel = .app, name: String = "command line")
    }

    /// The levels, applied in order; a later level replaces an earlier one
    /// of the same ``ConfigLevel``.
    public var levels: [Level]

    /// The ``ConfigLevel/app`` level as ordered command-line layers, git's
    /// `-c a=1 -c include.path=<file> -c b=2`: layer `i` is read at
    /// `GIT_CONFIG_LEVEL_APP + i`, so a later layer wins a single read over
    /// an earlier one. A file layer is read as a ``Level/file(_:_:)`` level
    /// is (missing: empty; unreadable: an error; its includes through the
    /// include policy in force, its repository-only settings skipped); an
    /// entries layer as an ``Level/entries(_:_:name:)`` level.
    ///
    /// `nil` names no command-line layers: the `.app` level of ``levels``,
    /// if any, or else an outer call's command-line set is in force. `[]`
    /// leaves no command-line config. Layers are the whole `.app` level, so
    /// a configuration with both layers and an `.app` level in ``levels`` is
    /// refused before the operation runs.
    public var layers: [ConfigLayer]?

    /// Conditional command-line elements, evaluated per opened repository.
    /// Mutually exclusive with `layers` and an `.app` level. A nil value
    /// inherits the outer operation's command-line set.
    public var commandLine: CommandLineConfig?

    /// Ordered nonfatal diagnostics from all opens, including internal ones.
    /// Delivered once after the body returns or throws, on its calling thread.
    /// Diagnostics for an inherited command-line set go to the scope that
    /// supplied it, even inside a nested scope with its own handler. Refreshes
    /// after the owning scope ends never report into a later unrelated scope.
    public var onDiagnostic: (@Sendable ([ConfigDiagnostic]) -> Void)?

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

    /// A configuration with command-line `layers` above `levels`, which
    /// then name no ``ConfigLevel/app`` level.
    public init(levels: [Level] = [], layers: [ConfigLayer]?, includePolicy: ConfigIncludePolicy? = nil) {
        self.levels = levels
        self.layers = layers
        self.includePolicy = includePolicy
    }

    /// A required-label overload preserves both existing initializer signatures.
    public init(
        levels: [Level] = [], commandLine: CommandLineConfig?, includePolicy: ConfigIncludePolicy? = nil,
        onDiagnostic: (@Sendable ([ConfigDiagnostic]) -> Void)? = nil
    ) {
        self.levels = levels
        self.commandLine = commandLine
        self.includePolicy = includePolicy
        self.onDiagnostic = onDiagnostic
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
    /// when `configuration` has none; an inner `.app` level or
    /// ``OperationConfiguration/layers`` replaces the outer
    /// call's whole command-line set. Nothing global changes: no environment
    /// variable, search path or config file is written; the levels are
    /// copied, so nothing the caller holds is lent to libgit2.
    ///
    /// It applies to opens only. A `Repository` opened before keeps the
    /// config it has; add the levels to it with
    /// ``addConfigFile(at:level:)`` / ``addConfigEntries(_:level:name:)`` /
    /// ``addConfigLayers(_:)``.
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
    /// - Throws: before `body` runs, `GIT_EINVALIDSPEC` for a configuration
    ///   with both ``OperationConfiguration/layers`` and an `.app` level, an
    ///   entry that
    ///   is not a valid config entry or names a setting git reads from the
    ///   repository's own config only — `core.repositoryformatversion`,
    ///   `core.bare`, `core.worktree`, `extensions.*` — or the error reading
    ///   a level's file that exists but cannot be read; a recorded failure;
    ///   or what `body` throws.
    public static func withOperationConfiguration<T>(
        _ configuration: OperationConfiguration, _ body: () throws -> T
    ) throws -> T {
        Libgit2.ensureInitialized()
        let scope = try OperationConfigurationScope(configuration)

        let restoreThreadPolicy = configuration.includePolicy
            .map(ConfigIncludePolicyBox.init)?.setForCurrentThread()
        defer { restoreThreadPolicy?() }

        try check(gitkit_config_scope_push(scope.pointer))
        defer {
            let diagnostics = scope.diagnostics()
            if !diagnostics.isEmpty { configuration.onDiagnostic?(diagnostics) }
        }
        let result: T
        do {
            defer { scope.pop() }
            result = try body()
        }
        if let failure = scope.firstFailure() { throw failure }
        return result
    }
}

extension OperationConfiguration.Level {
    var configLevel: ConfigLevel {
        switch self {
        case let .file(_, level), let .entries(_, level, _): level
        }
    }
}

/// Owns the C scope of one ``Repository/withOperationConfiguration(_:_:)``.
final class OperationConfigurationScope {
    let pointer: OpaquePointer

    private init() throws {
        var scope: OpaquePointer?
        try check(gitkit_config_scope_new(&scope))
        guard let scope else {
            throw Libgit2Error(code: -1, klass: 0, message: "gitkit_config_scope_new returned no scope")
        }
        pointer = scope
    }

    /// Direct installs store all valid entries. Repository-opening restrictions
    /// belong to the operation configuration initializer alone.
    convenience init(commandLine: CommandLineConfig) throws {
        try self.init()
        try commandLine.add(to: pointer)
    }

    convenience init(_ configuration: OperationConfiguration) throws {
        // Layers are the whole .app level: both would leave one unread.
        if configuration.layers != nil && configuration.commandLine != nil {
            throw ConfigEntryText.invalid("an operation configuration has both layers and commandLine")
        }
        if configuration.layers != nil || configuration.commandLine != nil,
           configuration.levels.contains(where: { $0.configLevel == .app }) {
            throw ConfigEntryText.invalid("an operation configuration has both command-line layers and an .app level")
        }

        try self.init()

        for item in configuration.levels {
            switch item {
            case let .file(url, level):
                try check(gitkit_config_scope_add_file(pointer, level.libgit2, url.path))
            case let .entries(entries, level, name):
                let text = try Self.entriesText(entries, name: name)
                try check(gitkit_config_scope_add_entries(
                    pointer, level.libgit2, text, text.utf8.count, name))
            }
        }

        if let commandLine = configuration.commandLine {
            // Reuse the operation's existing repository-only entry checks.
            for element in commandLine.elements {
                if case let .entries(entries, _) = element.storage { try Self.rejectRepositoryOnly(entries) }
            }
            try commandLine.add(to: pointer)
            return
        }
        guard let layers = configuration.layers else { return }
        try check(gitkit_config_scope_reset_layers(pointer))
        for layer in layers {
            switch layer {
            case let .entries(entries, name):
                let text = try Self.entriesText(entries, name: name)
                try check(gitkit_config_scope_add_layer_entries(
                    pointer, text, text.utf8.count, name))
            case let .file(url):
                guard url.isFileURL else {
                    throw ConfigEntryText.invalid("config layer '\(url.absoluteString)' is not a file URL")
                }
                try check(gitkit_config_scope_add_layer_file(pointer, url.path))
            }
        }
    }

    private static func entriesText(_ entries: [ConfigEntry], name: String) throws -> String {
        try rejectRepositoryOnly(entries)
        let text = try ConfigEntryText.serialize(entries)
        try ConfigEntryText.checkBackendName(name)
        return text
    }

    deinit {
        gitkit_config_scope_free(pointer)
    }

    func pop() {
        // Pushed on this thread by the caller's frame, so innermost.
        let rc = gitkit_config_scope_pop(pointer)
        precondition(rc == 0, "operation configuration scope popped out of order")
    }

    /// The first failure not handed back, typed when it is an include-depth
    /// failure: the scope keeps each one's paths, as later ones replace the
    /// thread's record.
    func firstFailure() -> Error? {
        var code: Int32 = 0
        var klass: Int32 = 0
        var message: UnsafePointer<CChar>?
        guard gitkit_config_scope_first_failure(pointer, &code, &klass, &message) == 1 else { return nil }
        var limit: Int32 = 0
        var included: UnsafePointer<CChar>?
        var including: UnsafePointer<CChar>?
        if gitkit_config_scope_first_failure_include_depth(pointer, &limit, &included, &including) == 1,
           let included, let including {
            return ConfigIncludeDepthError(limit: Int(limit), includedPath: String(cString: included),
                                           includingPath: String(cString: including))
        }
        return Libgit2Error(code: code, klass: klass, message: message.map { String(cString: $0) } ?? "unknown error")
    }

    func diagnostics() -> [ConfigDiagnostic] {
        (0..<gitkit_config_scope_diagnostic_count(pointer)).map { index in
            var condition: UnsafePointer<CChar>?
            var gitdir: UnsafePointer<CChar>?
            gitkit_config_scope_diagnostic(pointer, index, &condition, &gitdir)
            return ConfigDiagnostic(
                message: "relative config include conditionals must come from files",
                condition: condition.map { String(cString: $0) } ?? "",
                gitDirectory: gitdir.map { URL(fileURLWithPath: String(cString: $0), isDirectory: true) })
        }
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

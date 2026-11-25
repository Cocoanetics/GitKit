import Foundation
import CGitKit

/// Git's ordered command-line configuration, evaluated for each handle that
/// reads it. Conditions are raw `gitdir:`, `gitdir/i:`, `onbranch:` or
/// `hasconfig:remote.*.url:` strings. Unknown conditions never match.
///
/// Supply paths after invocation-specific interpolation (`~user`, `%(prefix)`).
/// A target the host could not interpolate is passed raw as `unexpandedPath`,
/// and a valueless one as a nil `path`. Like a relative target, each fails only
/// when its condition matches, with Git's "could not expand include path" or
/// "missing value for 'include.path'"; the plain `include` forms always fail.
/// When the condition does not match, the element is inert. A relative
/// `gitdir:./` command condition matches in a repository and produces a nonfatal
/// diagnostic, as Git does; outside a repository it is false without a diagnostic.
public struct CommandLineConfig: Sendable, Hashable {
    /// Opaque elements keep future additions source compatible with clients.
    public struct Element: Sendable, Hashable {
        let storage: Storage

        /// Entries are stored in order; include directives among them remain
        /// inert. Use the include factories to follow a directive in its place.
        public static func entries(_ entries: [ConfigEntry], name: String = "command line") -> Self {
            Self(storage: .entries(entries, name))
        }

        public static func include(path: String) -> Self { Self(storage: .include(.path(path))) }

        /// A nil path is a valueless `include.path`.
        public static func include(path: String?) -> Self { Self(storage: .include(Target(path))) }

        /// A target whose interpolation failed, kept raw for Git's error.
        public static func include(unexpandedPath: String) -> Self {
            Self(storage: .include(.unexpanded(unexpandedPath)))
        }

        public static func includeIf(condition: String, path: String) -> Self {
            Self(storage: .includeIf(condition, .path(path)))
        }

        /// A nil path is a valueless `includeIf.<condition>.path`.
        public static func includeIf(condition: String, path: String?) -> Self {
            Self(storage: .includeIf(condition, Target(path)))
        }

        /// A target whose interpolation failed, kept raw for Git's error.
        public static func includeIf(condition: String, unexpandedPath: String) -> Self {
            Self(storage: .includeIf(condition, .unexpanded(unexpandedPath)))
        }
    }

    enum Storage: Sendable, Hashable {
        case entries([ConfigEntry], String)
        case include(Target)
        case includeIf(String, Target)
    }

    enum Target: Sendable, Hashable {
        case path(String)
        case missing
        case unexpanded(String)

        init(_ path: String?) { self = path.map(Target.path) ?? .missing }

        /// The shim reads this variable as `path` that fails expansion
        /// (GITKIT_UNEXPANDED_PATH in gitkit_config_condition.h).
        func entry(section: String) -> ConfigEntry {
            switch self {
            case let .path(path): ConfigEntry(name: section + ".path", value: path)
            case .missing: ConfigEntry(name: section + ".path", value: nil)
            case let .unexpanded(path): ConfigEntry(name: section + ".gitkit-unexpanded-path", value: path)
            }
        }
    }

    public var elements: [Element]
    public init(_ elements: [Element]) { self.elements = elements }

    /// Atomically installs into a caller-owned live `git_config *`, including
    /// repository-less `git_config_open_default` / `git_config_new` handles.
    /// Lower files are re-read against the complete prospective source list,
    /// so file-level hasconfig can see later command-line URLs. Their write
    /// order is preserved; command elements are never write targets.
    /// All valid entries remain stored, including repository-layout settings;
    /// operation scopes alone reject those before opening repositories.
    ///
    /// The handles are borrowed. As with ``ConfigLayer/install(_:into:repository:)``,
    /// the repository must outlive the config and all its file backends, and the
    /// caller serializes reads, writes and installation. A nil repository makes
    /// gitdir/onbranch false in the new command elements; hasconfig still evaluates.
    /// Lower file backends keep their own repository context and include policy,
    /// including during URL collection and later refreshes. Repository caches are
    /// the host's responsibility. For a typed handle use
    /// ``Repository/setCommandLineConfig(_:)``.
    ///
    /// Every followed include is authorized before access. The hasconfig URL
    /// pre-scan also authorizes and reads nonmatching hasconfig targets and
    /// rejects remote URLs in any conditional target it follows, as Git does.
    @discardableResult
    public func install(into config: OpaquePointer, repository: OpaquePointer? = nil) throws -> [ConfigDiagnostic] {
        Libgit2.ensureInitialized()
        let scope = try OperationConfigurationScope(commandLine: self)
        try check(gitkit_config_scope_install(scope.pointer, config, repository))
        return scope.diagnostics()
    }

    func add(to scope: OpaquePointer) throws {
        try check(gitkit_config_scope_reset_layers(scope))
        for element in elements {
            switch element.storage {
            case let .entries(entries, name):
                let text = try ConfigEntryText.serialize(entries)
                try ConfigEntryText.checkBackendName(name)
                try check(gitkit_config_scope_add_layer_entries(scope, text, text.utf8.count, name))
            case let .include(target):
                try Self.addDirective(target.entry(section: "include"), to: scope)
            case let .includeIf(condition, target):
                try Self.addDirective(target.entry(section: "includeif.\(condition)"), to: scope)
            }
        }
    }

    private static func addDirective(_ entry: ConfigEntry, to scope: OpaquePointer) throws {
        let text = try ConfigEntryText.serialize([entry])
        try check(gitkit_config_scope_add_layer_command(scope, text, text.utf8.count))
    }
}

/// A nonfatal Git diagnostic. GitKit never prints it to stderr.
public struct ConfigDiagnostic: Sendable, Hashable {
    public let message: String
    public let condition: String
    public let gitDirectory: URL?
}

extension Repository {
    /// Replaces the whole command-line set atomically and refreshes repository
    /// caches. Writes keep going to LOCAL; a failed include leaves the previous
    /// config in force. Decisions use this repository's git directory and HEAD.
    @discardableResult
    public func setCommandLineConfig(_ configuration: CommandLineConfig) throws -> [ConfigDiagnostic] {
        var config: OpaquePointer?
        try check(git_repository_config(&config, repo))
        defer { git_config_free(config) }
        guard let config else { throw ConfigEntryText.invalid("no repository config") }
        let diagnostics = try configuration.install(into: config, repository: repo)
        var local = GIT_CONFIG_LEVEL_LOCAL
        try check(git_config_set_writeorder(config, &local, 1))
        addedConfigLevels.insert(.app)
        try check(gitkit_repository_config_changed(repo))
        try check(git_attr_cache_flush(repo))
        return diagnostics
    }
}

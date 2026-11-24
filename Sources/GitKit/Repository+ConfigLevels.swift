import Foundation
import CGitKit

/// A configuration level a host gives one open repository for an operation
/// (``Repository/addConfigFile(at:level:)``,
/// ``Repository/addConfigEntries(_:level:name:)``). Reads give a higher
/// level precedence: app over the repository's worktree and local files,
/// over global, over XDG, over system.
public enum ConfigLevel: Sendable, Hashable {
    /// Where libgit2 reads `/etc/gitconfig` (`GIT_CONFIG_SYSTEM`).
    case system
    /// Where libgit2 reads `$XDG_CONFIG_HOME/git/config`. git reads no XDG
    /// file when `GIT_CONFIG_GLOBAL` is set; a host following that replaces
    /// this level too, with an empty entry list.
    case xdg
    /// Where libgit2 reads `~/.gitconfig` (`GIT_CONFIG_GLOBAL`). Replacing it
    /// leaves ``xdg``, a level of its own, in place.
    case global
    /// Above every file, as git's `-c` / `GIT_CONFIG_COUNT` entries: the
    /// whole command-line config, which ``ConfigLayer``s may split into
    /// ordered layers (entries, an included file, later entries).
    case app

    var libgit2: git_config_level_t {
        switch self {
        case .system: GIT_CONFIG_LEVEL_SYSTEM
        case .xdg: GIT_CONFIG_LEVEL_XDG
        case .global: GIT_CONFIG_LEVEL_GLOBAL
        case .app: GIT_CONFIG_LEVEL_APP
        }
    }
}

/// One entry of an in-memory configuration level.
public struct ConfigEntry: Sendable, Hashable {
    /// `section.variable` or `section.subsection.variable`. Section and
    /// variable are case-insensitive (read back lowercased); the subsection
    /// is kept exactly, `=`, `.` and case included.
    public let name: String
    /// `nil` for a valueless entry (`[core] bare`, which reads as boolean
    /// true), distinct from `""`, an empty value (boolean false).
    public let value: String?

    public init(name: String, value: String?) {
        self.name = name
        self.value = value
    }
}

/// One layer of git's command-line config, in `-c` order
/// (``Repository/addConfigLayers(_:)``,
/// ``OperationConfiguration/layers``).
///
/// `git -c a=1 -c include.path=<file> -c b=2` reads as three layers:
/// `.entries([a=1, include.path=<file>])`, `.file(<file>)`,
/// `.entries([b=2])`. The host resolves the include's path (`~`, relative
/// paths) and keeps `include.path` among the entries, where
/// `git config --list` shows it; GitKit reads the layers it is given and
/// follows no `include.path` of an entries layer itself.
/// Use ``CommandLineConfig`` for command-line conditional includes. File
/// layers support `hasconfig:remote.*.url:` against the complete prospective
/// configuration, including later layers; entries layers remain inert.
///
/// For a libgit2 config GitKit does not own (a repository the host opened
/// with `git_repository_open_ext`, `git_config_open_default`), see
/// ``install(_:into:repository:)``.
public enum ConfigLayer: Sendable, Hashable {
    /// `entries`, in order, read-only; `name` is the backend type reported
    /// for them (`git_config_entry.backend_type`).
    case entries([ConfigEntry], name: String = "command line")
    /// The config file at the `file:` URL, as git reads an
    /// `-c include.path=<file>`: a missing file reads as empty, one that
    /// exists but cannot be read is an error. Its entries report the file as
    /// their origin (`origin_path`, backend type `"file"`), and its own
    /// `[include]` / `[includeIf]` go through the include policy; the file
    /// itself is not offered to the policy.
    case file(URL)
}

extension Repository {

    /// Reads the config file at `url` as `level` of this repository's
    /// config, replacing whatever that level held (the user's or system file
    /// the open read, or an earlier add). A missing file reads as empty.
    /// ``ConfigLevel/app`` is the whole command-line config: adding it also
    /// removes the layers ``addConfigLayers(_:)`` added.
    ///
    /// The file is read now, with this repository as the context of its
    /// `[include]` and `[includeIf]` entries; its includes go through the
    /// repository's ``ConfigIncludePolicy``. The file itself is not offered
    /// to the policy: authorising it is the caller's decision.
    ///
    /// Merged-config writes (`configSet(_:_:scope:)` with `.local`,
    /// `addRemote`, a clone's `remote.origin.*`) keep going to the
    /// repository's own config file. An explicit `.system` scope reads and
    /// writes the file added at ``ConfigLevel/system``; once a
    /// ``ConfigLevel/global`` level was added, an explicit `.global` scope
    /// reads and writes that file and no longer the XDG one, as
    /// `git config --global` does with `GIT_CONFIG_GLOBAL`.
    ///
    /// The level belongs to this `Repository` only: another open of the same
    /// path, a submodule or a worktree's repository does not see it. These are
    /// derived again from the new config: the cached `core.*` values,
    /// attribute and ignore files, a loaded index's `core.ignorecase` /
    /// `core.filemode` / `core.symlinks`, and diff drivers. Only these: any
    /// other copy libgit2 keeps is not refreshed, for example the settings
    /// read at open (`core.bare`, `core.worktree`, extensions) and those the
    /// reference and object databases keep once loaded (their
    /// `core.ignorecase`, `core.precomposeUnicode`,
    /// `core.fsyncObjectFiles`). A level meant to change those is added
    /// before the repository uses them, as from a clone's preparation.
    /// Unlike an ``OperationConfiguration`` level, a level added here does
    /// not hide `core.bare`, `core.worktree`, `core.repositoryformatversion`
    /// or `extensions.*`; the open read them already.
    ///
    /// Throws, leaving the config as it was, when the path is not a readable
    /// config file, it does not parse or the include policy refuses one of
    /// its includes.
    public func addConfigFile(at url: URL, level: ConfigLevel) throws {
        try withLiveConfig(level) { config, at in
            try ConfigBackends.addFile(url, to: config, at: at, repository: repo)
        }
    }

    /// Adds `entries`, in order, as a read-only in-memory `level` of this
    /// repository's config, replacing whatever that level held. Repeated
    /// names are kept in order: a single read returns the last one,
    /// multivar reads and ``configEntries()`` return them all
    /// (``configList()`` leaves out valueless ones).
    ///
    /// `name` is the backend type reported for these entries
    /// (`git_config_entry.backend_type`), for example `"command line"`.
    /// An `include.path` among the entries is stored, not followed; to read
    /// the file in its place, as git's `-c include.path=<file>` does, add
    /// the entries and the file as layers with ``addConfigLayers(_:)``.
    ///
    /// Writes, scope and lifetime are as for ``addConfigFile(at:level:)``;
    /// the level itself is never written to.
    ///
    /// Throws `GIT_EINVALIDSPEC`, leaving the config as it was, when an
    /// entry's name is not a valid config name or a name or value contains
    /// a NUL character.
    public func addConfigEntries(
        _ entries: [ConfigEntry], level: ConfigLevel = .app, name: String = "in-memory"
    ) throws {
        let text = try ConfigEntryText.serialize(entries)
        try ConfigEntryText.checkBackendName(name)
        try withLiveConfig(level) { config, at in
            try ConfigBackends.addEntries(text, name: name, to: config, at: at, repository: repo)
        }
    }

    /// Replaces this repository's command-line config (``ConfigLevel/app``
    /// and any layers added before) with `layers`, read in order: layer `i`
    /// is level `GIT_CONFIG_LEVEL_APP + i`, so a later layer wins a single
    /// read over an earlier one, and each wins over the repository's own and
    /// the user's files. Multivar reads and ``configEntries()`` see the
    /// layers' entries in order. One layer is the same as
    /// ``addConfigEntries(_:level:name:)`` / ``addConfigFile(at:level:)`` at
    /// ``ConfigLevel/app``; no layers leave no command-line config.
    ///
    /// Every layer is read before any replaces the current set — each file
    /// with this repository as the context of its includes, which go through
    /// the repository's ``ConfigIncludePolicy`` — and the derived state is
    /// refreshed once, as for ``addConfigFile(at:level:)``. Writes, scope and
    /// lifetime are as there too: a layer file is never written to, even
    /// though it is a file.
    ///
    /// Throws, leaving the config as it was: `GIT_EINVALIDSPEC` for an
    /// entry that is not a valid config entry or a URL that is not a `file:`
    /// URL; the error reading a layer's file that exists but cannot be read
    /// or does not parse; or the include policy's refusal of one of its
    /// includes.
    ///
    /// See also ``ConfigLayer/install(_:into:repository:)``, for a libgit2
    /// config GitKit does not own.
    public func addConfigLayers(_ layers: [ConfigLayer]) throws {
        let staged = try layers.map(ConfigBackends.StagedLayer.init)
        try withLiveConfig(.app, prospective: true) { config, _ in
            try ConfigBackends.install(staged, into: config, repository: repo)
        }
    }

    /// Runs `add` for `level`, then restores what an added level disturbs:
    /// libgit2 makes a new level the merged config's write target and keeps
    /// serving what it derived from the config before the add.
    ///
    /// ``ConfigLevel/app`` is the whole command-line set: `add` fills a
    /// staging config, which replaces every level from `GIT_CONFIG_LEVEL_APP`
    /// up only once all of it was read. Another level is added to the live
    /// config directly, replacing that level alone.
    private func withLiveConfig(
        _ level: ConfigLevel, prospective: Bool = false, _ add: (OpaquePointer, git_config_level_t) throws -> Void
    ) throws {
        var config: OpaquePointer?
        try check(git_repository_config(&config, repo))
        defer { git_config_free(config) }
        guard let config else {
            throw Libgit2Error(code: -1, klass: 0, message: "git_repository_config returned no config")
        }

        if level == .app && !prospective {
            let staged = try ConfigBackends.newConfig()
            defer { git_config_free(staged) }
            try add(staged, level.libgit2)
            try check(gitkit_config_replace_levels_from(config, staged, level.libgit2))
        } else {
            try add(config, level.libgit2)
        }

        // As the open left it (load_config): only the local file is written.
        var local = GIT_CONFIG_LEVEL_LOCAL
        try check(git_config_set_writeorder(config, &local, 1))
        addedConfigLevels.insert(level)
        try check(gitkit_repository_config_changed(repo))
        // core.attributesFile / core.excludesFile are read when the attribute
        // cache is built; the next use rebuilds it from the new config.
        try check(git_attr_cache_flush(repo))
    }
}

extension ConfigLayer {

    /// Replaces the command-line config of a libgit2 config the caller owns
    /// — every level from `GIT_CONFIG_LEVEL_APP` up — with `layers`, read in
    /// order as ``Repository/addConfigLayers(_:)`` reads them: layer `i` is
    /// level `GIT_CONFIG_LEVEL_APP + i`, a later layer wins a single read,
    /// and no layers leave no command-line config. Levels below the
    /// command-line config (a repository's local and worktree files, the
    /// global, XDG and system files) are left as they are.
    ///
    /// This is for configs GitKit does not own, which a host opened with the
    /// libgit2 C API GitKit re-exports: `git_repository_config` of a
    /// repository from `git_repository_open_ext`, `git_config_open_default`
    /// outside any repository, or `git_config_new`. For a ``Repository`` use
    /// ``Repository/addConfigLayers(_:)``, which also refreshes what the
    /// repository derived from its config.
    ///
    /// - Parameters:
    ///   - layers: The command-line config, in `-c` order.
    ///   - config: The `git_config *` to change: the live config, not a
    ///     `git_config_snapshot`. A snapshot taken before the call does not
    ///     see the layers; one taken after keeps them.
    ///   - repository: The `git_repository *` that is the context of a layer
    ///     file's `[include]` and `[includeIf]` (`gitdir:`, `onbranch:`).
    ///     With `nil`, conditions that need a repository never match, as
    ///     git behaves outside a repository.
    ///
    /// **Ownership and lifetime.** The caller keeps both pointers: GitKit
    /// retains, wraps, registers and frees neither, and keys no include
    /// policy by them. libgit2's file backend keeps `repository`, though: a
    /// later read of `config` re-reads a layer file (or a file it includes)
    /// that changed on disk, with `repository` as its context. So
    /// `repository` must outlive every file layer installed with it — free
    /// `config` before `repository`. Snapshots of `config` keep no
    /// repository. `config` must not be used on another thread during the
    /// call.
    ///
    /// **Writes.** The layers are never write targets, even a file layer,
    /// and the write order of the config's other levels is unchanged: a
    /// repository's config keeps writing to its own file, the default
    /// config to the global file.
    ///
    /// **Include policy.** Every read of a layer file's includes — this
    /// call's and each later re-read — asks the policy in force for that
    /// read: one a host registered for `repository` with the C
    /// `gitkit_config_set_include_policy`, otherwise the reading thread's
    /// (``Repository/withOperationConfiguration(_:_:)`` with
    /// ``OperationConfiguration/includePolicy``), otherwise the process
    /// default (``ConfigIncludePolicy/setDefault(_:)``). A policy that must
    /// govern later re-reads has to be in force for them too; wrapping only
    /// this call covers only the reads it does. The layer file itself is not
    /// offered to the policy.
    ///
    /// **Not refreshed.** Nothing derived from the config is refreshed: a
    /// repository's cached `core.*` values, a loaded index's capabilities,
    /// diff drivers, the attribute cache. Install the layers before the
    /// repository uses them.
    ///
    /// Entries git reads from the repository's own config only
    /// (`core.bare`, `core.worktree`, `core.repositoryformatversion`,
    /// `extensions.*`) are stored and listed, as git lists them for
    /// `git -c core.bare=false config --list --show-origin`. Layers already
    /// at those levels are replaced, including those an
    /// ``OperationConfiguration`` scope added at the open.
    ///
    /// Throws, leaving `config` as it was: `GIT_EINVALIDSPEC` for an entry
    /// that is not a valid config entry or a URL that is not a `file:` URL;
    /// the error reading a layer's file that exists but cannot be read or
    /// does not parse; or the include policy's refusal of one of its
    /// includes. A missing layer file reads as empty.
    public static func install(
        _ layers: [ConfigLayer], into config: OpaquePointer, repository: OpaquePointer? = nil
    ) throws {
        Libgit2.ensureInitialized()
        let staged = try layers.map(ConfigBackends.StagedLayer.init)
        try ConfigBackends.install(staged, into: config, repository: repository)
    }

    /// The libgit2 level of the layer at `index`.
    static func level(_ index: Int) -> git_config_level_t {
        git_config_level_t(rawValue: GIT_CONFIG_LEVEL_APP.rawValue + numericCast(index))
    }
}

/// Adds config levels to a libgit2 config, a ``Repository``'s or one a host
/// owns, with `repository` as the context of a file's includes.
enum ConfigBackends {

    static func install(_ layers: [StagedLayer], into config: OpaquePointer, repository: OpaquePointer?) throws {
        var scope: OpaquePointer?
        try check(gitkit_config_scope_new(&scope))
        guard let scope else { throw ConfigEntryText.invalid("no config scope") }
        defer { gitkit_config_scope_free(scope) }
        try check(gitkit_config_scope_reset_layers(scope))
        for layer in layers {
            switch layer {
            case let .entries(text, name):
                try check(gitkit_config_scope_add_layer_entries(scope, text, text.utf8.count, name))
            case let .file(url):
                try check(gitkit_config_scope_add_layer_file(scope, url.path))
            }
        }
        try check(gitkit_config_scope_install(scope, config, repository))
    }

    /// A layer whose entries were checked and serialized already.
    enum StagedLayer {
        case entries(String, name: String)
        case file(URL)

        init(_ layer: ConfigLayer) throws {
            switch layer {
            case let .entries(entries, name):
                let text = try ConfigEntryText.serialize(entries)
                try ConfigEntryText.checkBackendName(name)
                self = .entries(text, name: name)
            case let .file(url):
                guard url.isFileURL else {
                    throw ConfigEntryText.invalid("config layer '\(url.absoluteString)' is not a file URL")
                }
                self = .file(url)
            }
        }
    }

    /// An empty config, freed by the caller.
    static func newConfig() throws -> OpaquePointer {
        var config: OpaquePointer?
        try check(git_config_new(&config))
        guard let config else {
            throw Libgit2Error(code: -1, klass: 0, message: "git_config_new returned no config")
        }
        return config
    }

    /// Adds `staged` to `config`, layer `i` at ``ConfigLayer/level(_:)``.
    static func add(_ staged: [StagedLayer], to config: OpaquePointer, repository: OpaquePointer?) throws {
        for (index, layer) in staged.enumerated() {
            let at = ConfigLayer.level(index)
            switch layer {
            case let .entries(text, name):
                try addEntries(text, name: name, to: config, at: at, repository: repository)
            case let .file(url):
                try addFile(url, to: config, at: at, repository: repository)
            }
        }
    }

    static func addFile(
        _ url: URL, to config: OpaquePointer, at level: git_config_level_t, repository: OpaquePointer?
    ) throws {
        let path = url.path
        // libgit2 reads a file it may not read as missing, with no error.
        try check(gitkit_config_file_check_readable(path))
        let rc = git_config_add_file_ondisk(config, path, level, repository, 1)
        if rc == GIT_ENOTFOUND.rawValue {
            throw Libgit2Error(
                code: rc, klass: Int32(GIT_ERROR_CONFIG.rawValue),
                message: "config file '\(path)' could not be read")
        }
        try check(rc)
    }

    static func addEntries(
        _ text: String, name: String, to config: OpaquePointer, at level: git_config_level_t,
        repository: OpaquePointer?
    ) throws {
        var backend: UnsafeMutablePointer<git_config_backend>?
        try text.withCString { cText in
            try name.withCString { type in
                var options = git_config_backend_memory_options()
                options.version = UInt32(GIT_CONFIG_BACKEND_MEMORY_OPTIONS_VERSION)
                options.backend_type = type
                try check(git_config_backend_from_string(&backend, cText, text.utf8.count, &options))
            }
        }
        guard let backend else {
            throw Libgit2Error(code: -1, klass: 0, message: "git_config_backend_from_string returned no backend")
        }
        let rc = git_config_add_backend(config, backend, level, repository, 1)
        if rc < 0 {
            // Not yet owned by the config, so not freed with it.
            let error = Libgit2Error.last(code: rc)
            backend.pointee.free(backend)
            throw error
        }
    }
}

/// The config-file text of a list of entries, which libgit2's in-memory
/// backend parses back into exactly those entries: one section header per
/// entry keeps their order, a valueless entry is a bare name, and every value
/// is quoted with the escapes git's parser undoes.
enum ConfigEntryText {

    static func serialize(_ entries: [ConfigEntry]) throws -> String {
        var text = ""
        for entry in entries {
            let (section, subsection, variable) = try split(entry.name)
            text += "[" + section
            if let subsection {
                text += " \"" + escape(subsection, quoting: false) + "\""
            }
            text += "]\n\t" + variable
            if let value = entry.value {
                guard !value.utf8.contains(0) else {
                    throw invalid("value of '\(entry.name)' contains a NUL character")
                }
                text += " = \"" + escape(value, quoting: true) + "\""
            }
            text += "\n"
        }
        return text
    }

    /// libgit2's name rules (`git_config__normalize_name`), which every
    /// lookup applies: section and variable are ASCII letters, digits and
    /// `-` (not first); the subsection, everything between the first and the
    /// last dot, holds anything but a newline.
    private static func split(_ name: String) throws -> (String, String?, String) {
        let bytes = Array(name.utf8)
        guard !bytes.contains(0),
              let first = bytes.firstIndex(of: UInt8(ascii: ".")),
              let last = bytes.lastIndex(of: UInt8(ascii: ".")),
              isKey(bytes[..<first]), isKey(bytes[(last + 1)...]) else {
            throw invalid("invalid config item name '\(name)'")
        }
        let section = String(decoding: bytes[..<first], as: UTF8.self)
        let variable = String(decoding: bytes[(last + 1)...], as: UTF8.self)
        guard first < last else { return (section, nil, variable) }
        let subsection = bytes[(first + 1)..<last]
        guard !subsection.contains(UInt8(ascii: "\n")) else {
            throw invalid("invalid config item name '\(name)'")
        }
        return (section, String(decoding: subsection, as: UTF8.self), variable)
    }

    private static func isKey(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard let head = bytes.first, head != UInt8(ascii: "-") else { return false }
        return bytes.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"): true
            default: false
            }
        }
    }

    /// In a quoted subsection a backslash takes the next character
    /// literally; in a value git's parser knows `\\`, `\"`, `\n`, `\t` and
    /// `\b`, and drops any unescaped quote.
    private static func escape(_ string: String, quoting value: Bool) -> String {
        var out = ""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n" where value: out += "\\n"
            case "\t" where value: out += "\\t"
            case "\u{08}" where value: out += "\\b"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    static func checkBackendName(_ name: String) throws {
        guard !name.utf8.contains(0) else {
            throw invalid("backend name contains a NUL character")
        }
    }

    static func invalid(_ message: String) -> Libgit2Error {
        Libgit2Error(code: GIT_EINVALIDSPEC.rawValue, klass: Int32(GIT_ERROR_CONFIG.rawValue), message: message)
    }
}

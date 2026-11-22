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
    /// Above every file, as git's `-c` / `GIT_CONFIG_COUNT` entries.
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

extension Repository {

    /// Reads the config file at `url` as `level` of this repository's
    /// config, replacing whatever that level held (the user's or system file
    /// the open read, or an earlier add). A missing file reads as empty.
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
    /// path, a submodule or a worktree's repository does not see it. What
    /// this repository derived from its config before is derived again: its
    /// `core.*` values, attribute and ignore files, a loaded index's
    /// `core.ignorecase` / `core.filemode` / `core.symlinks` and diff
    /// drivers. Settings libgit2 reads once, at open (`core.bare`,
    /// `core.worktree`, extensions), are not affected.
    ///
    /// Throws, leaving the config as it was, when the path is not a readable
    /// config file, it does not parse or the include policy refuses one of
    /// its includes.
    public func addConfigFile(at url: URL, level: ConfigLevel) throws {
        try withLiveConfig(level) { config in
            try check(git_config_add_file_ondisk(config, url.path, level.libgit2, repo, 1))
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
    /// An `include.path` among the entries is stored, not followed.
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
        guard !name.utf8.contains(0) else {
            throw ConfigEntryText.invalid("backend name contains a NUL character")
        }
        try withLiveConfig(level) { config in
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
            let rc = git_config_add_backend(config, backend, level.libgit2, repo, 1)
            if rc < 0 {
                // Not yet owned by the config, so not freed with it.
                let error = Libgit2Error.last(code: rc)
                backend.pointee.free(backend)
                throw error
            }
        }
    }

    /// Runs `add` on the repository's live config, then restores what an
    /// added level disturbs: libgit2 makes a new level the merged config's
    /// write target and keeps serving what it derived from the config before
    /// the add.
    private func withLiveConfig(_ level: ConfigLevel, _ add: (OpaquePointer) throws -> Void) throws {
        var config: OpaquePointer?
        try check(git_repository_config(&config, repo))
        defer { git_config_free(config) }
        guard let config else {
            throw Libgit2Error(code: -1, klass: 0, message: "git_repository_config returned no config")
        }

        try add(config)

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

    static func invalid(_ message: String) -> Libgit2Error {
        Libgit2Error(code: GIT_EINVALIDSPEC.rawValue, klass: Int32(GIT_ERROR_CONFIG.rawValue), message: message)
    }
}

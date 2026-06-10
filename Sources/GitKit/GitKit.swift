// GitKit — the public Swift face over the bundled libgit2.
//
// `import GitKit` gives you the Swift SDK (`Repository` and friends, see
// Repository.swift and the Repository+*.swift operation files) AND — via
// `@_exported import CGitKit` — the full libgit2 C API
// (`git_repository_open`, `git_clone`, …) for anything the SDK doesn't
// surface yet. The C target and the libgit2 submodule are implementation
// details consumers never reference directly.

@_exported import CGitKit

/// Namespace for GitKit-level helpers and metadata.
public enum GitKit {
    /// The libgit2 version this package was compiled against, e.g. `"1.9.4"`.
    ///
    /// GitKit versions independently of libgit2; each release documents the
    /// libgit2 it vendors — see the README's versioning table.
    public static var libgit2Version: String {
        var major: Int32 = 0
        var minor: Int32 = 0
        var rev: Int32 = 0
        git_libgit2_version(&major, &minor, &rev)
        return "\(major).\(minor).\(rev)"
    }

    /// Initializes the libgit2 runtime. Safe to call repeatedly; returns the
    /// new initialization refcount. Pair each call with ``shutdown()``.
    @discardableResult
    public static func initialize() -> Int32 {
        git_libgit2_init()
    }

    /// Decrements the libgit2 initialization refcount; returns the remaining
    /// count (0 once fully shut down).
    @discardableResult
    public static func shutdown() -> Int32 {
        git_libgit2_shutdown()
    }
}

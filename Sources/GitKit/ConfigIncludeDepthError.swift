import Foundation
import CGitKit

/// A config include chain went deeper than git allows: following an
/// `[include]` or `[includeIf]` would read an eleventh nested file.
///
/// Thrown in place of the ``Libgit2Error`` libgit2 returns for it, whether
/// the config was being read or `hasconfig:remote.*.url:` was collecting
/// URLs. Git 2.54 reports the same case as
///
/// ```
/// fatal: exceeded maximum include depth (10) while including
/// 	<includedPath>
/// from
/// 	<includingPath>
/// This might be due to circular includes.
/// ```
///
/// and exits 128. Git checks that a target exists before it counts depth,
/// and so does GitKit: a missing target is empty, never this error.
public struct ConfigIncludeDepthError: Error, LocalizedError, Sendable, Equatable {
    /// The deepest include git follows: 10.
    public let limit: Int
    /// The file whose include went past ``limit``, resolved as git prints
    /// it (a relative target joined to its includer's directory).
    public let includedPath: String
    /// The file that names ``includedPath``. Git calls a command-line
    /// includer `the command line`; with ``limit`` at 10 the includer is
    /// always a file, so in practice this is a path.
    public let includingPath: String

    /// Memberwise init.
    public init(limit: Int, includedPath: String, includingPath: String) {
        self.limit = limit
        self.includedPath = includedPath
        self.includingPath = includingPath
    }

    /// Git's message without its `fatal: ` prefix.
    public var errorDescription: String? {
        "exceeded maximum include depth (\(limit)) while including\n\t\(includedPath)\nfrom\n\t\(includingPath)\n"
            + "This might be due to circular includes."
    }

    /// The typed error for `error` when it is the calling thread's newest
    /// include-depth failure, which is then forgotten.
    static func take(matching error: Libgit2Error) -> ConfigIncludeDepthError? {
        guard error.klass == Int32(GIT_ERROR_CONFIG.rawValue) else { return nil }
        var limit: Int32 = 0
        var included: UnsafePointer<CChar>?
        var including: UnsafePointer<CChar>?
        var message: UnsafePointer<CChar>?
        guard gitkit_config_include_depth_last(&limit, &included, &including, &message) == 1,
              let included, let including, let message,
              String(cString: message) == error.message else { return nil }
        let typed = ConfigIncludeDepthError(limit: Int(limit), includedPath: String(cString: included),
                                            includingPath: String(cString: including))
        gitkit_config_include_depth_clear()
        return typed
    }
}

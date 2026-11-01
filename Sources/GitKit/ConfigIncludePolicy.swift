import Foundation
import CGitKit

/// One `[include]` / `[includeIf]` file libgit2 is about to read for a
/// config.
public struct ConfigInclude: Sendable, Hashable {
    /// The include file's path, resolved the way libgit2 will open it.
    public let path: String
    /// The path of the config file whose directive named it, when known.
    public let includedFrom: String?
    /// 1 for a file the repository's own config includes, 2 for one that
    /// file includes, and so on.
    public let depth: Int
}

/// Decides which include files a config may read — what a sandbox needs to
/// authorise exactly the files actually read.
///
/// libgit2 asks the policy for every include file before it stats or reads
/// it: a plain `[include]`, an `[includeIf]` whose condition matches, and an
/// include named by an included file. Returning `false` refuses the include
/// and fails the config load that was reading it — a thrown error from the
/// operation, or from ``Repository/open(at:includePolicy:)`` when the include
/// is read while opening — naming the refused path. The policy is asked again
/// whenever the config is read again, e.g. after it changed on disk.
///
/// Policies are per repository, so several sandboxes can run in one process
/// with different rules: pass one to ``Repository/open(at:includePolicy:)``
/// or install it with ``Repository/setIncludePolicy(_:)``. A repository
/// without its own falls back to ``setDefault(_:)``; with neither, includes
/// are read as before.
///
/// The closure runs on whatever thread is reading the config, so it must be
/// thread-safe.
public struct ConfigIncludePolicy: Sendable {
    let authorise: @Sendable (ConfigInclude) -> Bool

    /// - Parameter authorise: `true` to let libgit2 read the include.
    public init(_ authorise: @escaping @Sendable (ConfigInclude) -> Bool) {
        self.authorise = authorise
    }

    /// Sets the policy for repositories (and configs) that have none of
    /// their own; `nil` removes it. Replaces any previous default. Process
    /// global: prefer a per-repository policy when sandboxes coexist.
    public static func setDefault(_ policy: ConfigIncludePolicy?) {
        Libgit2.ensureInitialized()
        defaultLock.lock()
        defer { defaultLock.unlock() }
        guard let policy else {
            gitkit_config_set_include_callback(nil, nil, nil)
            defaultBox = nil
            return
        }
        let box = ConfigIncludePolicyBox(policy)
        gitkit_config_set_include_callback(nil, configIncludeTrampoline, box.payload)
        defaultBox = box
    }

    // Kept alive for as long as it is the registered default.
    nonisolated(unsafe) private static var defaultBox: ConfigIncludePolicyBox?
    private static let defaultLock = NSLock()
}

/// Owns a policy for the C callback's `payload`.
final class ConfigIncludePolicyBox {
    let policy: ConfigIncludePolicy

    init(_ policy: ConfigIncludePolicy) {
        self.policy = policy
    }

    var payload: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    func setForCurrentThread() {
        gitkit_config_set_thread_include_callback(configIncludeTrampoline, payload)
    }
}

private let configIncludeTrampoline: gitkit_config_include_cb = { path, including, depth, payload in
    guard let path, let payload else { return 1 }
    let box = Unmanaged<ConfigIncludePolicyBox>.fromOpaque(payload).takeUnretainedValue()
    let include = ConfigInclude(
        path: String(cString: path),
        includedFrom: including.map { String(cString: $0) },
        depth: Int(depth))
    return box.policy.authorise(include) ? 0 : 1
}

extension Repository {

    /// Sets, or with `nil` removes, the policy authorising the include files
    /// this repository's config reads. Takes effect from the next time the
    /// config is read; to cover the reads while opening, pass the policy to
    /// ``Repository/open(at:includePolicy:)`` instead.
    public func setIncludePolicy(_ policy: ConfigIncludePolicy?) throws {
        guard let policy else {
            try check(gitkit_config_set_include_callback(pointer, nil, nil))
            includePolicyBox = nil
            return
        }
        try register(ConfigIncludePolicyBox(policy))
    }

    func register(_ box: ConfigIncludePolicyBox) throws {
        try check(gitkit_config_set_include_callback(pointer, configIncludeTrampoline, box.payload))
        includePolicyBox = box
    }
}

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
        // Ignoring the status: only an allocation failure can fail it.
        _ = ConfigIncludePolicyBox.register(policy, forRepository: nil)
    }
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

    /// Registers `policy` (or removes the registration for `nil`) with C
    /// owning a reference to the box, which keeps it alive for callbacks
    /// still running when the registration is replaced.
    static func register(_ policy: ConfigIncludePolicy?, forRepository repo: OpaquePointer?) -> Int32 {
        guard let policy else {
            return gitkit_config_set_include_policy(repo, nil, nil, nil, nil)
        }
        let owned = Unmanaged.passRetained(ConfigIncludePolicyBox(policy))
        let status = gitkit_config_set_include_policy(
            repo, configIncludeTrampoline, owned.toOpaque(),
            { Unmanaged<ConfigIncludePolicyBox>.fromOpaque($0!).retain() },
            { Unmanaged<ConfigIncludePolicyBox>.fromOpaque($0!).release() })
        if status != 0 { owned.release() }
        return status
    }

    /// Makes the box the calling thread's policy; returns what restores the
    /// previous one, for a nested open.
    func setForCurrentThread() -> () -> Void {
        var previousCallback: gitkit_config_include_cb?
        var previousPayload: UnsafeMutableRawPointer?
        gitkit_config_set_thread_include_callback(
            configIncludeTrampoline, payload, &previousCallback, &previousPayload)
        // The payload is unretained in C: the closure holds the box, so it
        // lives until the policy is restored.
        return {
            withExtendedLifetime(self) {
                gitkit_config_set_thread_include_callback(previousCallback, previousPayload, nil, nil)
            }
        }
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
        try check(ConfigIncludePolicyBox.register(policy, forRepository: pointer))
        hasIncludePolicy = policy != nil
    }
}

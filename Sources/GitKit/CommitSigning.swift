import Foundation
import CGitKit

/// Per-operation override for `commit.gpgsign` or `tag.gpgsign`.
public enum SignMode: Sendable, Equatable {
    case config
    case sign(keyID: String?)
    case noSign
}

/// Settings passed to a signer. Key interpretation belongs entirely to
/// the signer: GitKit never expands, opens or rewrites `key`.
public struct SigningRequest: Sendable {
    public let format: SigningFormat
    public let key: String?
    public let identity: String
    public let program: String?
    public let defaultKeyCommand: String?
    public let workingDirectory: URL?

    public init(
        format: SigningFormat, key: String?, identity: String,
        program: String? = nil, defaultKeyCommand: String? = nil,
        workingDirectory: URL? = nil
    ) {
        self.format = format
        self.key = key
        self.identity = identity
        self.program = program
        self.defaultKeyCommand = defaultKeyCommand
        self.workingDirectory = workingDirectory
    }
}

/// Produces an armored signature over the exact object bytes. The returned
/// text is opaque; GitKit does not validate its format or cryptography.
///
/// Called synchronously on the operation's calling thread, once per object,
/// before writing the commit object, without GitKit, index or reference
/// locks held — except for an amend, which like git holds `index.lock`
/// until HEAD has moved. A signer may block while bridging to an async
/// host service.
public protocol GitSigner: Sendable {
    func sign(_ payload: [UInt8], request: SigningRequest) throws -> String
}

/// Process defaults for repositories without an installed signer.
/// Swift does not permit static calls on a protocol metatype; use this
/// namespace or the static conveniences on a concrete `GitSigner` type.
public enum GitSigning {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var signer: (any GitSigner)?
    nonisolated(unsafe) private static var externalProgramFallbackEnabled = true

    /// Replace the process default; nil removes it. Prefer per-repository
    /// signers when several sandboxed shells share a process.
    public static func setDefault(_ signer: (any GitSigner)?) {
        lock.lock()
        defer { lock.unlock() }
        self.signer = signer
    }

    /// Disable at host startup to guarantee signing never launches a
    /// Foundation.Process through GitKit's built-in fallback.
    public static func setExternalProgramFallbackEnabled(_ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        externalProgramFallbackEnabled = enabled
    }

    static func defaultSigner() -> (any GitSigner)? {
        lock.lock()
        defer { lock.unlock() }
        if let signer { return signer }
        #if os(macOS) || os(Linux) || os(Windows)
        if externalProgramFallbackEnabled { return ExternalProgramSigner() }
        #endif
        return nil
    }
}

extension GitSigner {
    public static func setDefault(_ signer: (any GitSigner)?) {
        GitSigning.setDefault(signer)
    }

    public static func setExternalProgramFallbackEnabled(_ enabled: Bool) {
        GitSigning.setExternalProgramFallbackEnabled(enabled)
    }
}

public enum SigningError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    case noSigner(SigningFormat)
    case missingKey
    case unsupportedFormat(String)
    case failed(program: String, stderr: String)

    public var description: String {
        switch self {
        case .noSigner(let format):
            return "no signer available for \(format.rawValue)"
        case .missingKey:
            return "either user.signingkey or gpg.ssh.defaultKeyCommand needs to be configured"
        case .unsupportedFormat(let format):
            return "unsupported signing format '\(format)'"
        case .failed(_, let stderr):
            return "gpg failed to sign the data" + (stderr.isEmpty ? "" : "\n" + stderr)
        }
    }

    public var errorDescription: String? { description }
}

/// Resolved once per operation, from the repository's existing config stack.
struct SigningConfig {
    let format: SigningFormat
    let key: String?
    let program: String?
    let defaultKeyCommand: String?

    static func resolve(_ mode: SignMode, repository: Repository, forTag: Bool = false) throws -> SigningConfig? {
        switch mode {
        case .noSign: return nil
        case .sign(let key):
            // Explicit modes must not read any signing config, including
            // an invalid gpg.format or a conflicting user.signingkey.
            return SigningConfig(format: .openpgp, key: key, program: nil, defaultKeyCommand: nil)
        case .config: break
        }
        var config: OpaquePointer?
        try check(git_repository_config(&config, repository.repo))
        defer { git_config_free(config) }
        var enabled: Int32 = 0
        let rc = git_config_get_bool(&enabled, config, forTag ? "tag.gpgsign" : "commit.gpgsign")
        if rc == GIT_ENOTFOUND.rawValue { return nil }
        try check(rc)
        guard enabled != 0 else { return nil }

        func string(_ name: String) throws -> String? {
            var buffer = git_buf()
            defer { git_buf_dispose(&buffer) }
            let rc = git_config_get_string_buf(&buffer, config, name)
            if rc == GIT_ENOTFOUND.rawValue { return nil }
            try check(rc)
            return buffer.ptr.map { String(cString: $0) }
        }
        func path(_ value: String) throws -> String {
            var buffer = git_buf()
            defer { git_buf_dispose(&buffer) }
            try check(git_config_parse_path(&buffer, value))
            return buffer.ptr.map { String(cString: $0) } ?? ""
        }
        let value = try string("gpg.format") ?? "openpgp"
        guard let format = SigningFormat(rawValue: value) else { throw SigningError.unsupportedFormat(value) }
        let programNames = format == .openpgp
            ? ["gpg.program", "gpg.openpgp.program"] : ["gpg.\(format.rawValue).program"]
        var program: String?
        var iterator: UnsafeMutablePointer<git_config_iterator>?
        try check(git_config_iterator_new(&iterator, config))
        defer { git_config_iterator_free(iterator) }
        while true {
            var entry: UnsafeMutablePointer<git_config_entry>?
            let rc = git_config_next(&entry, iterator)
            if rc == GIT_ITEROVER.rawValue { break }
            try check(rc)
            if let entry, let name = entry.pointee.name, let rawValue = entry.pointee.value,
               programNames.contains(String(cString: name)) {
                program = try path(String(cString: rawValue))
            }
        }
        return try SigningConfig(format: format, key: string("user.signingkey"), program: program,
                                 defaultKeyCommand: string("gpg.ssh.defaultKeyCommand"))
    }
}

extension Repository {
    /// Install a signer for this repository. Nil restores process defaults.
    /// Available on every platform, including iOS and Android.
    public func setSigner(_ signer: (any GitSigner)?) {
        self.signer = signer
    }

    // The extra-header transform is shared with amend; it runs before signing.
    // `message` takes a String or, for messages in another encoding, raw bytes.
    func createCommit(
        updateRef: String?, author: UnsafePointer<git_signature>?, committer: UnsafePointer<git_signature>?,
        encoding: String? = nil, message: UnsafePointer<CChar>, tree: OpaquePointer?, parents: [OpaquePointer?],
        sign: SignMode, transform: (([UInt8]) -> [UInt8])? = nil
    ) throws -> git_oid {
        let config = try SigningConfig.resolve(sign, repository: self)
        var oid = git_oid()
        var parents = parents
        if config == nil, transform == nil {
            _ = try parents.withUnsafeMutableBufferPointer { parents in
                try check(git_commit_create(&oid, repo, updateRef, author, committer,
                                            encoding, message, tree, parents.count, parents.baseAddress))
            }
            return oid
        }

        let selectedSigner = config != nil ? (signer ?? GitSigning.defaultSigner()) : nil
        if let config, selectedSigner == nil { throw SigningError.noSigner(config.format) }
        let reference = try commitReference(updateRef, parents: parents)
        defer { git_reference_free(reference.resolved) }

        var buffer = git_buf()
        defer { git_buf_dispose(&buffer) }
        _ = try parents.withUnsafeMutableBufferPointer { parents in
            try check(git_commit_create_buffer(&buffer, repo, author, committer,
                                               encoding, message, tree, parents.count, parents.baseAddress))
        }
        var payload = Array(UnsafeRawBufferPointer(start: buffer.ptr, count: buffer.size))
        if let transform { payload = transform(payload) }
        var signature: String?
        if let config, let selectedSigner {
            let identity = ResolvedSignature(committer)
            let request = SigningRequest(
                format: config.format, key: config.key, identity: "\(identity.name) <\(identity.email)>",
                program: config.program, defaultKeyCommand: config.defaultKeyCommand, workingDirectory: workdirURL)
            let armor = try selectedSigner.sign(payload, request: request)
            // libgit2 supplies the header's final LF itself. Passing a
            // terminal LF would add an extra empty continuation line that
            // git does not write. Preserve all other signature bytes.
            signature = armor.utf8.last == 10 ? String(decoding: armor.utf8.dropLast(), as: UTF8.self) : armor
        }

        // Recheck after a possibly blocking signer, before writing the object.
        // The C export also uses libgit2's compare-and-swap ref update.
        let current = try commitReference(updateRef, parents: parents)
        defer { git_reference_free(current.resolved) }
        if reference.symbolicTarget != current.symbolicTarget
            || (reference.resolved == nil) != (current.resolved == nil)
            || (reference.resolved != nil && current.resolved != nil
                && (git_reference_cmp(reference.resolved, current.resolved) != 0
                    || String(cString: git_reference_name(reference.resolved))
                        != String(cString: git_reference_name(current.resolved)))) {
            throw Libgit2Error(code: GIT_EMODIFIED.rawValue, klass: 0,
                              message: "failed to create commit: reference changed while signing")
        }
        var text = payload.map { CChar(bitPattern: $0) } + [0]
        _ = try text.withUnsafeMutableBufferPointer { text in
            try check(git_commit_create_with_signature(&oid, repo, text.baseAddress, signature, "gpgsig"))
        }
        if let updateRef {
            try check(gitkit_reference_update_for_commit(repo, reference.resolved, updateRef, &oid, "commit"))
        }
        return oid
    }

    private struct CommitReference {
        let resolved: OpaquePointer?
        let symbolicTarget: String?
    }

    private func commitReference(_ name: String?, parents: [OpaquePointer?]) throws -> CommitReference {
        guard let name else { return CommitReference(resolved: nil, symbolicTarget: nil) }
        var unresolved: OpaquePointer?
        let rc = git_reference_lookup(&unresolved, repo, name)
        if rc == GIT_ENOTFOUND.rawValue { return CommitReference(resolved: nil, symbolicTarget: nil) }
        try check(rc)
        defer { git_reference_free(unresolved) }
        let symbolicTarget = git_reference_symbolic_target(unresolved).map { String(cString: $0) }
        var reference: OpaquePointer?
        let resolveRC = git_reference_resolve(&reference, unresolved)
        if resolveRC == GIT_ENOTFOUND.rawValue {
            return CommitReference(resolved: nil, symbolicTarget: symbolicTarget)
        }
        try check(resolveRC)
        if let tip = git_reference_target(reference) {
            guard let parent = parents.first, let first = git_commit_id(parent), git_oid_cmp(tip, first) == 0 else {
                git_reference_free(reference)
                throw Libgit2Error(code: GIT_EMODIFIED.rawValue, klass: 0,
                                  message: "failed to create commit: current tip is not the first parent")
            }
        }
        return CommitReference(resolved: reference, symbolicTarget: symbolicTarget)
    }
}

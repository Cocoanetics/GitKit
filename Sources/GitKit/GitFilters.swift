import Foundation
import CGitKit

/// The conversion performed by a Git attribute filter.
public enum GitFilterDirection: Sendable {
    /// Blob → working tree, for example during checkout.
    case smudge
    /// Working tree → blob, for example during add or status.
    case clean
}

/// A snapshot of the file being filtered; contains no borrowed libgit2 pointers.
public struct GitFilterSource: Sendable {
    public let driver: String
    public let direction: GitFilterDirection
    /// Repository-relative path.
    public let path: String
    /// Git file mode, or zero when unknown.
    public let fileMode: UInt16
    /// Hex object ID, or nil when unknown (usually on clean).
    public let objectID: String?
    public let gitDirectory: URL
    /// Nil for a bare repository.
    public let workingDirectory: URL?
}

/// Downstream output for one filter stream. Use synchronously from the factory,
/// `write`, or `close` callbacks; do not use it from another thread. It becomes
/// invalid when the stream closes. Writes are forwarded without copying.
public final class GitFilterOutput {
    private var next: UnsafeMutablePointer<git_writestream>?

    init(_ next: UnsafeMutablePointer<git_writestream>) { self.next = next }

    public func write(_ bytes: UnsafeRawBufferPointer) throws {
        guard let next else {
            throw Libgit2Error(code: -1, klass: Int32(GIT_ERROR_FILTER.rawValue),
                               message: "filter output is closed")
        }
        // Some C sinks require a non-null pointer even for an empty write.
        guard !bytes.isEmpty else { return }
        try check(next.pointee.write(next, bytes.baseAddress?.assumingMemoryBound(to: CChar.self), bytes.count))
    }

    public func write(_ data: Data) throws {
        try data.withUnsafeBytes { try write($0) }
    }

    func invalidate() { next = nil }
}

/// A per-file push stream. Chunks are borrowed only for the duration of `write`.
/// Different files may be filtered concurrently, but one stream's callbacks are
/// synchronous and serial. `close` flushes output once; after a failed write it
/// is skipped, and releasing the stream must release any temporary resources.
public protocol GitFilterStream: AnyObject {
    func write(_ chunk: UnsafeRawBufferPointer) throws
    func close() throws
}

/// A process-wide filter definition, with a fresh stream for each file.
public struct GitFilter: Sendable {
    /// Return nil to pass this file through unchanged. A thrown error fails the
    /// operation, even for an optional driver, since output cannot be retracted.
    public typealias StreamFactory = @Sendable (
        GitFilterSource, GitFilterOutput
    ) throws -> (any GitFilterStream)?
    public typealias BufferedTransform = @Sendable (GitFilterSource, Data) throws -> Data?

    let clean: StreamFactory?
    let smudge: StreamFactory?

    public init(clean: StreamFactory? = nil, smudge: StreamFactory? = nil) {
        self.clean = clean
        self.smudge = smudge
    }

    /// Collects the input before transforming it. Nil results pass through.
    /// Optional drivers also pass through when the transform throws; required
    /// drivers propagate the error. Use the streaming initializer for large data.
    public static func buffered(
        clean: BufferedTransform? = nil, smudge: BufferedTransform? = nil
    ) -> GitFilter {
        GitFilter(clean: adapter(clean), smudge: adapter(smudge))
    }

    private static func adapter(_ transform: BufferedTransform?) -> StreamFactory? {
        guard let transform else { return nil }
        return { source, output in
            BufferedFilterStream(source: source, output: output, transform: transform)
        }
    }
}

final class BufferedFilterStream: GitFilterStream {
    let source: GitFilterSource
    let output: GitFilterOutput
    let transform: GitFilter.BufferedTransform
    var required = false
    private var input = Data()

    init(source: GitFilterSource, output: GitFilterOutput, transform: @escaping GitFilter.BufferedTransform) {
        self.source = source
        self.output = output
        self.transform = transform
    }

    func write(_ chunk: UnsafeRawBufferPointer) throws { input.append(contentsOf: chunk) }

    func close() throws {
        let result: Data
        do {
            result = try transform(source, input) ?? input
        } catch {
            guard !required else { throw error }
            result = input
        }
        // Downstream failures must never be treated as optional transform failures.
        try output.write(result)
    }
}

/// Registration affects all repositories in this process. Use unique names.
public enum GitFilters {
    public static let defaultPriority = 200

    /// Defaults to matching `filter=<name>` in .gitattributes. Lower priorities
    /// run first on smudge and last on clean. Also enables required-driver checks.
    public static func register(
        name: String, attributes: String? = nil, priority: Int = defaultPriority, _ filter: GitFilter
    ) throws {
        try GitFilterRegistry.shared.register(name: name, attributes: attributes, priority: priority, filter: filter)
    }

    public static func register(
        name: String, attributes: String? = nil, priority: Int = defaultPriority,
        clean: GitFilter.BufferedTransform? = nil, smudge: GitFilter.BufferedTransform? = nil
    ) throws {
        try register(name: name, attributes: attributes, priority: priority,
                     .buffered(clean: clean, smudge: smudge))
    }

    /// In-flight files keep their Swift closures. libgit2 retains raw filter
    /// pointers, so a small C definition and attributes allocation intentionally
    /// survive unregister (one allocation per registration cycle).
    public static func unregister(name: String) throws {
        try GitFilterRegistry.shared.unregister(name: name)
    }

    public static func isRegistered(_ name: String) -> Bool {
        GitFilterRegistry.shared.contains(name)
    }

    /// Opt into failing operations for missing `filter.<name>.required` drivers
    /// even before registering a filter. Once enabled, enforcement stays enabled.
    public static func enforceRequiredDrivers() throws {
        try GitFilterRegistry.shared.enforceRequiredDrivers()
    }
}

/// A Swift filter callback failure, preserved across the libgit2 C boundary.
public struct GitFilterError: Error, LocalizedError, Sendable {
    public enum Reason: Sendable, Equatable {
        case failed(String)
        case requiredDriverMissing
    }

    public let driver: String
    public let path: String
    public let direction: GitFilterDirection
    public let reason: Reason
    public let underlying: (any Error)?

    public var errorDescription: String? {
        let detail: String
        switch reason {
        case .failed(let description): detail = description.isEmpty ? "" : ": \(description)"
        case .requiredDriverMissing: detail = ": required filter driver is not registered"
        }
        return "\(path): \(direction) filter '\(driver)' failed\(detail)"
    }
}

import Foundation
import CGitKit

private let requiredGuardStartName = "gitkit-required-filter-guard-start"
private let requiredGuardEndName = "gitkit-required-filter-guard-end"

private final class FilterRegistration {
    let name: String
    let filter: GitFilter
    let driverAttributeIndex: Int?

    init(name: String, attributes: String, filter: GitFilter) {
        self.name = name
        self.filter = filter
        driverAttributeIndex = attributes.split(whereSeparator: { $0.isWhitespace })
            .firstIndex { $0 == "filter" || $0.hasPrefix("filter=") }
    }
}

/// Mutations and status lookups are serialized together. Required-driver checks
/// use callbacks selected under libgit2's own registry lock, not this table.
final class GitFilterRegistry: @unchecked Sendable {
    static let shared = GitFilterRegistry()
    private let mutationLock = NSLock()
    private var registrations: [String: UnsafeMutablePointer<gitkit_filter>] = [:]
    private var guardStartInstalled = false
    private var guardEndInstalled = false

    func contains(_ name: String) -> Bool {
        mutationLock.lock(); defer { mutationLock.unlock() }
        return registrations[name] != nil
    }

    func register(name: String, attributes: String?, priority: Int, filter: GitFilter) throws {
        Libgit2.ensureInitialized()
        guard !name.isEmpty, !name.contains(where: { $0.isWhitespace || $0 == "\0" }),
              name != requiredGuardStartName, name != requiredGuardEndName,
              let priority = Int32(exactly: priority), priority != Int32.min, priority != Int32.max,
              attributes?.contains("\0") != true else {
            throw Libgit2Error(code: -1, klass: Int32(GIT_ERROR_FILTER.rawValue),
                               message: "invalid filter name, attributes, or priority")
        }
        mutationLock.lock(); defer { mutationLock.unlock() }
        try installGuards()
        let attributes = attributes ?? "filter=\(name)"
        let pointer = try allocateFilter(attributes: attributes)
        let registration = FilterRegistration(name: name, attributes: attributes, filter: filter)
        pointer.pointee.context = Unmanaged.passRetained(registration).toOpaque()
        pointer.pointee.parent.check = filterCheck
        pointer.pointee.parent.stream = filterStream
        pointer.pointee.parent.cleanup = filterCleanup
        let rc = git_filter_register(name, UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: git_filter.self),
                                     priority)
        if rc < 0 {
            let error = Libgit2Error.last(code: rc)
            Unmanaged<FilterRegistration>.fromOpaque(pointer.pointee.context).release()
            free(UnsafeMutableRawPointer(mutating: pointer.pointee.parent.attributes))
            pointer.deallocate()
            throw error
        }
        registrations[name] = pointer
    }

    func unregister(name: String) throws {
        Libgit2.ensureInitialized()
        mutationLock.lock(); defer { mutationLock.unlock() }
        let pointer = registrations[name]
        guard let pointer else {
            throw Libgit2Error(code: Int32(GIT_ENOTFOUND.rawValue), klass: Int32(GIT_ERROR_FILTER.rawValue),
                               message: "Swift filter '\(name)' is not registered")
        }
        try check(git_filter_unregister(name))
        registrations.removeValue(forKey: name)
        Unmanaged<FilterRegistration>.fromOpaque(pointer.pointee.context).release()
        pointer.pointee.context = nil
        // Loaded lists still reference the C struct after unregister. Their
        // sessions own the Swift registration; stream/cleanup never read context.
        // Intentionally retain the C struct and attributes for process lifetime.
    }

    func enforceRequiredDrivers() throws {
        Libgit2.ensureInitialized()
        mutationLock.lock(); defer { mutationLock.unlock() }
        try installGuards()
    }

    private func installGuards() throws {
        if !guardStartInstalled {
            try installGuard(name: requiredGuardStartName, priority: Int32.min, check: requiredGuardStartCheck)
            guardStartInstalled = true
        }
        if !guardEndInstalled {
            try installGuard(name: requiredGuardEndName, priority: Int32.max, check: requiredGuardEndCheck)
            guardEndInstalled = true
        }
    }

    private func installGuard(name: String, priority: Int32, check callback: git_filter_check_fn?) throws {
        let pointer = try allocateFilter(attributes: "filter=*")
        pointer.pointee.parent.check = callback
        let rc = git_filter_register(name,
                                    UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: git_filter.self),
                                    priority)
        if rc < 0 {
            let error = Libgit2Error.last(code: rc)
            free(UnsafeMutableRawPointer(mutating: pointer.pointee.parent.attributes))
            pointer.deallocate()
            throw error
        }
    }
}

private func allocateFilter(attributes: String) throws -> UnsafeMutablePointer<gitkit_filter> {
    let pointer = UnsafeMutablePointer<gitkit_filter>.allocate(capacity: 1)
    pointer.initialize(to: gitkit_filter())
    let rc = git_filter_init(&pointer.pointee.parent, UInt32(GIT_FILTER_VERSION))
    guard rc >= 0, let text = strdup(attributes) else {
        pointer.deallocate()
        throw Libgit2Error.last(code: -1)
    }
    pointer.pointee.parent.attributes = UnsafePointer(text)
    return pointer
}

private final class FilterSession {
    let registration: FilterRegistration
    let required: Bool
    let driver: String

    init(registration: FilterRegistration, required: Bool, driver: String) {
        self.registration = registration
        self.required = required
        self.driver = driver
    }
}

private func sourceSnapshot(_ src: OpaquePointer, driver: String) -> GitFilterSource {
    let repo = git_filter_source_repo(src)
    let oid = git_filter_source_id(src)
    let objectID = oid.flatMap { git_oid_is_zero($0) == 0 ? String(cString: git_oid_tostr_s($0)) : nil }
    return GitFilterSource(
        driver: driver,
        direction: git_filter_source_mode(src) == GIT_FILTER_TO_WORKTREE ? .smudge : .clean,
        path: git_filter_source_path(src).map { String(cString: $0) } ?? "",
        fileMode: git_filter_source_filemode(src), objectID: objectID,
        gitDirectory: URL(fileURLWithPath: String(cString: git_repository_path(repo))),
        workingDirectory: git_repository_workdir(repo).map { URL(fileURLWithPath: String(cString: $0)) })
}

private func isRequired(_ driver: String, src: OpaquePointer) throws -> Bool {
    var config: OpaquePointer?
    try check(git_repository_config_snapshot(&config, git_filter_source_repo(src)))
    defer { git_config_free(config) }
    var value: Int32 = 0
    let rc = git_config_get_bool(&value, config, "filter.\(driver).required")
    if rc == GIT_ENOTFOUND.rawValue { return false }
    try check(rc)
    return value != 0
}

private func failure(_ error: Error, source: GitFilterSource) -> GitFilterError {
    // Preserve a downstream filter's original driver/path and underlying error.
    if let error = error as? GitFilterError { return error }
    return GitFilterError(driver: source.driver, path: source.path, direction: source.direction,
                          reason: .failed((error as? LocalizedError)?.errorDescription ?? String(describing: error)),
                          underlying: error)
}

/// The C error is thread-local too. Match both class and message when consuming
/// the pending error so an unrelated later failure cannot pick up a stale error.
enum PendingFilterError {
    private static let key = "GitKit.pendingFilterError"

    static func record(_ error: GitFilterError) -> Int32 {
        Thread.current.threadDictionary[key] = error
        _ = error.localizedDescription.withCString { git_error_set_str(Int32(GIT_ERROR_FILTER.rawValue), $0) }
        return -1 // GIT_EUSER has special checkout-notify semantics; do not use it.
    }

    static func take(matching error: Libgit2Error) -> GitFilterError? {
        let pending = Thread.current.threadDictionary[key] as? GitFilterError
        Thread.current.threadDictionary.removeObject(forKey: key)
        guard error.klass == Int32(GIT_ERROR_FILTER.rawValue),
              pending?.localizedDescription == error.message else { return nil }
        return pending
    }
}

private enum MatchedFilterDrivers {
    private final class State {
        var drivers: Set<String> = []
    }

    private static let key = "GitKit.matchedFilterDrivers"

    static func reset() {
        Thread.current.threadDictionary[key] = State()
    }

    static func record(_ driver: String) {
        let state: State
        if let current = Thread.current.threadDictionary[key] as? State {
            state = current
        } else {
            state = State()
            Thread.current.threadDictionary[key] = state
        }
        state.drivers.insert(driver)
    }

    static func contains(_ driver: String) -> Bool {
        (Thread.current.threadDictionary[key] as? State)?.drivers.contains(driver) == true
    }
}

private let requiredGuardStartCheck: git_filter_check_fn = { _, _, _, _ in
    MatchedFilterDrivers.reset()
    return GIT_PASSTHROUGH.rawValue
}

private let requiredGuardEndCheck: git_filter_check_fn = { _, _, src, values in
    guard let src, let value = values?.pointee, git_attr_value(value) == GIT_ATTR_VALUE_STRING else {
        return GIT_PASSTHROUGH.rawValue
    }
    let driver = String(cString: value)
    defer { MatchedFilterDrivers.reset() }
    if MatchedFilterDrivers.contains(driver) { return GIT_PASSTHROUGH.rawValue }
    let source = sourceSnapshot(src, driver: driver)
    do {
        guard try isRequired(driver, src: src) else { return GIT_PASSTHROUGH.rawValue }
        return PendingFilterError.record(GitFilterError(driver: driver, path: source.path,
            direction: source.direction, reason: .requiredDriverMissing, underlying: nil))
    } catch { return PendingFilterError.record(failure(error, source: source)) }
}

private let filterCheck: git_filter_check_fn = { filter, payload, src, values in
    guard let filter, let payload, let src else { return -1 }
    let container = UnsafeMutableRawPointer(filter).assumingMemoryBound(to: gitkit_filter.self)
    let registration = Unmanaged<FilterRegistration>.fromOpaque(container.pointee.context).takeUnretainedValue()
    // Use libgit2's resolved values, respecting attribute options such as
    // reading .gitattributes from HEAD rather than the working tree.
    var driver = registration.name
    if let index = registration.driverAttributeIndex,
       let value = values?[index], git_attr_value(value) == GIT_ATTR_VALUE_STRING {
        driver = String(cString: value)
    }
    let source = sourceSnapshot(src, driver: driver)
    do {
        let required = try isRequired(source.driver, src: src)
        let factory = source.direction == .clean ? registration.filter.clean : registration.filter.smudge
        guard factory != nil else {
            if required {
                return PendingFilterError.record(GitFilterError(driver: source.driver, path: source.path,
                    direction: source.direction, reason: .failed(""), underlying: nil))
            }
            return GIT_PASSTHROUGH.rawValue
        }
        let session = FilterSession(registration: registration, required: required, driver: source.driver)
        payload.pointee = Unmanaged.passRetained(session).toOpaque()
        MatchedFilterDrivers.record(source.driver)
        return 0
    } catch { return PendingFilterError.record(failure(error, source: source)) }
}

private let filterCleanup: git_filter_cleanup_fn = { _, payload in
    if let payload { Unmanaged<FilterSession>.fromOpaque(payload).release() }
}

private final class FilterStreamContext {
    let source: GitFilterSource
    let output: GitFilterOutput
    let next: UnsafeMutablePointer<git_writestream>
    let stream: (any GitFilterStream)?
    var error: GitFilterError?
    var closed = false

    init(source: GitFilterSource, output: GitFilterOutput, next: UnsafeMutablePointer<git_writestream>,
         stream: (any GitFilterStream)?) {
        self.source = source
        self.output = output
        self.next = next
        self.stream = stream
    }
}

private let filterStream: git_filter_stream_fn = { out, _, payload, src, next in
    guard let out, let payload = payload?.pointee, let src, let next else { return -1 }
    let session = Unmanaged<FilterSession>.fromOpaque(payload).takeUnretainedValue()
    let source = sourceSnapshot(src, driver: session.driver)
    let output = GitFilterOutput(next)
    do {
        let definition = session.registration.filter
        let factory = source.direction == .clean ? definition.clean : definition.smudge
        let stream = try factory?(source, output)
        (stream as? BufferedFilterStream)?.required = session.required
        let context = FilterStreamContext(source: source, output: output, next: next, stream: stream)
        let pointer = UnsafeMutablePointer<gitkit_filter_stream>.allocate(capacity: 1)
        pointer.initialize(to: gitkit_filter_stream())
        pointer.pointee.context = Unmanaged.passRetained(context).toOpaque()
        pointer.pointee.parent.write = filterWrite
        pointer.pointee.parent.close = filterClose
        pointer.pointee.parent.free = filterFree
        out.pointee = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: git_writestream.self)
        return 0
    } catch {
        output.invalidate()
        return PendingFilterError.record(failure(error, source: source))
    }
}

private func streamContext(_ pointer: UnsafeMutablePointer<git_writestream>) -> FilterStreamContext {
    let container = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: gitkit_filter_stream.self)
    return Unmanaged<FilterStreamContext>.fromOpaque(container.pointee.context).takeUnretainedValue()
}

private let filterWrite: @convention(c) (
    UnsafeMutablePointer<git_writestream>?, UnsafePointer<CChar>?, Int
) -> Int32 = { pointer, bytes, count in
    guard let pointer else { return -1 }
    let context = streamContext(pointer)
    if let error = context.error { return PendingFilterError.record(error) }
    guard !context.closed else { return -1 }
    do {
        let chunk = UnsafeRawBufferPointer(start: bytes, count: count)
        if let stream = context.stream { try stream.write(chunk) }
        else { try context.output.write(chunk) }
        return 0
    } catch {
        let error = failure(error, source: context.source)
        context.error = error
        return PendingFilterError.record(error)
    }
}

private let filterClose: @convention(c) (UnsafeMutablePointer<git_writestream>?) -> Int32 = { pointer in
    guard let pointer else { return -1 }
    let context = streamContext(pointer)
    if context.closed { return context.error.map { PendingFilterError.record($0) } ?? 0 }
    context.closed = true
    if context.error == nil {
        do { try context.stream?.close() }
        catch { context.error = failure(error, source: context.source) }
    }
    context.output.invalidate()
    // Always close downstream exactly once, including after a write failure.
    let rc = context.next.pointee.close(context.next)
    if let error = context.error { return PendingFilterError.record(error) }
    return rc
}

private let filterFree: @convention(c) (UnsafeMutablePointer<git_writestream>?) -> Void = { pointer in
    guard let pointer else { return }
    let container = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: gitkit_filter_stream.self)
    streamContext(pointer).output.invalidate()
    Unmanaged<FilterStreamContext>.fromOpaque(container.pointee.context).release()
    container.deallocate()
}

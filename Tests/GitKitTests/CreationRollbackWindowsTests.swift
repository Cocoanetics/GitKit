// Windows controls of the creation rollback: reparse points, data streams
// and open handles, which only Windows has in this form.
#if os(Windows)
import Foundation
import Testing
import WinSDK
import CGitKit
@testable import GitKit

extension CreationRollbackTests {

    /// Clones into `directory` with a preparation, refused by the include
    /// policy in the new repository's own open.
    func expectFailingClone(from source: URL, into directory: URL) throws {
        let extra = fixtures.url("extra.config")
        try "[test]\n\textra = 1\n".write(to: extra, atomically: true, encoding: .utf8)
        let global = fixtures.url("global.config")
        try "[includeIf \"gitdir:**/probe-clone/\"]\n\tpath = \(extra.path)\n"
            .write(to: global, atomically: true, encoding: .utf8)
        _ = Self.trace()
        #expect(throws: Libgit2Error.self) {
            try Repository.withOperationConfiguration(OperationConfiguration(
                levels: [.file(global, .global)], includePolicy: ConfigIncludePolicy { _ in false })) {
                // Prepared, so the clone's init is GitKit's own, which rolls back.
                try Repository.clone(
                    fromRemote: source.path, to: directory, progress: Self.silent,
                    preparation: RepositoryPreparation { _ in Issue.record("prepared") })
            }
        }
    }

    /// `path` as Win32 takes it: drive-letter, backslash-separated.
    private static func win32Path(_ url: URL) -> String {
        var path = url.path
        if path.hasPrefix("/"), path.dropFirst().dropFirst().first == ":" { path.removeFirst() }
        return path.replacingOccurrences(of: "/", with: "\\")
    }

    /// Opens `url` with Win32's CreateFileW; nil when it can't.
    private static func open(
        _ url: URL, access: DWORD, share: DWORD, disposition: DWORD, flags: DWORD = 0
    ) -> HANDLE? {
        let handle = win32Path(url).withCString(encodedAs: UTF16.self) {
            CreateFileW($0, access, share, nil, disposition, flags, nil)
        }
        return handle == INVALID_HANDLE_VALUE ? nil : handle
    }

    /// Makes `link` a directory junction (a mount-point reparse point) to
    /// `target`, as `mklink /J` does; no privilege needed.
    private static func makeJunction(at link: URL, to target: URL) throws {
        try FileManager.default.createDirectory(at: link, withIntermediateDirectories: false)
        let print = Array(win32Path(target).utf16)
        let substitute = Array("\\??\\".utf16) + print
        let names = substitute + [0] + print + [0]
        let dataLength = 8 + names.count * 2
        var buffer = [UInt8](repeating: 0, count: 8 + dataLength)
        func put16(_ value: Int, at offset: Int) {
            buffer[offset] = UInt8(value & 0xFF)
            buffer[offset + 1] = UInt8(value >> 8)
        }
        let tag: UInt32 = 0xA000_0003  // IO_REPARSE_TAG_MOUNT_POINT
        for index in 0..<4 { buffer[index] = UInt8((tag >> (8 * UInt32(index))) & 0xFF) }
        put16(dataLength, at: 4)
        put16(0, at: 8)                                  // SubstituteNameOffset
        put16(substitute.count * 2, at: 10)              // SubstituteNameLength
        put16((substitute.count + 1) * 2, at: 12)        // PrintNameOffset
        put16(print.count * 2, at: 14)                   // PrintNameLength
        for (index, unit) in names.enumerated() { put16(Int(unit), at: 16 + index * 2) }

        guard let handle = open(
            link, access: DWORD(GENERIC_WRITE), share: 0, disposition: DWORD(OPEN_EXISTING),
            flags: DWORD(FILE_FLAG_BACKUP_SEMANTICS) | DWORD(FILE_FLAG_OPEN_REPARSE_POINT))
        else { throw CocoaError(.fileWriteUnknown) }
        defer { CloseHandle(handle) }
        var returned: DWORD = 0
        let set = buffer.withUnsafeMutableBytes {
            DeviceIoControl(handle, 0x0009_00A4 /* FSCTL_SET_REPARSE_POINT */,
                            $0.baseAddress, DWORD($0.count), nil, 0, &returned, nil)
        }
        guard set else { throw CocoaError(.fileWriteUnknown) }
    }

    @Test("a worktree directory replaced by a junction leaves its target and the original alone")
    func directoryReplacedByJunctionIsLeftAlone() throws {
        defer { fixtures.removeAll() }
        try expectReplacedWorktreeLeftAlone(replace: { path, elsewhere in
            try Self.makeJunction(at: path, to: elsewhere)
        }, check: { path in
            let attributes = Self.win32Path(path).withCString(encodedAs: UTF16.self) { GetFileAttributesW($0) }
            #expect(attributes != INVALID_FILE_ATTRIBUTES
                    && attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0)
        })
    }

    @Test("an alternate data stream someone adds to a clone's config keeps the clone")
    func alternateStreamKeepsClone() throws {
        defer { fixtures.removeAll() }
        let (source, _, _) = try makeSource()
        for directory in try failingClones(source, meanwhile: { directory in
            try Self.writeStream(directory.appendingPathComponent(".git/config").path + ":theirs")
        }) {
            #expect(Self.streamExists(directory.appendingPathComponent(".git/config").path + ":theirs"))
            #expect(Self.exists(directory.appendingPathComponent(".git/HEAD")))
        }
    }

    /// Writes a named data stream, `path` being `<file or directory>:<name>`.
    private static func writeStream(_ path: String) throws {
        guard let handle = open(
            URL(fileURLWithPath: path), access: DWORD(GENERIC_WRITE), share: 0,
            disposition: DWORD(CREATE_NEW))
        else { throw CocoaError(.fileWriteUnknown) }
        defer { CloseHandle(handle) }
        var written: DWORD = 0
        _ = Array("mine\n".utf8).withUnsafeBytes {
            WriteFile(handle, $0.baseAddress, DWORD($0.count), &written, nil)
        }
    }

    private static func streamExists(_ path: String) -> Bool {
        guard let handle = open(URL(fileURLWithPath: path), access: DWORD(GENERIC_READ),
                                share: DWORD(FILE_SHARE_READ), disposition: DWORD(OPEN_EXISTING))
        else { return false }
        CloseHandle(handle)
        return true
    }

    @Test("an alternate data stream someone adds to a clone's git directory keeps the clone")
    func directoryStreamKeepsClone() throws {
        defer { fixtures.removeAll() }
        let (source, _, _) = try makeSource()
        for directory in try failingClones(source, meanwhile: { directory in
            try Self.writeStream(directory.appendingPathComponent(".git").path + ":theirs")
        }) {
            #expect(Self.streamExists(directory.appendingPathComponent(".git").path + ":theirs"))
            #expect(Self.exists(directory.appendingPathComponent(".git/HEAD")))
        }
    }

    /// Makes `link` another name of `target`, with Win32's CreateHardLinkW.
    static func makeHardLink(_ link: URL, to target: URL) throws {
        let made = win32Path(link).withCString(encodedAs: UTF16.self) { link in
            win32Path(target).withCString(encodedAs: UTF16.self) { CreateHardLinkW(link, $0, nil) }
        }
        guard made else { throw CocoaError(.fileWriteUnknown, userInfo: ["win32": GetLastError()]) }
    }

    /// What `writeLateStream` did: how often it ran, where it wrote (the
    /// checked directory, or `.git` in it, which the walk checked), and
    /// whether the stream could be made, sharing everything.
    nonisolated(unsafe) private static var lateCalls = 0
    nonisolated(unsafe) private static var lateSuffix = ""
    nonisolated(unsafe) private static var lateWritten = false
    nonisolated(unsafe) private static var lateError: DWORD = 0

    private static let writeLateStream: gitkit_created_restore_hook = { path in
        guard let path else { return }
        lateCalls += 1
        guard lateCalls == 1 else { return }
        let stream = String(cString: path) + lateSuffix + ":late"
        let handle = stream.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(GENERIC_WRITE),
                        DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE) | DWORD(FILE_SHARE_DELETE),
                        nil, DWORD(CREATE_NEW), 0, nil)
        }
        guard handle != INVALID_HANDLE_VALUE, let handle else {
            lateError = GetLastError()
            return
        }
        defer { CloseHandle(handle) }
        var written: DWORD = 0
        lateWritten = Array("late\n".utf8).withUnsafeBytes {
            WriteFile(handle, $0.baseAddress, DWORD($0.count), &written, nil)
        }
        if !lateWritten { lateError = GetLastError() }
    }

    @Test("a stream someone adds to a checked directory just before its delete keeps it, with the stream",
          arguments: ["", "\\.git"])
    func lateDirectoryStreamIsKept(suffix: String) throws {
        defer { fixtures.removeAll() }
        let (source, _, _) = try makeSource()
        Self.lateCalls = 0
        Self.lateSuffix = suffix
        Self.lateWritten = false
        Self.lateError = 0
        gitkit_created_set_delete_hook(Self.writeLateStream)
        defer { gitkit_created_set_delete_hook(nil) }
        let directory = fixtures.url("probe-clone")
        try expectFailingClone(from: source, into: directory)
        gitkit_created_set_delete_hook(nil)

        // The hook ran between the last check and the delete.
        #expect(Self.lateCalls >= 1, "the delete hook ran")
        // How Windows behaved, for the record: whether a pin denying delete
        // sharing keeps another stream from being made by one sharing it.
        print("CreationRollbackTests: late stream on '\(suffix)': written \(Self.lateWritten), "
              + "Win32 error \(Self.lateError)")
        let target = suffix.isEmpty ? directory : directory.appendingPathComponent(".git")
        if Self.lateWritten {
            #expect(Self.streamExists(target.path + ":late"), Self.trace())
        } else {
            // Refused: nothing foreign was added, so the clone goes.
            #expect(Self.lateError != 0)
            #expect(!Self.exists(directory), Self.trace())
        }
    }

    /// Handles a test holds open past the failing call.
    final class HeldHandles: @unchecked Sendable {
        private let lock = NSLock()
        private var handles: [HANDLE] = []

        func hold(_ handle: HANDLE) {
            lock.lock(); defer { lock.unlock() }
            handles.append(handle)
        }

        func closeAll() {
            lock.lock(); defer { lock.unlock() }
            handles.forEach { CloseHandle($0) }
            handles = []
        }
    }

    @Test("a file someone holds open in a clone across the failure keeps the clone, intact")
    func heldFileKeepsClone() throws {
        defer { fixtures.removeAll() }
        let (source, _, _) = try makeSource()
        let held = HeldHandles()
        defer { held.closeAll() }
        let directories = try failingClones(source, meanwhile: { directory in
            guard let handle = Self.open(
                directory.appendingPathComponent(".git/HEAD"), access: DWORD(GENERIC_READ),
                share: DWORD(FILE_SHARE_READ), disposition: DWORD(OPEN_EXISTING))
            else { throw CocoaError(.fileReadUnknown) }
            held.hold(handle)
        })
        held.closeAll()
        for directory in directories {
            #expect(try String(contentsOf: directory.appendingPathComponent(".git/HEAD"), encoding: .utf8)
                .hasPrefix("ref: refs/heads/"))
            #expect(Self.exists(directory.appendingPathComponent(".git/config")))
        }
    }
}
#endif

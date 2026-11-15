#if os(macOS) || os(Linux)
import Foundation

enum ExecutableScript {
    /// Writes a script that a test is about to execute.
    ///
    /// A child that parallel tests fork while this process holds the script
    /// open for writing inherits that descriptor, and on Linux executing the
    /// script then fails with ETXTBSY. Writing it from a short-lived `cp`
    /// keeps the only writable descriptor out of this process.
    static func write(_ contents: String, to url: URL, permissions: Int = 0o755) throws {
        let source = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent)-source-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data(contents.utf8).write(to: source)
        let copy = Process()
        copy.executableURL = URL(fileURLWithPath: "/bin/cp")
        copy.arguments = [source.path, url.path]
        try copy.run()
        copy.waitUntilExit()
        guard copy.terminationStatus == 0 else {
            throw AmendFixture.Failure(description: "cp \(url.path) exited \(copy.terminationStatus)")
        }
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }
}
#endif

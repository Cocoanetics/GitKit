import Foundation
import Testing

/// One private directory per test instance, holding every repository, clone,
/// copy and supporting file. Register cleanup with `defer` before setup starts.
final class TemporaryRepositories {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("GitKitTests-\(UUID().uuidString)")

    /// Reserve a path without creating it (clone and copy need absent paths).
    func url(_ name: String) -> URL {
        root.appendingPathComponent(name)
    }

    func directory(_ name: String) throws -> URL {
        let dir = url(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func removeAll(sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            try FileManager.default.removeItem(at: root)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Setup may have failed before creating anything.
        } catch {
            Issue.record(error, "Removing test fixtures at \(root.path)", sourceLocation: sourceLocation)
        }
    }
}

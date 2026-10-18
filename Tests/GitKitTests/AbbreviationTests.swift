import Foundation
import Testing
import CGitKit
@testable import GitKit

/// Abbreviated object IDs in the push summary follow git: they start at
/// `core.abbrev` and lengthen while another object shares the prefix.
@Suite("Abbreviated IDs")
struct AbbreviationTests {

    @Test("an ID lengthens while another object shares its prefix")
    func abbreviationsStayUnambiguous() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AbbreviationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try Repository.initialize(at: dir, initialBranch: "main")
        try repo.configSet("core.abbrev", "4")

        // Write blobs until two share their first four hex digits.
        var seen: [String: git_oid] = [:]
        var collision: git_oid?
        for index in 0..<20_000 where collision == nil {
            var oid = git_oid()
            let text = "blob \(index)"
            _ = text.withCString { git_blob_create_from_buffer(&oid, repo.pointer, $0, strlen($0)) }
            let prefix = String(String(cString: git_oid_tostr_s(&oid)).prefix(4))
            if seen[prefix] != nil { collision = oid } else { seen[prefix] = oid }
        }
        let shared = try #require(collision)
        #expect(abbreviated(shared, minimum: 4, in: repo.pointer).count > 4)

        // An object the repository doesn't have keeps the minimum.
        var missing = git_oid()
        _ = "0123456789abcdef0123456789abcdef01234567".withCString { git_oid_fromstr(&missing, $0) }
        #expect(abbreviated(missing, minimum: 4, in: repo.pointer) == "0123")
    }
}

import Foundation
import CGitKit

extension Repository {
    /// Keep the unpeeled object, as git's MERGE_HEAD does for tags.
    func mergeHeadObject(_ spec: String) throws -> git_oid {
        var object: OpaquePointer?
        try check(git_revparse_single(&object, repo, spec))
        defer { git_object_free(object) }
        return git_object_id(object).pointee
    }

    func peelMergeHead(_ oid: git_oid) throws -> git_oid {
        var oid = oid
        var object: OpaquePointer?
        try check(git_object_lookup(&object, repo, &oid, GIT_OBJECT_ANY))
        defer { git_object_free(object) }
        var commit: OpaquePointer?
        try check(git_object_peel(&commit, object, GIT_OBJECT_COMMIT))
        defer { git_object_free(commit) }
        return git_object_id(commit).pointee
    }

    func writeMergeHeadObjects(_ oids: [git_oid]) throws {
        let directory = URL(fileURLWithPath: String(cString: git_repository_path(repo)))
        let text = oids.map { oid in
            var oid = oid
            return formatOID(&oid) + "\n"
        }.joined()
        try Data(text.utf8).write(to: directory.appendingPathComponent("MERGE_HEAD"))
    }

    /// Git embeds signed annotated tags only, without verifying their
    /// signatures. Read the raw object so encoding and line endings survive.
    func mergeTagHeaders(oids: [git_oid]) throws -> [UInt8] {
        var odb: OpaquePointer?
        try check(git_repository_odb(&odb, repo))
        defer { git_odb_free(odb) }
        var headers: [UInt8] = []
        for var oid in oids {
            var object: OpaquePointer?
            try check(git_odb_read(&object, odb, &oid))
            defer { git_odb_object_free(object) }
            guard git_odb_object_type(object) == GIT_OBJECT_TAG else { continue }
            let bytes = Array(UnsafeRawBufferPointer(
                start: git_odb_object_data(object), count: git_odb_object_size(object)))
            guard parseTagSignature(bytes) != nil else { continue }
            headers += Array("mergetag".utf8)
            var start = bytes.startIndex
            while start < bytes.endIndex {
                let end = bytes[start...].firstIndex(of: 10) ?? bytes.endIndex
                headers += [32] + bytes[start..<end] + [10]
                start = end < bytes.endIndex ? end + 1 : end
            }
        }
        return headers
    }

    /// Extra headers precede the blank line and are part of the signed payload.
    static func insertingMergeTags(_ commit: [UInt8], headers: [UInt8]) -> [UInt8] {
        guard let end = commit.indices.dropLast().first(where: { commit[$0] == 10 && commit[$0 + 1] == 10 })
        else { return commit }
        return Array(commit[...end]) + headers + Array(commit[(end + 1)...])
    }
}

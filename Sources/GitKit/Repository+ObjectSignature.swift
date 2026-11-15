import CGitKit

/// An object's signature and the exact bytes it signs. GitKit does not
/// verify signatures or establish trust in their signers.
public struct ObjectSignature: Sendable, Equatable {
    /// Commit header (`gpgsig` or `gpgsig-sha256`), or nil for a tag.
    public let field: String?
    /// Armored signature text.
    public let signature: String
    /// Serialized object bytes excluding all signature fields.
    public let signedPayload: [UInt8]
    /// Format recognized from the armor header, or nil if unknown.
    public let format: SigningFormat?
}

extension Repository {
    /// Extract both supported signature headers, in `gpgsig`,
    /// `gpgsig-sha256` order. Unsigned commits return an empty array.
    /// Annotated tags are peeled to their commit; lookup/type errors throw.
    public func commitSignatures(_ rev: String) throws -> [ObjectSignature] {
        var obj: OpaquePointer?
        try check(git_revparse_single(&obj, repo, rev))
        defer { git_object_free(obj) }
        var commit: OpaquePointer?
        try check(git_object_peel(&commit, obj, GIT_OBJECT_COMMIT))
        defer { git_object_free(commit) }
        var oid = git_object_id(commit)?.pointee ?? git_oid()
        let rawBytes = try rawObjectBytes(repo: repo, oid: &oid)
        let signedPayload = removingSignatureHeaders(from: rawBytes)

        var result: [ObjectSignature] = []
        for field in ["gpgsig", "gpgsig-sha256"] {
            guard containsHeader(field, in: rawBytes) else { continue }
            var signature = git_buf()
            var ignoredPayload = git_buf()
            defer {
                git_buf_dispose(&signature)
                git_buf_dispose(&ignoredPayload)
            }
            let rc = git_commit_extract_signature(&signature, &ignoredPayload, repo, &oid, field)
            if rc == GIT_ENOTFOUND.rawValue { continue }
            try check(rc)
            let text = signature.ptr.map {
                String(decoding: UnsafeRawBufferPointer(start: $0, count: signature.size), as: UTF8.self)
            } ?? ""
            result.append(ObjectSignature(
                field: field, signature: text, signedPayload: signedPayload,
                format: signatureFormat(text)))
        }
        return result
    }

    /// Extract the trailing signature from an annotated tag's raw object.
    /// Unsigned annotated tags return nil; lookup/type errors throw.
    /// Lightweight tags resolve to their target and therefore throw.
    public func tagSignature(_ rev: String) throws -> ObjectSignature? {
        var obj: OpaquePointer?
        try check(git_revparse_single(&obj, repo, rev))
        defer { git_object_free(obj) }
        var oid = git_object_id(obj)?.pointee ?? git_oid()
        var tag: OpaquePointer?
        try check(git_tag_lookup(&tag, repo, &oid))
        defer { git_tag_free(tag) }

        return parseTagSignature(try rawObjectBytes(repo: repo, oid: &oid))
    }
}

private let signatureHeaders: [(String, SigningFormat)] = [
    ("-----BEGIN PGP SIGNATURE-----", .openpgp),
    ("-----BEGIN PGP MESSAGE-----", .openpgp),
    ("-----BEGIN SSH SIGNATURE-----", .ssh),
    ("-----BEGIN SIGNED MESSAGE-----", .x509)
]

private let signatureFieldPrefixes = [
    Array("gpgsig ".utf8), Array("gpgsig-sha256 ".utf8)
]

private func signatureFormat(_ signature: String) -> SigningFormat? {
    signatureHeaders.first { signature.hasPrefix($0.0) }?.1
}

private func rawObjectBytes(repo: OpaquePointer?, oid: inout git_oid) throws -> [UInt8] {
    var odb: OpaquePointer?
    try check(git_repository_odb(&odb, repo))
    defer { git_odb_free(odb) }
    var raw: OpaquePointer?
    try check(git_odb_read(&raw, odb, &oid))
    defer { git_odb_object_free(raw) }
    guard let data = git_odb_object_data(raw) else { return [] }
    return Array(UnsafeRawBufferPointer(start: data, count: git_odb_object_size(raw)))
}

/// Find an exact field only before the header/body separator.
private func containsHeader(_ field: String, in bytes: [UInt8]) -> Bool {
    let prefix = Array((field + " ").utf8)
    var lineStart = 0
    while lineStart < bytes.count {
        let lineEnd = bytes[lineStart...].firstIndex(of: 10) ?? bytes.endIndex
        let line = bytes[lineStart..<lineEnd]
        if line.isEmpty { return false }
        if line.starts(with: prefix) { return true }
        lineStart = lineEnd < bytes.endIndex ? lineEnd + 1 : lineEnd
    }
    return false
}

/// Match git's last armor header at a line start, scanning only the body.
func parseTagSignature(_ bytes: [UInt8]) -> ObjectSignature? {
    guard let separator = bytes.indices.dropLast().first(where: {
        bytes[$0] == 10 && bytes[$0 + 1] == 10
    }) else { return nil }
    let headers = signatureHeaders.map { Array($0.0.utf8) }
    var start: Int?
    for index in (separator + 2)..<bytes.count where bytes[index - 1] == 10 {
        if headers.contains(where: { bytes[index...].starts(with: $0) }) {
            start = index
        }
    }
    guard let start else { return nil }
    let signature = String(decoding: bytes[start...], as: UTF8.self)
    return ObjectSignature(
        field: nil, signature: signature,
        signedPayload: removingSignatureHeaders(from: Array(bytes[..<start])),
        format: signatureFormat(signature))
}

/// Remove compatibility signatures from an object's header section while
/// preserving all other bytes, including the header/body separator.
private func removingSignatureHeaders(from bytes: [UInt8]) -> [UInt8] {
    var result: [UInt8] = []
    result.reserveCapacity(bytes.count)
    var lineStart = 0
    var removing = false
    while lineStart < bytes.count {
        let lineEnd = bytes[lineStart...].firstIndex(of: 10) ?? bytes.endIndex
        let nextLine = lineEnd < bytes.endIndex ? lineEnd + 1 : lineEnd
        let line = bytes[lineStart..<lineEnd]
        if line.isEmpty {
            result.append(contentsOf: bytes[lineStart...])
            break
        }
        if line.first != 32 {
            removing = signatureFieldPrefixes.contains { line.starts(with: $0) }
        }
        if !removing {
            result.append(contentsOf: bytes[lineStart..<nextLine])
        }
        lineStart = nextLine
    }
    return result
}

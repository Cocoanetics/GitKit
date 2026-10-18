import Foundation

extension URL {
    /// The remote spelled the way git spells it, for handing to libgit2.
    ///
    /// Foundation parses a scp-style remote (`git@github.com:o/r.git`)
    /// as a URL without a scheme and percent-encodes what it doesn't
    /// allow there, so `git@[::1]:r.git` comes back from
    /// `absoluteString` as `git@%5B%3A%3A1%5D%3Ar.git`, which libgit2
    /// can't read. For such a remote, the escapes Foundation adds — for
    /// characters a URL path can't hold, plus `:` — are undone. Escapes
    /// that were already valid in the remote, like the `%2F` in
    /// `host:repos%2Fteam.git`, stay as written. Real URLs
    /// (`scheme://…`) pass through unchanged.
    var gitRemote: String {
        let string = absoluteString
        guard !string.contains("://") else { return string }
        return Self.undoingFoundationEscapes(in: string)
    }

    /// Bytes Foundation escapes in a URL path: space, `"`, `%`, `:`,
    /// `<`, `>`, `[`, `\`, `]`, `^`, `` ` ``, `{`, `|`, `}`, and every
    /// non-ASCII byte.
    private static func isFoundationEscaped(_ byte: UInt8) -> Bool {
        byte >= 0x80 || Array(#" "%:<>[\]^`{|}"#.utf8).contains(byte)
    }

    private static func undoingFoundationEscapes(in string: String) -> String {
        let bytes = Array(string.utf8)
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "%"), index + 2 < bytes.count,
               let value = UInt8(String(decoding: bytes[(index + 1)...(index + 2)], as: UTF8.self),
                                 radix: 16),
               isFoundationEscaped(value) {
                result.append(value)
                index += 3
            } else {
                result.append(bytes[index])
                index += 1
            }
        }
        return String(decoding: result, as: UTF8.self)
    }
}

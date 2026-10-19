// Non-cone sparse-checkout patterns, matched as git matches them
// (path_in_sparse_checkout): gitignore syntax, the last pattern that
// matches deciding, a `!` pattern leaving the path out, and a path no
// pattern decides taking what its directory gets.
import Foundation
import CGitKit

struct SparsePatterns {

    private struct Pattern {
        let text: String
        let negative: Bool
        let mustBeDirectory: Bool
        /// No slash but a trailing one: matched against the basename.
        let basenameOnly: Bool
    }

    private let patterns: [Pattern]
    private let flags: UInt32

    init(_ text: String, ignoreCase: Bool = false) {
        flags = ignoreCase ? UInt32(GITKIT_WM_CASEFOLD) : 0
        patterns = text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { raw in
            var line = Self.trimmingTrailingSpaces(String(raw.hasSuffix("\r") ? raw.dropLast() : raw))
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let negative = line.hasPrefix("!")
            if negative { line.removeFirst() }
            let mustBeDirectory = line.hasSuffix("/")
            if mustBeDirectory { line.removeLast() }
            guard !line.isEmpty else { return nil }
            let basenameOnly = !line.contains("/")
            if line.hasPrefix("/") { line.removeFirst() }
            return Pattern(text: line, negative: negative, mustBeDirectory: mustBeDirectory,
                           basenameOnly: basenameOnly)
        }
    }

    /// Trailing spaces go unless a backslash escapes them, as in
    /// gitignore.
    private static func trimmingTrailingSpaces(_ line: String) -> String {
        var chars = Array(line)
        while chars.last == " " {
            let backslashes = chars.dropLast().reversed().prefix { $0 == "\\" }.count
            if backslashes % 2 == 1 { break }
            chars.removeLast()
        }
        return String(chars)
    }

    /// Whether the file `path` is in the sparse checkout.
    func includes(_ path: String) -> Bool {
        var current = Substring(path)
        var isDirectory = false
        while !current.isEmpty {
            if let decided = decide(String(current), isDirectory: isDirectory) { return decided }
            guard let slash = current.lastIndex(of: "/") else { break }
            current = current[..<slash]
            isDirectory = true
        }
        return false
    }

    /// The last matching pattern's say, or nil when none matches.
    private func decide(_ path: String, isDirectory: Bool) -> Bool? {
        let basename = path.split(separator: "/").last.map(String.init) ?? path
        for pattern in patterns.reversed() {
            if pattern.mustBeDirectory, !isDirectory { continue }
            let text = pattern.basenameOnly ? basename : path
            let pathname = pattern.basenameOnly ? 0 : UInt32(GITKIT_WM_PATHNAME)
            if gitkit_wildmatch(pattern.text, text, flags | pathname) == 0 { return !pattern.negative }
        }
        return nil
    }
}

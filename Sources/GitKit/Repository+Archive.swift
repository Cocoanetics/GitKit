// `git archive` support — present only when the package's `Archive` trait
// is enabled (`.package(url: …, traits: ["Archive"])` or
// `swift build --traits Archive`), which adds the libarchive-backed
// swift-archive dependency. An enabled trait doubles as a compilation
// condition of the same name; with it off this file compiles to nothing —
// core GitKit stays dependency-free. (Gating on the trait, not
// `canImport(Archive)`, keeps a shared .build from a prior trait-on build
// from poisoning the probe.)
#if Archive

import Foundation
import CGitKit

// Selective imports — the libarchive wrapper module is named `Archive`
// and its own `enum Archive` / `ArchiveFormat` / `ArchiveFilter` would
// shadow more than we want if we used a module-level `import Archive`.
import struct Archive.ArchiveEntry
import class Archive.ArchiveWriter
import enum Archive.ArchiveFormat
import enum Archive.ArchiveFilter
import enum Archive.FileType

/// Output formats ``Repository/archive(treeish:format:to:prefix:)`` can
/// produce. tar variants are libarchive's pax-restricted tar with the named
/// filter; zip is libarchive's PKZIP with default deflate. The bz2 / xz /
/// zstd arms only work where libarchive was compiled with the matching
/// trait — macOS / Linux / Windows. iOS / Android writes throw libarchive's
/// "filter not enabled" error.
public enum GitArchiveFormat: Sendable, Equatable {
    /// Uncompressed pax-restricted tar.
    case tar
    /// tar + gzip filter (`.tar.gz`).
    case tarGzip
    /// tar + bzip2 filter (`.tar.bz2`).
    case tarBzip2
    /// tar + xz filter (`.tar.xz`).
    case tarXz
    /// tar + zstd filter (`.tar.zst`).
    case tarZstd
    /// PKZIP with default deflate.
    case zip
}

extension Repository {

    /// Write `treeish`'s tree as an archive — `git archive`.
    ///
    /// Walks the tree via ``treeBlobs(of:prefix:)`` and streams each blob
    /// into the libarchive writer the format selects: no `git` binary, no
    /// `Process` spawn, works under sandboxed iOS / Android. Every entry is
    /// stamped with ``commitTime(of:)`` so the same SHA produces a
    /// byte-identical archive across runs — upstream `git archive`'s
    /// reproducibility guarantee. (Raw tree SHAs have no commit context and
    /// fall back to the current wall clock.)
    ///
    /// - Parameters:
    ///   - treeish: Anything that peels to a tree — `"HEAD"`, a branch, a
    ///     tag, a commit SHA, or a raw tree SHA.
    ///   - format: The container/filter to produce; see ``GitArchiveFormat``.
    ///   - output: Destination file URL (created/overwritten).
    ///   - prefix: Prepended to every entry path, `git archive --prefix=`
    ///     style. A trailing slash is added if missing.
    public func archive(
        treeish: String = "HEAD",
        format: GitArchiveFormat,
        to output: URL,
        prefix: String? = nil
    ) throws {
        let entries = try treeBlobs(of: treeish, prefix: Self.normalizedPrefix(prefix))
        let mtime = try commitTime(of: treeish) ?? Date()
        try Self.writeArchive(entries: entries, mtime: mtime, to: output, format: format)
    }

    /// `--prefix` normalisation: empty stays empty, anything else gains a
    /// trailing slash if it lacks one.
    private static func normalizedPrefix(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        if raw.hasSuffix("/") { return raw }
        return raw + "/"
    }

    /// Stream the walked blobs into a libarchive writer.
    private static func writeArchive(
        entries: [TreeBlob],
        mtime: Date,
        to output: URL,
        format: GitArchiveFormat
    ) throws {
        let archiveFormat: ArchiveFormat
        let filters: [ArchiveFilter]
        switch format {
        case .tar:       archiveFormat = .tar; filters = [.none]
        case .tarGzip:   archiveFormat = .tar; filters = [.gzip]
        case .tarBzip2:  archiveFormat = .tar; filters = [.bzip2]
        case .tarXz:     archiveFormat = .tar; filters = [.xz]
        case .tarZstd:   archiveFormat = .tar; filters = [.zstd]
        case .zip:       archiveFormat = .zip; filters = [.none]
        }

        let writer = try ArchiveWriter(
            path: output.path, format: archiveFormat, filters: filters)
        var closed = false
        defer { if !closed { try? writer.close() } }

        for entry in entries {
            // Match upstream `git archive`: regular files keep their
            // executable bit; symlinks are stored as links to their target.
            let unixMode: UInt16 = entry.isSymlink ? 0o755
                : (entry.isExecutable ? 0o755 : 0o644)
            let archiveEntry = ArchiveEntry(
                pathname: entry.path,
                size: Int64(entry.isSymlink ? 0 : entry.bytes.count),
                fileType: entry.isSymlink ? .symbolicLink : .regular,
                permissions: unixMode,
                modificationDate: mtime,
                symlinkTarget: entry.isSymlink
                    ? String(data: entry.bytes, encoding: .utf8)
                    : nil)
            try writer.writeEntry(
                archiveEntry,
                data: entry.isSymlink ? nil : entry.bytes)
        }
        try writer.close()
        closed = true
    }
}

#endif // Archive trait

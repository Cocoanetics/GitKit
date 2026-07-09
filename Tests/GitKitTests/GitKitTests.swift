import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif
@testable import GitKit

final class GitKitTests: XCTestCase {
    /// Proves the Swift layer links against — and calls into — the libgit2
    /// compiled from the pinned submodule, and that GitKit's version tracks it.
    func testLinksAgainstPinnedLibgit2() {
        let expected = String(Bundle.libgit2VersionFromPackage)
        XCTAssertEqual(GitKit.libgit2Version, expected,
                       "GitKit's compiled libgit2 must match the package version")
    }

    func testRuntimeInitShutdown() {
        XCTAssertEqual(GitKit.initialize(), 1)   // first init → refcount 1
#if canImport(Darwin) || canImport(Glibc) || canImport(Musl) || canImport(Android)
        let previousSIGPIPEHandler = signal(SIGPIPE, SIG_IGN)
        XCTAssertEqual(
            unsafeBitCast(previousSIGPIPEHandler, to: Int.self),
            unsafeBitCast(SIG_IGN, to: Int.self))
#endif
        XCTAssertEqual(GitKit.shutdown(), 0)      // back to 0
    }

    /// A minimal end-to-end exercise of the C API surfaced through GitKit.
    func testInitOpenInvalidRepoReturnsError() {
        GitKit.initialize()
        defer { GitKit.shutdown() }
        var repo: OpaquePointer?
        let rc = git_repository_open(&repo, "/nonexistent/path/\(UUID())")
        XCTAssertNotEqual(rc, 0, "opening a bogus path should fail, not crash")
    }
}

private extension Bundle {
    /// The libgit2 release this build is pinned to. Update alongside the
    /// submodule + package tag (kept in one place so the test documents intent).
    static var libgit2VersionFromPackage: String { "1.9.4" }
}

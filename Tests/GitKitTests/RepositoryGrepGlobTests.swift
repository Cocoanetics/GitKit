// Pure-Swift unit tests for `Repository.glob` — the in-house `*`/`?`
// matcher that replaced the libc `fnmatch(3)` call. Unlike the
// integration tests in `RepositoryGrepTests`, these don't fork system
// `git`, so they run on every platform — including Windows, which
// doesn't ship `fnmatch` and is exactly the reason the helper exists.
import Foundation
import Testing
@testable import GitKit

@Suite("Repository.grep glob helper")
struct RepositoryGrepGlobTests {

    @Test func starMatchesAnyRun() {
        #expect(Repository.glob(pattern: "*.swift", name: "Walker.swift"))
        #expect(Repository.glob(pattern: "*.swift", name: "sub/Walker.swift"))
        #expect(!Repository.glob(pattern: "*.swift", name: "Walker.md"))
    }

    @Test func questionMarkMatchesOne() {
        #expect(Repository.glob(pattern: "a?c", name: "abc"))
        #expect(Repository.glob(pattern: "a?c", name: "axc"))
        #expect(!Repository.glob(pattern: "a?c", name: "ac"))
        #expect(!Repository.glob(pattern: "a?c", name: "abcd"))
    }

    @Test func literalMustMatchExactly() {
        #expect(Repository.glob(pattern: "README", name: "README"))
        #expect(!Repository.glob(pattern: "README", name: "README.md"))
    }

    @Test func emptyPatternMatchesEmptyOnly() {
        #expect(Repository.glob(pattern: "", name: ""))
        #expect(!Repository.glob(pattern: "", name: "x"))
    }

    @Test func starAloneMatchesEverything() {
        #expect(Repository.glob(pattern: "*", name: ""))
        #expect(Repository.glob(pattern: "*", name: "anything/at/all.txt"))
    }
}

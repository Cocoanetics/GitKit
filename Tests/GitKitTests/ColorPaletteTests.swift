import Foundation
import Testing
@testable import GitKit

@Suite("ColorPalette")
struct ColorPaletteTests {

    // ANSI SGR shortcuts so the assertion strings stay readable.
    private let RED      = "\u{1B}[31m"
    private let GREEN    = "\u{1B}[32m"
    private let CYAN     = "\u{1B}[36m"
    private let BOLD     = "\u{1B}[1m"
    private let RESET    = "\u{1B}[m"

    // MARK: - element wrappers

    @Test func disabledPaletteIsAPassthrough() {
        let p = ColorPalette.disabled
        #expect(p.staged("modified: foo")   == "modified: foo")
        #expect(p.unstaged("foo")           == "foo")
        #expect(p.added("+x")               == "+x")
        #expect(p.removed("-x")             == "-x")
        #expect(p.frag("@@ -1 +1 @@")       == "@@ -1 +1 @@")
        #expect(p.meta("diff --git a/x b/x") == "diff --git a/x b/x")
        // Empty string short-circuits.
        #expect(p.staged("") == "")
    }

    @Test func enabledPaletteWrapsWithSGR() {
        let p = ColorPalette(enabled: true)
        #expect(p.staged("foo")   == "\(GREEN)foo\(RESET)")
        #expect(p.unstaged("foo") == "\(RED)foo\(RESET)")
        #expect(p.frag("@@")      == "\(CYAN)@@\(RESET)")
        #expect(p.meta("diff")    == "\(BOLD)diff\(RESET)")
    }

    // MARK: - patch colorizer

    @Test func colorizePatchHonorsLinePrefixes() {
        let p = ColorPalette(enabled: true)
        let input = """
        diff --git a/foo b/foo
        index abc..def 100644
        --- a/foo
        +++ b/foo
        @@ -1,2 +1,2 @@
         context line
        -old line
        +new line
        """
        let out = p.colorizePatch(input)
        #expect(out.contains("\(BOLD)diff --git a/foo b/foo\(RESET)"))
        #expect(out.contains("\(BOLD)index abc..def 100644\(RESET)"))
        #expect(out.contains("\(BOLD)--- a/foo\(RESET)"))
        #expect(out.contains("\(BOLD)+++ b/foo\(RESET)"))
        #expect(out.contains("\(CYAN)@@ -1,2 +1,2 @@\(RESET)"))
        #expect(out.contains("\(RED)-old line\(RESET)"))
        #expect(out.contains("\(GREEN)+new line\(RESET)"))
        // Context lines stay uncolored.
        #expect(out.contains(" context line"))
        #expect(!out.contains("\(RED) context line\(RESET)"))
    }

    @Test func colorizePatchIsPassthroughWhenDisabled() {
        let p = ColorPalette.disabled
        let input = "@@ -1 +1 @@\n-old\n+new\n"
        #expect(p.colorizePatch(input) == input)
    }

    @Test func colorizePatchPreservesTrailingNewline() {
        let withNL = "diff --git a/x b/x\n"
        let withoutNL = "diff --git a/x b/x"
        let p = ColorPalette(enabled: true)
        #expect(p.colorizePatch(withNL).hasSuffix("\n"))
        #expect(!p.colorizePatch(withoutNL).hasSuffix("\n"))
    }

    @Test func colorizePatchDoesNotConfuseHeadersWithDiffLines() {
        // The `+++ b/foo` header must be colored as a header (bold),
        // NOT as an added line (green). Same for `--- a/foo` vs `-`
        // diff lines.
        let p = ColorPalette(enabled: true)
        let input = "+++ b/foo\n--- a/foo\n+added\n-removed"
        let out = p.colorizePatch(input)
        #expect(out.contains("\(BOLD)+++ b/foo\(RESET)"))
        #expect(out.contains("\(BOLD)--- a/foo\(RESET)"))
        #expect(out.contains("\(GREEN)+added\(RESET)"))
        #expect(out.contains("\(RED)-removed\(RESET)"))
        // Negative: shouldn't accidentally green/red the headers.
        #expect(!out.contains("\(GREEN)+++ b/foo\(RESET)"))
        #expect(!out.contains("\(RED)--- a/foo\(RESET)"))
    }
}

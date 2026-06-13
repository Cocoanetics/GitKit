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

    // MARK: - diffstat colorizer

    @Test func colorizeDiffStatColorsTheHistogramBars() {
        // Real-git `--stat` shape: leading `+` run green, trailing `-`
        // run red; the path / count / `|` and the summary stay plain.
        let p = ColorPalette(enabled: true)
        let input = """
         addonly.txt |  1 +
         delonly.txt |  1 -
         mixed.txt   |  5 ++-
         3 files changed, 6 insertions(+), 1 deletion(-)
        """
        let out = p.colorizeDiffStat(input)
        // mixed: green `++` immediately followed by red `-`.
        #expect(out.contains("\(GREEN)++\(RESET)\(RED)-\(RESET)"))
        // add-only: a lone green `+`, no red wrapper trailing it.
        #expect(out.contains("\(GREEN)+\(RESET)"))
        // delete-only: a lone red `-`.
        #expect(out.contains("\(RED)-\(RESET)"))
        // Paths stay uncolored.
        #expect(out.contains(" mixed.txt   |"))
        #expect(!out.contains("\(GREEN) mixed.txt"))
        // The summary line has no `|`, so its `(+)` / `(-)` stay plain.
        #expect(out.contains("3 files changed, 6 insertions(+), 1 deletion(-)"))
        #expect(!out.contains("\(GREEN)+\(RESET))"))   // no colored `(+)`
    }

    @Test func colorizeDiffStatColorsScaledBars() {
        // A wide change scales the bar but keeps additions-before-
        // deletions ordering: the whole `+` run is green, the whole
        // `-` run red.
        let p = ColorPalette(enabled: true)
        let plus = String(repeating: "+", count: 42)
        let minus = String(repeating: "-", count: 18)
        let input = " big.txt | 170 \(plus)\(minus)\n"
        let out = p.colorizeDiffStat(input)
        #expect(out.contains("\(GREEN)\(plus)\(RESET)\(RED)\(minus)\(RESET)"))
        #expect(out.hasPrefix(" big.txt | 170 "))
    }

    @Test func colorizeDiffStatColorsBinarySizes() {
        // Binary delta: old size red, new size green — matching real
        // git — while the `Bin` / `->` / `bytes` scaffolding and the
        // path stay plain.
        let p = ColorPalette(enabled: true)
        let binary = " bin.dat | Bin 12 -> 14 bytes"
        let out = p.colorizeDiffStat(binary)
        #expect(out == " bin.dat | Bin \(RED)12\(RESET) -> \(GREEN)14\(RESET) bytes")
    }

    @Test func colorizeDiffStatLeavesSummaryPlain() {
        // The `N files changed …` summary has no `|`, so its `(+)` /
        // `(-)` pass through byte-for-byte.
        let p = ColorPalette(enabled: true)
        let summary = " 1 file changed, 0 insertions(+), 0 deletions(-)"
        #expect(p.colorizeDiffStat(summary) == summary)
    }

    @Test func colorizeDiffStatIsPassthroughWhenDisabled() {
        let p = ColorPalette.disabled
        let input = " mixed.txt | 5 ++-\n 1 file changed\n"
        #expect(p.colorizeDiffStat(input) == input)
    }

    @Test func colorizeDiffStatPreservesTrailingNewline() {
        let p = ColorPalette(enabled: true)
        #expect(p.colorizeDiffStat(" f | 1 +\n").hasSuffix("\n"))
        #expect(!p.colorizeDiffStat(" f | 1 +").hasSuffix("\n"))
    }
}

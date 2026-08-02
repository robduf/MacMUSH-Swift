import Foundation
import MudEngine

final class AnsiParserTests {

    private func textOps(_ ops: [AnsiOp]) -> [StyledText] {
        ops.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
    }

    func testBasicColorAndReset() {
        var p = AnsiParser()
        let t = textOps(p.feed("\u{1B}[31mred\u{1B}[0m plain"))
        XCTAssertEqual(t.count, 2)
        XCTAssertEqual(t[0].text, "red")
        XCTAssertEqual(t[0].style.fg, .indexed(1))
        XCTAssertEqual(t[1].text, " plain")
        XCTAssertEqual(t[1].style.fg, .defaultColor)
    }

    func testBoldBright256AndTruecolor() {
        var p = AnsiParser()
        let t = textOps(p.feed("\u{1B}[1;33mgold\u{1B}[38;5;208morange\u{1B}[38;2;255;105;180mpink"))
        XCTAssertTrue(t[0].style.bold)
        XCTAssertEqual(t[0].style.fg, .indexed(3))
        XCTAssertEqual(t[1].style.fg, .indexed(208))
        XCTAssertEqual(t[2].style.fg, .rgb(255, 105, 180))
    }

    func testBackgroundAndBrightForeground() {
        var p = AnsiParser()
        let t = textOps(p.feed("\u{1B}[44;97mwhite-on-blue\u{1B}[49mnobg"))
        XCTAssertEqual(t[0].style.bg, .indexed(4))
        XCTAssertEqual(t[0].style.fg, .indexed(15))
        XCTAssertEqual(t[1].style.bg, .defaultColor)
    }

    func testEscapeSplitAcrossChunks() {
        var p = AnsiParser()
        let ops1 = p.feed("before\u{1B}[3")
        let ops2 = p.feed("2mgreen")
        XCTAssertEqual(textOps(ops1)[0].text, "before")
        let t2 = textOps(ops2)
        XCTAssertEqual(t2[0].text, "green")
        XCTAssertEqual(t2[0].style.fg, .indexed(2))
    }

    func testNewlinesAndCarriageReturns() {
        var p = AnsiParser()
        let ops = p.feed("line1\r\nline2\nline3\r")
        let kinds: [String] = ops.map {
            switch $0 {
            case .text: return "text"
            case .newline: return "newline"
            case .bell: return "bell"
            }
        }
        XCTAssertEqual(kinds, ["text", "newline", "text", "newline", "text"])
    }

    func testCRLFLineEndings() {
        // MUDs almost always send CRLF. Swift groups "\r\n" into one Character,
        // so the parser must iterate unicode scalars to see the "\n" — otherwise
        // every line runs together.
        var p = AnsiParser()
        let ops = p.feed("alpha\r\nbeta\r\ngamma")
        let kinds: [String] = ops.map {
            switch $0 {
            case .text: return "text"
            case .newline: return "newline"
            case .bell: return "bell"
            }
        }
        XCTAssertEqual(kinds, ["text", "newline", "text", "newline", "text"])
        XCTAssertEqual(textOps(ops).map { $0.text }, ["alpha", "beta", "gamma"])
    }

    func testStylePersistsAcrossChunks() {
        var p = AnsiParser()
        _ = p.feed("\u{1B}[35m")
        let t = textOps(p.feed("still magenta"))
        XCTAssertEqual(t[0].style.fg, .indexed(5))
    }

    func testUnderlineItalicStrikeToggles() {
        var p = AnsiParser()
        let t = textOps(p.feed("\u{1B}[4;3;9mfancy\u{1B}[24;23;29mplain"))
        XCTAssertEqual([t[0].style.underline, t[0].style.italic, t[0].style.strikethrough], [true, true, true])
        XCTAssertEqual([t[1].style.underline, t[1].style.italic, t[1].style.strikethrough], [false, false, false])
    }

    func testNonSGRSequencesSwallowed() {
        var p = AnsiParser()
        let t = textOps(p.feed("a\u{1B}[2Jb\u{1B}[10;20Hc\u{1B}[Kd"))
        XCTAssertEqual(t.map { $0.text }.joined(), "abcd")
    }

    func testOSCSequencesSwallowed() {
        var p = AnsiParser()
        let t = textOps(p.feed("x\u{1B}]0;title\u{07}y\u{1B}]2;t2\u{1B}\\z"))
        XCTAssertEqual(t.map { $0.text }.joined(), "xyz")
    }

    func testEmptySGRResets() {
        var p = AnsiParser()
        let t = textOps(p.feed("\u{1B}[31mred\u{1B}[mnormal"))
        XCTAssertEqual(t[1].style.fg, .defaultColor)
    }

    func testBellEmitted() {
        var p = AnsiParser()
        let ops = p.feed("ding\u{07}")
        XCTAssertTrue(ops.contains(.bell))
    }
}

// Every test in this file, listed because a plain executable has no runtime
// discovery to find them for us. A test missing from here never runs.
// See TestHarness.swift.
extension AnsiParserTests {
    static let suite = TestSuite("AnsiParserTests", [
        ("testBasicColorAndReset", { AnsiParserTests().testBasicColorAndReset() }),
        ("testBoldBright256AndTruecolor", { AnsiParserTests().testBoldBright256AndTruecolor() }),
        ("testBackgroundAndBrightForeground", { AnsiParserTests().testBackgroundAndBrightForeground() }),
        ("testEscapeSplitAcrossChunks", { AnsiParserTests().testEscapeSplitAcrossChunks() }),
        ("testNewlinesAndCarriageReturns", { AnsiParserTests().testNewlinesAndCarriageReturns() }),
        ("testCRLFLineEndings", { AnsiParserTests().testCRLFLineEndings() }),
        ("testStylePersistsAcrossChunks", { AnsiParserTests().testStylePersistsAcrossChunks() }),
        ("testUnderlineItalicStrikeToggles", { AnsiParserTests().testUnderlineItalicStrikeToggles() }),
        ("testNonSGRSequencesSwallowed", { AnsiParserTests().testNonSGRSequencesSwallowed() }),
        ("testOSCSequencesSwallowed", { AnsiParserTests().testOSCSequencesSwallowed() }),
        ("testEmptySGRResets", { AnsiParserTests().testEmptySGRResets() }),
        ("testBellEmitted", { AnsiParserTests().testBellEmitted() }),
    ])
}

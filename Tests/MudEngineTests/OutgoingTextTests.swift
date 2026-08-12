import Foundation
import MudEngine

final class OutgoingTextTests {

    // MARK: Leaving well alone

    func testPlainASCIIIsUntouched() {
        let line = "page Caitlin=Sounds good, I'll be around later."
        XCTAssertEqual(OutgoingText.tidy(line), line)
    }

    func testEmptyStringStaysEmpty() {
        XCTAssertEqual(OutgoingText.tidy(""), "")
    }

    /// The one substitution deliberately *not* made. People type `%r`, `%t` and
    /// `%b` into MUSH clients on purpose; escaping `%` to `%%` to protect the
    /// occasional "50% chance" would break far more than it saved.
    func testPercentIsNotEscaped() {
        XCTAssertEqual(OutgoingText.tidy("say 50% chance"), "say 50% chance")
        XCTAssertEqual(OutgoingText.tidy("pose smiles.%rThen leaves."),
                       "pose smiles.%rThen leaves.")
    }

    // MARK: Line breaks

    func testNewlineBecomesPercentR() {
        XCTAssertEqual(OutgoingText.tidy("first\nsecond"), "first%rsecond")
    }

    /// The whole block has to arrive as ONE command, or `page x=` covers only
    /// the first line and the rest land on the game as bare input.
    func testMultiLineBlockCollapsesToASingleLine() {
        let out = OutgoingText.tidy("page Caitlin=One.\nTwo.\nThree.")
        XCTAssertEqual(out, "page Caitlin=One.%rTwo.%rThree.")
        XCTAssertFalse(out.contains("\n"))
    }

    /// A pasted \r\n is one break, not two. Getting this wrong doubles every
    /// line break in anything copied out of a Windows-flavoured source.
    func testCRLFIsOneBreak() {
        XCTAssertEqual(OutgoingText.tidy("first\r\nsecond"), "first%rsecond")
    }

    func testLoneCarriageReturnIsABreak() {
        XCTAssertEqual(OutgoingText.tidy("first\rsecond"), "first%rsecond")
    }

    /// Pasted text nearly always ends in a newline, and a trailing `%r` puts a
    /// blank line on the end of every pose.
    func testTrailingNewlinesAreDropped() {
        XCTAssertEqual(OutgoingText.tidy("a pose\n"), "a pose")
        XCTAssertEqual(OutgoingText.tidy("a pose\n\n\n"), "a pose")
        XCTAssertEqual(OutgoingText.tidy("a pose\r\n"), "a pose")
    }

    /// Only from the end. A leading break is rare enough that when it happens
    /// it was meant.
    func testLeadingNewlineIsKept() {
        XCTAssertEqual(OutgoingText.tidy("\nstarts blank"), "%rstarts blank")
    }

    func testNothingButNewlinesComesBackEmpty() {
        XCTAssertEqual(OutgoingText.tidy("\n\n"), "")
    }

    func testTabBecomesPercentT() {
        XCTAssertEqual(OutgoingText.tidy("name\tvalue"), "name%tvalue")
    }

    // MARK: Punctuation

    func testCurlyApostropheStraightens() {
        // "He's" with the right single quote macOS and every word processor use.
        XCTAssertEqual(OutgoingText.tidy("He\u{2019}s a playboy"), "He's a playboy")
    }

    func testCurlySingleQuotesStraighten() {
        XCTAssertEqual(OutgoingText.tidy("\u{2018}quoted\u{2019}"), "'quoted'")
    }

    func testCurlyDoubleQuotesStraighten() {
        XCTAssertEqual(OutgoingText.tidy("\u{201C}quoted\u{201D}"), "\"quoted\"")
    }

    /// An em dash was two hyphens before autocorrect got to it, so that is what
    /// it goes back to. An en dash was one.
    func testDashes() {
        XCTAssertEqual(OutgoingText.tidy("Donovan \u{2014} 42"), "Donovan -- 42")
        XCTAssertEqual(OutgoingText.tidy("20\u{2013}30"), "20-30")
    }

    func testEllipsis() {
        XCTAssertEqual(OutgoingText.tidy("well\u{2026}"), "well...")
    }

    func testNonBreakingSpaceBecomesASpace() {
        XCTAssertEqual(OutgoingText.tidy("a\u{00A0}b"), "a b")
    }

    func testZeroWidthCharactersVanish() {
        XCTAssertEqual(OutgoingText.tidy("a\u{200B}b\u{FEFF}c"), "abc")
    }

    // MARK: Everything else outside ASCII

    func testAccentsFoldToPlainLetters() {
        XCTAssertEqual(OutgoingText.tidy("caf\u{00E9} na\u{00EF}ve"), "cafe naive")
    }

    /// A combining sequence is one Character and has to fold the same way a
    /// precomposed one does, or the answer depends on which app you copied from.
    func testCombiningAccentFoldsToo() {
        XCTAssertEqual(OutgoingText.tidy("cafe\u{0301}"), "cafe")
    }

    /// Nothing sensible to fold to, and a server that cannot render it is better
    /// handed nothing than handed a broken byte sequence.
    func testUnmappableCharactersAreDropped() {
        XCTAssertEqual(OutgoingText.tidy("hi \u{1F600} there"), "hi  there")
        XCTAssertEqual(OutgoingText.tidy("\u{4F60}\u{597D}"), "")
    }

    /// An ESC pasted out of a terminal would otherwise go out as the start of an
    /// ANSI sequence.
    func testControlCharactersAreDropped() {
        XCTAssertEqual(OutgoingText.tidy("a\u{1B}[31mb"), "a[31mb")
        XCTAssertEqual(OutgoingText.tidy("a\u{00}b\u{7F}c"), "abc")
    }

    /// Whatever comes out has to be safe to hand to `TelnetParser.encodeLine`,
    /// which sends one line terminated by CRLF. An embedded break would make it
    /// two commands and undo the entire point.
    func testResultNeverContainsALineBreak() {
        for input in ["a\nb", "a\r\nb", "a\rb", "\n\n", "a\n\n\nb", "x\ty"] {
            let out = OutgoingText.tidy(input)
            XCTAssertFalse(out.contains("\n"))
            XCTAssertFalse(out.contains("\r"))
        }
    }

    /// Everything at once, from the paste that started this: curly quotes, an
    /// em dash and real line breaks in a single multi-line page.
    func testTheWholePasteFromShangrila() {
        let pasted = "page Caitlin=\u{201C}Donovan\u{201D} \u{2014} 42, dark hair.\n"
                   + "He\u{2019}s retired\u{2026}\n"
                   + "\u{201C}Jace\u{201D} \u{2014} early 20s.\n"

        XCTAssertEqual(OutgoingText.tidy(pasted),
                       "page Caitlin=\"Donovan\" -- 42, dark hair."
                       + "%rHe's retired..."
                       + "%r\"Jace\" -- early 20s.")
    }

    // MARK: The switch that turns it off

    /// On for a world file that predates the setting. This departs from how
    /// `echoInput` and `linkifyURLs` decode — they default to the old behaviour
    /// so upgrading changes nothing — because here the old behaviour is the bug.
    func testTidyDefaultsOnForWorldsSavedBeforeItExisted() throws {
        let json = #"{ "name": "Shang", "host": "shangrilamux.com", "port": 9999 }"#
            .data(using: .utf8)!
        XCTAssertTrue(try JSONDecoder().decode(WorldConfig.self, from: json).tidyOutgoing)
    }

    func testTidyOffSurvivesARoundTrip() throws {
        var world = WorldConfig(name: "Raw")
        world.tidyOutgoing = false

        let data = try JSONEncoder().encode(world)
        XCTAssertFalse(try JSONDecoder().decode(WorldConfig.self, from: data).tidyOutgoing)
    }
}

// Every test in this file, listed because a plain executable has no runtime
// discovery to find them for us. A test missing from here never runs.
// See TestHarness.swift.
extension OutgoingTextTests {
    static let suite = TestSuite("OutgoingTextTests", [
        ("testPlainASCIIIsUntouched", { OutgoingTextTests().testPlainASCIIIsUntouched() }),
        ("testEmptyStringStaysEmpty", { OutgoingTextTests().testEmptyStringStaysEmpty() }),
        ("testPercentIsNotEscaped", { OutgoingTextTests().testPercentIsNotEscaped() }),
        ("testNewlineBecomesPercentR", { OutgoingTextTests().testNewlineBecomesPercentR() }),
        ("testMultiLineBlockCollapsesToASingleLine", { OutgoingTextTests().testMultiLineBlockCollapsesToASingleLine() }),
        ("testCRLFIsOneBreak", { OutgoingTextTests().testCRLFIsOneBreak() }),
        ("testLoneCarriageReturnIsABreak", { OutgoingTextTests().testLoneCarriageReturnIsABreak() }),
        ("testTrailingNewlinesAreDropped", { OutgoingTextTests().testTrailingNewlinesAreDropped() }),
        ("testLeadingNewlineIsKept", { OutgoingTextTests().testLeadingNewlineIsKept() }),
        ("testNothingButNewlinesComesBackEmpty", { OutgoingTextTests().testNothingButNewlinesComesBackEmpty() }),
        ("testTabBecomesPercentT", { OutgoingTextTests().testTabBecomesPercentT() }),
        ("testCurlyApostropheStraightens", { OutgoingTextTests().testCurlyApostropheStraightens() }),
        ("testCurlySingleQuotesStraighten", { OutgoingTextTests().testCurlySingleQuotesStraighten() }),
        ("testCurlyDoubleQuotesStraighten", { OutgoingTextTests().testCurlyDoubleQuotesStraighten() }),
        ("testDashes", { OutgoingTextTests().testDashes() }),
        ("testEllipsis", { OutgoingTextTests().testEllipsis() }),
        ("testNonBreakingSpaceBecomesASpace", { OutgoingTextTests().testNonBreakingSpaceBecomesASpace() }),
        ("testZeroWidthCharactersVanish", { OutgoingTextTests().testZeroWidthCharactersVanish() }),
        ("testAccentsFoldToPlainLetters", { OutgoingTextTests().testAccentsFoldToPlainLetters() }),
        ("testCombiningAccentFoldsToo", { OutgoingTextTests().testCombiningAccentFoldsToo() }),
        ("testUnmappableCharactersAreDropped", { OutgoingTextTests().testUnmappableCharactersAreDropped() }),
        ("testControlCharactersAreDropped", { OutgoingTextTests().testControlCharactersAreDropped() }),
        ("testResultNeverContainsALineBreak", { OutgoingTextTests().testResultNeverContainsALineBreak() }),
        ("testTheWholePasteFromShangrila", { OutgoingTextTests().testTheWholePasteFromShangrila() }),
        ("testTidyDefaultsOnForWorldsSavedBeforeItExisted", { try OutgoingTextTests().testTidyDefaultsOnForWorldsSavedBeforeItExisted() }),
        ("testTidyOffSurvivesARoundTrip", { try OutgoingTextTests().testTidyOffSurvivesARoundTrip() }),
    ])
}

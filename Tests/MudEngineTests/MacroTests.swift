import Foundation
import MudEngine

final class MacroTests {

    // MARK: Display

    func testDisplayLabelPrefersTheLabel() {
        let macro = Macro(label: "Who", sendText: "+who")
        XCTAssertEqual(macro.displayLabel, "Who")
    }

    /// A row where only the command has been filled in is the common half-done
    /// state, and it has to produce a button you can still read.
    func testDisplayLabelFallsBackToTheCommand() {
        let macro = Macro(label: "", sendText: "+who/find F H any/R29")
        XCTAssertEqual(macro.displayLabel, "+who/find F H any/R29")
    }

    /// A multi-line macro shows only its first line — the whole thing would
    /// stretch the button to the height of the palette.
    func testDisplayLabelUsesOnlyTheFirstLine() {
        let macro = Macro(sendText: "pose waves.\n+who\nlook")
        XCTAssertEqual(macro.displayLabel, "pose waves.")
    }

    /// Whitespace-only is empty for this purpose; a button captioned with three
    /// spaces looks broken rather than blank.
    func testDisplayLabelOfAnEmptyMacro() {
        XCTAssertEqual(Macro().displayLabel, "(empty)")
        XCTAssertEqual(Macro(label: "   ", sendText: "  ").displayLabel, "(empty)")
    }

    func testDisplayLabelTrims() {
        XCTAssertEqual(Macro(label: "  Who  ").displayLabel, "Who")
        XCTAssertEqual(Macro(sendText: "  +who  ").displayLabel, "+who")
    }

    // MARK: Identity

    func testDistinctIDs() {
        XCTAssertNotEqual(Macro().id, Macro().id)
    }

    // MARK: Codable

    func testCodableRoundTrip() throws {
        let macro = Macro(label: "Find",
                          sendText: "+who/find F H any/R29",
                          sendImmediately: false,
                          shortcut: KeyShortcut(keyCode: 3, modifiers: 1_048_576, label: "⌘F"))

        let decoded = try JSONDecoder().decode(
            Macro.self, from: try JSONEncoder().encode(macro))

        XCTAssertEqual(decoded, macro)
        XCTAssertEqual(decoded.id, macro.id)
        XCTAssertEqual(decoded.shortcut?.keyCode, 3)
        XCTAssertEqual(decoded.shortcut?.modifiers, 1_048_576)
        XCTAssertEqual(decoded.shortcut?.label, "⌘F")
    }

    /// `sendImmediately` defaults true, so the value that a missing `encode`
    /// line would silently swallow is false. Same shape of bug as the per-world
    /// toggles: the setting appears to un-tick itself between launches.
    func testSendImmediatelySurvivesBeingOff() throws {
        let macro = Macro(label: "Find", sendText: "+who/find ", sendImmediately: false)

        let decoded = try JSONDecoder().decode(
            Macro.self, from: try JSONEncoder().encode(macro))

        XCTAssertFalse(decoded.sendImmediately)
    }

    /// A macro with no key bound must round-trip as *no key bound*, not as a
    /// shortcut on keyCode 0 — which is the letter A, and would fire every time
    /// it was typed.
    func testAbsentShortcutStaysAbsent() throws {
        let macro = Macro(label: "Who", sendText: "+who")
        XCTAssertNil(macro.shortcut)

        let decoded = try JSONDecoder().decode(
            Macro.self, from: try JSONEncoder().encode(macro))

        XCTAssertNil(decoded.shortcut)
    }

    /// Hand-written or older JSON with most keys missing still has to load.
    func testLenientDecodeOfPartialJSON() throws {
        let json = """
        { "label": "Who", "sendText": "+who" }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(Macro.self, from: json)

        XCTAssertEqual(decoded.label, "Who")
        XCTAssertEqual(decoded.sendText, "+who")
        XCTAssertFalse(decoded.id.isEmpty)      // minted, not crashed
        XCTAssertTrue(decoded.sendImmediately)  // the default
        XCTAssertNil(decoded.shortcut)
    }

    func testLenientDecodeOfPartialShortcutJSON() throws {
        let json = """
        { "label": "Who", "sendText": "+who", "shortcut": { "keyCode": 122 } }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(Macro.self, from: json)

        XCTAssertEqual(decoded.shortcut?.keyCode, 122)
        XCTAssertEqual(decoded.shortcut?.modifiers, 0)
        XCTAssertEqual(decoded.shortcut?.label, "")
    }

    // MARK: Matching

    func testShortcutMatchesOnKeyCodeAndModifiers() {
        let shortcut = KeyShortcut(keyCode: 40, modifiers: 1_048_576, label: "⌘K")

        XCTAssertTrue(shortcut.matches(keyCode: 40, modifiers: 1_048_576))
        XCTAssertFalse(shortcut.matches(keyCode: 41, modifiers: 1_048_576))
        XCTAssertFalse(shortcut.matches(keyCode: 40, modifiers: 0))
    }

    /// Extra modifier bits are a different combination, not a near miss. ⇧⌘K
    /// must not fire a macro bound to ⌘K, or every shifted variant would be a
    /// duplicate of the unshifted one.
    func testShortcutRejectsExtraModifiers() {
        let command: UInt = 1_048_576
        let shift: UInt = 131_072
        let shortcut = KeyShortcut(keyCode: 40, modifiers: command, label: "⌘K")

        XCTAssertFalse(shortcut.matches(keyCode: 40, modifiers: command | shift))
    }

    /// The stale-caption case: the label drifts after a keyboard layout change
    /// but the binding underneath keeps working, which is the whole reason the
    /// two are stored separately.
    func testShortcutMatchingIgnoresTheLabel() {
        let shortcut = KeyShortcut(keyCode: 40, modifiers: 1_048_576, label: "nonsense")
        XCTAssertTrue(shortcut.matches(keyCode: 40, modifiers: 1_048_576))
    }

    /// A bare function key is bound with no modifiers at all, so zero has to be
    /// a legitimate combination rather than a stand-in for "unbound". Being
    /// unbound is `shortcut == nil`, tested above.
    func testBareFunctionKeyMatches() {
        let f1 = KeyShortcut(keyCode: 122, modifiers: 0, label: "F1")
        XCTAssertTrue(f1.matches(keyCode: 122, modifiers: 0))
    }
}

// Every test in this file, listed because a plain executable has no runtime
// discovery to find them for us. A test missing from here never runs.
// See TestHarness.swift.
extension MacroTests {
    static let suite = TestSuite("MacroTests", [
        ("testDisplayLabelPrefersTheLabel", { MacroTests().testDisplayLabelPrefersTheLabel() }),
        ("testDisplayLabelFallsBackToTheCommand", { MacroTests().testDisplayLabelFallsBackToTheCommand() }),
        ("testDisplayLabelUsesOnlyTheFirstLine", { MacroTests().testDisplayLabelUsesOnlyTheFirstLine() }),
        ("testDisplayLabelOfAnEmptyMacro", { MacroTests().testDisplayLabelOfAnEmptyMacro() }),
        ("testDisplayLabelTrims", { MacroTests().testDisplayLabelTrims() }),
        ("testDistinctIDs", { MacroTests().testDistinctIDs() }),
        ("testCodableRoundTrip", { try MacroTests().testCodableRoundTrip() }),
        ("testSendImmediatelySurvivesBeingOff", { try MacroTests().testSendImmediatelySurvivesBeingOff() }),
        ("testAbsentShortcutStaysAbsent", { try MacroTests().testAbsentShortcutStaysAbsent() }),
        ("testLenientDecodeOfPartialJSON", { try MacroTests().testLenientDecodeOfPartialJSON() }),
        ("testLenientDecodeOfPartialShortcutJSON", { try MacroTests().testLenientDecodeOfPartialShortcutJSON() }),
        ("testShortcutMatchesOnKeyCodeAndModifiers", { MacroTests().testShortcutMatchesOnKeyCodeAndModifiers() }),
        ("testShortcutRejectsExtraModifiers", { MacroTests().testShortcutRejectsExtraModifiers() }),
        ("testShortcutMatchingIgnoresTheLabel", { MacroTests().testShortcutMatchingIgnoresTheLabel() }),
        ("testBareFunctionKeyMatches", { MacroTests().testBareFunctionKeyMatches() }),
    ])
}

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

    // MARK: Colour

    func testColorRoundTrip() throws {
        let macro = Macro(label: "Who", sendText: "+who", color: .teal)

        let decoded = try JSONDecoder().decode(
            Macro.self, from: try JSONEncoder().encode(macro))

        XCTAssertEqual(decoded.color, .teal)
        XCTAssertEqual(decoded, macro)
    }

    /// Every macro written before the colour existed has no `color` key, and all
    /// of them have to keep loading — as uncoloured, which is what they looked
    /// like when they were saved.
    func testAbsentColorDecodesAsPlain() throws {
        let json = """
        { "label": "Who", "sendText": "+who" }
        """.data(using: .utf8)!

        XCTAssertEqual(try JSONDecoder().decode(Macro.self, from: json).color, .plain)
    }

    /// The reason `color` is decoded as a string and then looked up, rather than
    /// asked for as a `SwatchColor`: asking for the enum makes an unrecognised
    /// name *throw*, and a throw in a macro takes the whole world file with it —
    /// every trigger, alias and timer in it — over one unknown colour. A name
    /// from a newer build, or a typo in a hand-edited file, must cost the colour
    /// and nothing else.
    func testUnknownColorNameDecodesAsPlainRatherThanThrowing() throws {
        let json = """
        { "label": "Who", "sendText": "+who", "color": "chartreuse" }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(Macro.self, from: json)

        XCTAssertEqual(decoded.color, .plain)
        XCTAssertEqual(decoded.label, "Who")     // the rest of the macro survived
        XCTAssertEqual(decoded.sendText, "+who")
    }

    /// A colour wrong-typed on disk is the same problem as an unknown name, and
    /// gets the same answer. `decodeIfPresent` throws on a type mismatch too.
    func testNonStringColorDecodesAsPlainRatherThanThrowing() throws {
        let json = """
        { "label": "Who", "sendText": "+who", "color": 3 }
        """.data(using: .utf8)!

        XCTAssertEqual(try JSONDecoder().decode(Macro.self, from: json).color, .plain)
    }

    /// These raw values are the on-disk format, not an implementation detail.
    /// Rename a case and every world file saved before the rename quietly loses
    /// its colours — the lenient decode above is exactly what would hide it.
    func testColorNamesAreStableOnDisk() {
        XCTAssertEqual(SwatchColor.allCases.map { $0.rawValue },
                       ["plain", "red", "orange", "yellow",
                        "green", "teal", "blue", "purple", "pink"])
    }

    /// `allCases` is what builds the Settings popup, and both directions of that
    /// menu are index arithmetic against this array: the row's colour is found
    /// by `firstIndex(of:)`, and a pick comes back as `allCases[index]`. The
    /// lookup falls back to item 0 when it finds nothing, so item 0 has to be
    /// the harmless one.
    func testPlainIsTheFirstColor() {
        XCTAssertEqual(SwatchColor.allCases.first, .plain)
        XCTAssertEqual(Macro().color, .plain)
    }

    /// Nine menu items, nine captions, none of them blank.
    func testEveryColorHasADisplayName() {
        XCTAssertEqual(SwatchColor.allCases.count, 9)
        for color in SwatchColor.allCases {
            XCTAssertFalse(color.displayName.isEmpty)
        }
        XCTAssertEqual(SwatchColor.plain.displayName, "None")
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
        ("testColorRoundTrip", { try MacroTests().testColorRoundTrip() }),
        ("testAbsentColorDecodesAsPlain", { try MacroTests().testAbsentColorDecodesAsPlain() }),
        ("testUnknownColorNameDecodesAsPlainRatherThanThrowing", { try MacroTests().testUnknownColorNameDecodesAsPlainRatherThanThrowing() }),
        ("testNonStringColorDecodesAsPlainRatherThanThrowing", { try MacroTests().testNonStringColorDecodesAsPlainRatherThanThrowing() }),
        ("testColorNamesAreStableOnDisk", { MacroTests().testColorNamesAreStableOnDisk() }),
        ("testPlainIsTheFirstColor", { MacroTests().testPlainIsTheFirstColor() }),
        ("testEveryColorHasADisplayName", { MacroTests().testEveryColorHasADisplayName() }),
        ("testShortcutMatchesOnKeyCodeAndModifiers", { MacroTests().testShortcutMatchesOnKeyCodeAndModifiers() }),
        ("testShortcutRejectsExtraModifiers", { MacroTests().testShortcutRejectsExtraModifiers() }),
        ("testShortcutMatchingIgnoresTheLabel", { MacroTests().testShortcutMatchingIgnoresTheLabel() }),
        ("testBareFunctionKeyMatches", { MacroTests().testBareFunctionKeyMatches() }),
    ])
}

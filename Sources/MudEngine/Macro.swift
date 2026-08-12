// Quick-reference macros: labelled buttons that send something to the world,
// each optionally bound to a key combination.
//
// Foundation only — no AppKit — so this lives in the engine with the rest of a
// world's saved state and can be tested without a window server.
//
// Both types decode leniently, for the same reason `WorldConfig` does: a field
// added here later must not make every world file written before it unreadable.

import Foundation

/// One key combination, stored the way it has to be *matched* rather than the
/// way it's drawn.
///
/// `keyCode` is the physical key. That's what keeps a binding working when the
/// keyboard layout changes underneath it, and it's the only thing function keys
/// and arrows can be identified by at all — they have no character to speak of.
///
/// `label` is the drawn form, captured at the moment the key was pressed,
/// because that is the only time the user's own layout is in the room. Change
/// layouts afterwards and the label can go stale while the binding itself keeps
/// working; re-recording the shortcut catches it up. A wrong caption is a much
/// smaller problem than a shortcut that stops firing, which is the trade this
/// makes.
public struct KeyShortcut: Equatable, Codable, Sendable {
    public var keyCode: UInt16
    /// An `NSEvent.ModifierFlags` raw value, already reduced to the
    /// device-independent bits. Untyped because the engine has no AppKit; the
    /// app side is the only thing that puts a meaning to it.
    public var modifiers: UInt
    /// Display only. Never compared, never matched against.
    public var label: String

    public init(keyCode: UInt16, modifiers: UInt, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    /// Whether a key press should fire this shortcut.
    ///
    /// The caller is responsible for having reduced the event's modifier flags
    /// to the four that a shortcut can be built from — shift, control, option,
    /// command — before asking. Caps lock and the function bit ride along on
    /// real events and would otherwise turn a working binding into a dead one
    /// the moment caps lock happened to be down.
    ///
    /// `label` is deliberately no part of this. It's a caption that can go stale
    /// when the keyboard layout changes; matching on it would promote that
    /// cosmetic staleness into a shortcut that stops firing.
    public func matches(keyCode: UInt16, modifiers: UInt) -> Bool {
        self.keyCode == keyCode && self.modifiers == modifiers
    }

    private enum CodingKeys: String, CodingKey {
        case keyCode, modifiers, label
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.keyCode = try c.decodeIfPresent(UInt16.self, forKey: .keyCode) ?? 0
        self.modifiers = try c.decodeIfPresent(UInt.self, forKey: .modifiers) ?? 0
        self.label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
    }
}

/// The app's fixed set of colours, used wherever something in a world can be
/// tinted: a macro button's fill, a trigger's highlight.
///
/// A fixed set rather than a free-form colour, so the shades can be chosen once
/// to stay readable against both a light and a dark palette, and so a label on
/// top can be black or white to suit without asking anyone to think about it.
///
/// One set of *names*, two sets of shades. What reads well as a button fill is
/// too dark to read as text on the scrollback's near-black, so the app side
/// keeps a separate table for each; see `Swatch.swift`. Sharing the names is the
/// point — "the red one" means the same thing in the macro list and the trigger
/// list, and a world file records `"red"` either way.
///
/// The case is named `plain` rather than `none` on purpose. `none` is also
/// `Optional`'s case, and `SwatchColor(rawValue: x) ?? .none` is genuinely
/// ambiguous — the compiler can read that `.none` as an empty optional and hand
/// back the wrong type. `plain` has no such twin.
///
/// The actual shades live on the app side; the engine has no AppKit and does not
/// need one.
public enum SwatchColor: String, Codable, Sendable, CaseIterable {
    case plain, red, orange, yellow, green, teal, blue, purple, pink

    /// What the menu item says.
    public var displayName: String {
        switch self {
        case .plain:  return "None"
        case .red:    return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green:  return "Green"
        case .teal:   return "Teal"
        case .blue:   return "Blue"
        case .purple: return "Purple"
        case .pink:   return "Pink"
        }
    }

    /// Build from a name that might be missing, might be nonsense, and must not
    /// be allowed to fail.
    ///
    /// Every colour in a world file arrives through here. The alternative —
    /// decoding straight into `SwatchColor` — makes an unrecognised name *throw*,
    /// and a throw while decoding a rule loses the entire world it belongs to:
    /// every trigger, alias, timer and macro, over one bad string. A name written
    /// by a newer build, or a typo in a hand-edited file, should cost the colour
    /// and nothing else.
    public init(lenient name: String?) {
        self = SwatchColor(rawValue: name ?? "") ?? .plain
    }
}

/// A single button in the macro palette.
public struct Macro: Equatable, Codable, Sendable {
    public var id: String
    /// What the button says. Falls back to the command itself when empty, so a
    /// half-filled row is still usable rather than a blank button.
    public var label: String
    /// What it sends. Newlines split it into separate lines, the same as typing
    /// a multi-line pose into the command box does.
    public var sendText: String
    /// True fires it. False puts it in the command box with the caret at the
    /// end, for the ones with a bit in the middle you change every time.
    public var sendImmediately: Bool
    /// nil means the button is the only way to reach it.
    public var shortcut: KeyShortcut?
    /// What colour to paint the button. `.plain` leaves it the standard grey.
    public var color: SwatchColor

    public init(id: String = UUID().uuidString,
                label: String = "",
                sendText: String = "",
                sendImmediately: Bool = true,
                shortcut: KeyShortcut? = nil,
                color: SwatchColor = .plain) {
        self.id = id
        self.label = label
        self.sendText = sendText
        self.sendImmediately = sendImmediately
        self.shortcut = shortcut
        self.color = color
    }

    /// What to actually draw on the button.
    public var displayLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        // An unnamed macro shows its first line. Better than an empty button,
        // and it's usually what someone would have typed as the name anyway.
        let firstLine = sendText.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let command = firstLine.trimmingCharacters(in: .whitespaces)
        return command.isEmpty ? "(empty)" : command
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, sendText, sendImmediately, shortcut, color
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        self.sendText = try c.decodeIfPresent(String.self, forKey: .sendText) ?? ""
        self.sendImmediately = try c.decodeIfPresent(Bool.self, forKey: .sendImmediately) ?? true
        self.shortcut = try c.decodeIfPresent(KeyShortcut.self, forKey: .shortcut)
        // Decoded as a string and then looked up, rather than as `SwatchColor`
        // directly. Asking for the enum makes an unrecognised name *throw*, and a
        // throw here loses the whole world — every trigger, alias and timer in it
        // — over one unknown colour. This way a name from a newer build, or a
        // typo in a hand-edited file, costs you the colour and nothing else.
        //
        // `try?` rather than `decodeIfPresent` for the same reason again:
        // `decodeIfPresent` answers nil for a missing key but still *throws* on a
        // value of the wrong type, and a number where the name should be is
        // exactly the sort of thing hand-editing produces. This way missing,
        // null, and wrong-typed all arrive as nil and all mean uncoloured.
        self.color = SwatchColor(lenient: try? c.decode(String.self, forKey: .color))
    }
}

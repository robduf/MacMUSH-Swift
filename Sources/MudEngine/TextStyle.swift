// Style + colour model for MUD text. Deliberately free of AppKit so the engine
// stays portable and testable; the UI layer maps MudColor -> NSColor.

import Foundation

/// A colour as it appears in an ANSI stream.
public enum MudColor: Equatable, Sendable {
    /// The terminal's default foreground/background.
    case defaultColor
    /// A palette index, 0–255 (16 base colours, then the 6×6×6 cube, then greys).
    case indexed(Int)
    /// A 24-bit "true colour".
    case rgb(UInt8, UInt8, UInt8)
}

/// The set of SGR attributes that can apply to a run of text.
public struct TextStyle: Equatable, Sendable {
    public var fg: MudColor = .defaultColor
    public var bg: MudColor = .defaultColor
    public var bold = false
    public var italic = false
    public var underline = false
    public var inverse = false
    public var strikethrough = false

    public init() {}
}

/// A run of text sharing one style.
public struct StyledText: Equatable, Sendable {
    public let text: String
    public let style: TextStyle
    public init(text: String, style: TextStyle) {
        self.text = text
        self.style = style
    }
}

/// One unit of output produced by the ANSI parser.
public enum AnsiOp: Equatable, Sendable {
    case text(StyledText)
    case newline
    case bell
}

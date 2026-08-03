#if canImport(AppKit)
import AppKit

/// The handful of colours that make a world window look like one thing rather
/// than three.
///
/// These are fixed sRGB values rather than the semantic system colours, and
/// that's the point. A MUD's scrollback is a terminal: the ANSI palette it
/// renders was designed for a dark background, and a window that turned white
/// at sunrise because macOS switched to light mode would render half that
/// palette illegible. So world windows are pinned to the dark appearance — see
/// `WorldWindow.init` — which also means the semantic colours the tab bar and
/// status line *do* use (`labelColor`, `separatorColor`, `secondaryLabelColor`)
/// resolve against the same dark background these were chosen against, instead
/// of against a light window that isn't there.
///
/// The Worlds window is deliberately left following the system. It's an
/// ordinary Mac editor with text fields and checkboxes, not a terminal.
enum Theme {
    /// Behind the scrollback: near-black, with just enough blue in it that the
    /// darker ANSI blues don't disappear into it.
    static let scrollback = NSColor(srgbRed: 0.055, green: 0.055, blue: 0.080, alpha: 1)

    /// Behind the command box. A few percent up from the scrollback — enough to
    /// say "this part is yours to type in" without drawing a box around it, and
    /// not so much that it competes with the output above. It's the one region
    /// that has to stay findable while a wall of MUD text scrolls past.
    static let commandBackground = NSColor(srgbRed: 0.105, green: 0.105, blue: 0.140, alpha: 1)

    /// The tab strip along the top and the status line along the bottom: the
    /// window's chrome. Between the other two, so the scrollback still reads as
    /// the deepest thing on screen and the command box as the nearest.
    static let chrome = NSColor(srgbRed: 0.085, green: 0.085, blue: 0.110, alpha: 1)

    /// Text arriving with no ANSI colour of its own.
    static let foreground = NSColor(srgbRed: 0.84, green: 0.84, blue: 0.88, alpha: 1)

    /// The "›" in front of the command box, and the hint drawn behind it while
    /// the box is empty. Dim enough to read as furniture rather than as
    /// something the MUD said.
    static let promptIdle = NSColor(srgbRed: 0.45, green: 0.45, blue: 0.52, alpha: 1)
}
#endif

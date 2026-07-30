// ANSI / SGR escape-sequence parser. Converts a text stream (with embedded ESC
// sequences) into styled runs. Stateful across chunks: an escape sequence or the
// current style survives a chunk boundary.

import Foundation

public struct AnsiParser {
    private enum State { case text, esc, csi, osc, oscEsc }

    private var state: State = .text
    private var csiBuffer = ""
    private var style = TextStyle()

    public init() {}

    public mutating func resetStyle() {
        style = TextStyle()
    }

    /// Feed a chunk of text; returns the ops it produced. Style carries over.
    public mutating func feed(_ str: String) -> [AnsiOp] {
        var ops: [AnsiOp] = []
        var text = ""

        func flush() {
            if !text.isEmpty {
                ops.append(.text(StyledText(text: text, style: style)))
                text = ""
            }
        }

        // Iterate unicode scalars, NOT Characters: Swift treats "\r\n" as a
        // single grapheme-cluster Character, so a Character-based loop never
        // matches "\n" or "\r" on CRLF line endings and the lines run together.
        for scalar in str.unicodeScalars {
            let v = scalar.value
            switch state {
            case .text:
                if scalar == "\u{1B}" {            // ESC
                    flush()
                    state = .esc
                } else if scalar == "\n" {
                    flush()
                    ops.append(.newline)
                } else if scalar == "\r" {
                    // swallow; newlines are driven by \n
                } else if scalar == "\u{07}" {     // BEL
                    flush()
                    ops.append(.bell)
                } else if scalar == "\t" {
                    text += "        "             // simple 8-space tab
                } else if v < 0x20 {
                    // swallow other C0 control characters
                } else {
                    text.unicodeScalars.append(scalar)
                }

            case .esc:
                if scalar == "[" { csiBuffer = ""; state = .csi }
                else if scalar == "]" { state = .osc }
                else { state = .text }             // other escapes: ignore

            case .csi:
                // CSI parameter / intermediate bytes are 0x20–0x3F; the final
                // byte (0x40–0x7E) ends the sequence.
                if v >= 0x20 && v <= 0x3F {
                    csiBuffer.unicodeScalars.append(scalar)
                    if csiBuffer.utf8.count > 64 { state = .text } // runaway guard
                } else {
                    if scalar == "m" { applySGR(csiBuffer) }
                    // all other CSI finals (cursor moves, erase, …) are ignored
                    state = .text
                }

            case .osc:
                if scalar == "\u{07}" { state = .text }
                else if scalar == "\u{1B}" { state = .oscEsc }

            case .oscEsc:
                if scalar == "\\" { state = .text } else { state = .osc }
            }
        }

        flush()
        return ops
    }

    private mutating func applySGR(_ buffer: String) {
        let rawParts = buffer.isEmpty
            ? [""]
            : buffer.split(separator: ";", omittingEmptySubsequences: false).map(String.init)

        // Normalise ':' sub-separators (some servers use 38:5:n).
        var params: [String] = []
        for p in rawParts {
            if p.contains(":") {
                params.append(contentsOf: p.split(separator: ":", omittingEmptySubsequences: false).map(String.init))
            } else {
                params.append(p)
            }
        }

        var i = 0
        while i < params.count {
            let n = Int(params[i]) ?? 0
            switch n {
            case 0: style = TextStyle()
            case 1: style.bold = true
            case 2: break                    // faint: ignore
            case 3: style.italic = true
            case 4: style.underline = true
            case 5, 6: break                 // blink: ignore
            case 7: style.inverse = true
            case 9: style.strikethrough = true
            case 21, 22: style.bold = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 25: break
            case 27: style.inverse = false
            case 29: style.strikethrough = false
            case 30...37: style.fg = .indexed(n - 30)
            case 38, 48:
                let mode = (i + 1 < params.count) ? (Int(params[i + 1]) ?? -1) : -1
                if mode == 5 {
                    if i + 2 < params.count, let idx = Int(params[i + 2]) {
                        let c = MudColor.indexed(max(0, min(255, idx)))
                        if n == 38 { style.fg = c } else { style.bg = c }
                    }
                    i += 2
                } else if mode == 2 {
                    if i + 4 < params.count,
                       let r = Int(params[i + 2]), let g = Int(params[i + 3]), let b = Int(params[i + 4]) {
                        let c = MudColor.rgb(UInt8(clamping: r), UInt8(clamping: g), UInt8(clamping: b))
                        if n == 38 { style.fg = c } else { style.bg = c }
                    }
                    i += 4
                }
            case 39: style.fg = .defaultColor
            case 40...47: style.bg = .indexed(n - 40)
            case 49: style.bg = .defaultColor
            case 90...97: style.fg = .indexed(n - 90 + 8)
            case 100...107: style.bg = .indexed(n - 100 + 8)
            default: break
            }
            i += 1
        }
    }
}

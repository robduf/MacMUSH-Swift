#if canImport(AppKit)
import AppKit
import MudEngine

/// Turns MudEngine's styled ops into attributed text and appends them to an
/// NSTextView, mapping MudColor -> NSColor via the classic ANSI palette.
final class AnsiRenderer {
    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private let boldFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
    // Kept as properties rather than used from `Theme` directly at each call
    // site: `inverse` below has to swap a run's colours with whatever the
    // *scrollback* is showing, so the renderer genuinely needs to know its own
    // background, not just where to look one up.
    let defaultForeground = Theme.foreground
    let background = Theme.scrollback

    private let maxLength = 600_000
    private let trimTo = 500_000

    func append(_ ops: [AnsiOp], to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let result = NSMutableAttributedString()
        for op in ops {
            switch op {
            case .newline:
                result.append(NSAttributedString(string: "\n"))
            case .bell:
                NSSound.beep()
            case .text(let styled):
                result.append(attributed(styled))
            }
        }
        storage.append(result)

        if storage.length > maxLength {
            storage.deleteCharacters(in: NSRange(location: 0, length: storage.length - trimTo))
        }
    }

    /// Render a plain client message (notes, connection status) in one colour.
    func systemLine(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
        ])
    }

    private func attributed(_ styled: StyledText) -> NSAttributedString {
        let style = styled.style
        var attrs: [NSAttributedString.Key: Any] = [:]

        var fg = color(style.fg, isForeground: true, bold: style.bold) ?? defaultForeground
        var bg = color(style.bg, isForeground: false, bold: false)
        if style.inverse {
            let previousFg = fg
            fg = bg ?? background
            bg = previousFg
        }

        var chosen = style.bold ? boldFont : font
        if style.italic {
            chosen = NSFontManager.shared.convert(chosen, toHaveTrait: .italicFontMask)
        }
        attrs[.font] = chosen
        attrs[.foregroundColor] = fg
        if let bg = bg { attrs[.backgroundColor] = bg }
        if style.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }

        return NSAttributedString(string: styled.text, attributes: attrs)
    }

    private func color(_ c: MudColor, isForeground: Bool, bold: Bool) -> NSColor? {
        switch c {
        case .defaultColor:
            return nil
        case .rgb(let r, let g, let b):
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        case .indexed(let raw):
            var idx = raw
            if isForeground && bold && idx < 8 { idx += 8 }  // bold -> bright
            return AnsiRenderer.palette(idx)
        }
    }

    static func palette(_ idx: Int) -> NSColor {
        if idx < 16 {
            let base: [(CGFloat, CGFloat, CGFloat)] = [
                (0, 0, 0), (0.73, 0, 0), (0, 0.73, 0), (0.73, 0.73, 0),
                (0.27, 0.27, 0.80), (0.73, 0, 0.73), (0, 0.73, 0.73), (0.80, 0.80, 0.80),
                (0.33, 0.33, 0.33), (1, 0.33, 0.33), (0.33, 1, 0.33), (1, 1, 0.33),
                (0.47, 0.60, 1), (1, 0.33, 1), (0.33, 1, 1), (1, 1, 1),
            ]
            let c = base[max(0, min(15, idx))]
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        }
        if idx < 232 {
            let n = idx - 16
            let r = n / 36, g = (n % 36) / 6, b = n % 6
            func level(_ x: Int) -> CGFloat { x == 0 ? 0 : CGFloat(55 + x * 40) / 255 }
            return NSColor(srgbRed: level(r), green: level(g), blue: level(b), alpha: 1)
        }
        let gray = CGFloat(8 + (idx - 232) * 10) / 255
        return NSColor(srgbRed: gray, green: gray, blue: gray, alpha: 1)
    }
}
#endif

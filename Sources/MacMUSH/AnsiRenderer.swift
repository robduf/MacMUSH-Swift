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

    /// Whether URLs in text rendered from here on become clickable links.
    ///
    /// Per world for free: every `Session` builds its own renderer, so this is
    /// just that world's `linkifyURLs` copied across whenever its config is.
    ///
    /// Only affects text rendered *after* it changes — lines already in the
    /// scrollback keep the attributes they were built with. That's why
    /// `Session`'s click handler consults the setting too rather than trusting
    /// what's in the storage: turning links off should stop them opening now,
    /// not gradually as the old text scrolls away.
    var linksEnabled = true

    /// How much scrollback to keep, in characters, and how far back to cut when
    /// there's more than that.
    ///
    /// Roughly three thousand lines of an eighty-column world, which is a long
    /// evening's play. It used to be two and a half times this, and that turned
    /// out to be expensive in a way the raw character count hides: the text
    /// system keeps glyph positions and line-fragment rectangles for everything
    /// it has laid out, which is several times the size of the text itself, and
    /// every open tab pays it separately. Scroll back further than this and the
    /// session log is the place to look — that keeps everything.
    private let maxLength = 240_000
    private let trimTo = 200_000

    /// Built once and shared. `NSDataDetector` compiles a fair-sized rule set on
    /// creation and `append` runs on every line the world sends, so this is not
    /// a thing to make per call. Optional only because the initialiser is
    /// throwing; there is no input here for it to fail on.
    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Render ops into the scrollback.
    ///
    /// `highlight`, when given, repaints every character in this batch — the
    /// whole line, which is what a trigger colour is for. It goes on after the
    /// ANSI attributes rather than instead of them, so a highlighted line keeps
    /// its bold, italics and underlines and loses only its colours. That's the
    /// useful half of the trade: the world's emphasis survives, and the thing
    /// you asked to be able to spot at a glance is one flat colour.
    ///
    /// Backgrounds are cleared along with the foreground. A line that arrived
    /// with an inverse or coloured background would otherwise keep it, and the
    /// new foreground was chosen to be read against the scrollback's near-black
    /// — not against whatever the world happened to paint behind the text.
    func append(_ ops: [AnsiOp], to textView: NSTextView, highlight: NSColor? = nil) {
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
        if let highlight = highlight, result.length > 0 {
            let whole = NSRange(location: 0, length: result.length)
            result.addAttribute(.foregroundColor, value: highlight, range: whole)
            result.removeAttribute(.backgroundColor, range: whole)
        }
        // Before `storage.append`, because the detector should only ever see the
        // line that just arrived, never the whole scrollback. Order against the
        // highlight above doesn't matter — that touches only the two colour
        // attributes and this adds only `.link` and an underline.
        if linksEnabled { AnsiRenderer.linkify(result) }
        storage.append(result)

        if storage.length > maxLength {
            storage.deleteCharacters(in: NSRange(location: 0, length: storage.length - trimTo))
        }
    }

    /// Render a plain client message (notes, connection status) in one colour.
    func systemLine(_ text: String, color: NSColor) -> NSAttributedString {
        let line = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
        ])
        // Client messages carry URLs about as often as the world does — someone
        // pastes one into a channel and it comes back through the echo — and a
        // link that works in one half of the scrollback but not the other is
        // worse than no links at all.
        if linksEnabled { AnsiRenderer.linkify(line) }
        return line
    }

    /// Attach a URL to anything in `text` that looks like one, so the text view
    /// will open it on click.
    ///
    /// Called with a single line at a time, which is what makes this affordable:
    /// the detector never sees the whole scrollback, only the few dozen
    /// characters that just arrived.
    static func linkify(_ text: NSMutableAttributedString) {
        let string = text.string
        // Cheap gate first, because the overwhelming majority of MUD output
        // contains nothing resembling a URL and the detector is a regex engine
        // over a dozen-odd rules. "://" catches every scheme whatever its case,
        // and "www." is the one common form that leaves the scheme out.
        guard string.contains("://")
                || string.range(of: "www.", options: .caseInsensitive) != nil,
              let detector = linkDetector else { return }

        let whole = NSRange(location: 0, length: (string as NSString).length)
        detector.enumerateMatches(in: string, options: [], range: whole) { match, _, _ in
            guard let url = match?.url, let range = match?.range,
                  AnsiRenderer.isOpenable(url) else { return }
            // The underline is here in the storage, rather than left to the text
            // view's `linkTextAttributes`, so that text dragged or copied out of
            // the scrollback still arrives somewhere else looking like a link.
            text.addAttributes([.link: url,
                                .underlineStyle: NSUnderlineStyle.single.rawValue],
                               range: range)
        }
    }

    /// Whether MacMUSH will hand this URL to the system.
    ///
    /// The text these come out of is whatever a server chose to print, and
    /// `NSDataDetector` is happy to build a `file://` or `ftp://` URL out of it.
    /// Opening one of those on a stranger's say-so is how a hostile world gets
    /// to reach into this machine, so "a page on the web" is the whole of what's
    /// allowed and everything else is left inert.
    static func isOpenable(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https": return true
        default: return false
        }
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

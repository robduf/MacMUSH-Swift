// The actual shades behind `SwatchColor`.
//
// Here rather than in the engine, because these are AppKit colours and the
// engine has no AppKit — a world file carries the *name* of a colour and nothing
// else, which is also why a rename of these cases would be a file-format change
// and a re-tuning of the numbers below would not.
//
// Two tables, one set of names. `fillColor` paints a macro button, where the
// colour sits behind a label and competes with the window's own chrome;
// `textColor` paints a line in the scrollback, where the colour *is* the text
// and sits on near-black. The same numbers cannot do both jobs: a fill that
// reads as a solid green button is, as text, a dim smear that's harder to read
// than the plain foreground it replaced. So the fills stay as they were and the
// text shades are their own thing, tuned light enough to carry a whole line.

#if canImport(AppKit)
import AppKit
import MudEngine

extension SwatchColor {

    /// Button fills. Held as literal components rather than pulled back out of an
    /// `NSColor`: `redComponent` and its siblings trap on a colour that isn't in
    /// an RGB space, and there is no reason to go near that when the numbers are
    /// right here.
    private var components: (r: CGFloat, g: CGFloat, b: CGFloat)? {
        switch self {
        case .plain:  return nil
        case .red:    return (0.78, 0.25, 0.24)
        case .orange: return (0.85, 0.49, 0.15)
        case .yellow: return (0.92, 0.78, 0.20)
        case .green:  return (0.28, 0.60, 0.31)
        case .teal:   return (0.15, 0.58, 0.60)
        case .blue:   return (0.24, 0.46, 0.82)
        case .purple: return (0.50, 0.34, 0.74)
        case .pink:   return (0.84, 0.38, 0.58)
        }
    }

    /// Scrollback text. Every one of these clears a 4.5:1 contrast ratio against
    /// `Theme.scrollback`; three of the button fills — red, blue and purple — do
    /// not, and would be darker as text than the default foreground they'd be
    /// replacing. A "highlight" that makes a line harder to read is worse than no
    /// highlight, which is why this table exists rather than reusing the fills.
    ///
    /// They also stay far enough apart from each other to be told apart at a
    /// glance in a fast-moving window, which is the entire job: the eye has to
    /// sort two interleaved conversations without stopping to read either.
    private var textComponents: (r: CGFloat, g: CGFloat, b: CGFloat)? {
        switch self {
        case .plain:  return nil
        case .red:    return (0.96, 0.47, 0.44)
        case .orange: return (0.98, 0.66, 0.33)
        case .yellow: return (0.95, 0.86, 0.45)
        case .green:  return (0.52, 0.84, 0.53)
        case .teal:   return (0.38, 0.82, 0.82)
        case .blue:   return (0.51, 0.72, 0.99)
        case .purple: return (0.76, 0.62, 0.96)
        case .pink:   return (0.96, 0.62, 0.78)
        }
    }

    /// What the button is painted. `.plain` gets the standard control grey, which
    /// is a dynamic colour and so follows light and dark mode by itself.
    var fillColor: NSColor {
        guard let c = components else { return .controlColor }
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }

    /// What a highlighted line is painted, or nil for "don't repaint it".
    ///
    /// Optional rather than falling back to the default foreground, because the
    /// caller needs to tell the two apart: `.plain` has to leave the world's own
    /// ANSI colours standing, and painting every character the default grey would
    /// flatten a carefully coloured line into a beige one.
    var textColor: NSColor? {
        guard let c = textComponents else { return nil }
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }

    /// Black on the pale shades, white on the rest.
    ///
    /// The weights are the usual perceptual ones: green carries most of what the
    /// eye reads as brightness and blue almost none, which is why a saturated
    /// blue counts as dark here even though its numbers aren't small. On this set
    /// only yellow comes out light enough to want black on it.
    private var wantsDarkTitle: Bool {
        guard let c = components else { return false }
        return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b > 0.6
    }

    /// The macro's name.
    var titleColor: NSColor {
        guard components != nil else { return .labelColor }
        return wantsDarkTitle ? .black : .white
    }

    /// The key caption, a step quieter than the name. On a coloured button the
    /// standard tertiary grey all but vanishes, so it's the title colour faded
    /// instead — which keeps its contrast with the fill underneath.
    var keyColor: NSColor {
        guard components != nil else { return .tertiaryLabelColor }
        return titleColor.withAlphaComponent(0.7)
    }

    /// A small rounded chip for the Settings popups.
    ///
    /// Drawn from `fillColor` in both tables' popups, including the trigger one
    /// where the colour will actually arrive as text. A solid chip is what reads
    /// at 24×12 — a swatch drawn in the text shade would be a pale wash that's
    /// hard to tell from its neighbours at that size — and the popup's job is to
    /// say *which* colour, not to preview it.
    var swatchImage: NSImage {
        // The handler is kept and re-run each time the image is drawn, so the
        // dynamic colour behind `.plain` resolves against the appearance in force
        // then rather than the one that happened to be up when this was built.
        NSImage(size: NSSize(width: 24, height: 12), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                    xRadius: 3, yRadius: 3)
            self.fillColor.setFill()
            path.fill()
            path.lineWidth = 1
            NSColor.separatorColor.setStroke()
            path.stroke()
            return true
        }
    }
}
#endif

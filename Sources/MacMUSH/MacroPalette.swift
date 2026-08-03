#if canImport(AppKit)
import AppKit
import MudEngine

// MARK: - Swatches

/// The shades a macro can be painted, and the label colour that reads on top of
/// each one.
///
/// Here rather than in the engine, because these are AppKit colours and the
/// engine has no AppKit — it carries the *name* of the colour and nothing else.
///
/// Held as literal components rather than pulled back out of an `NSColor`:
/// `redComponent` and its siblings trap on a colour that isn't in an RGB space,
/// and there is no reason to go near that when the numbers are right here.
extension MacroColor {

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

    /// What the button is painted. `.plain` gets the standard control grey, which
    /// is a dynamic colour and so follows light and dark mode by itself.
    var fillColor: NSColor {
        guard let c = components else { return .controlColor }
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

    /// A small rounded chip for the Settings popup.
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

// MARK: - Buttons

/// A button that remembers which macro it stands for.
///
/// The alternative is `tag` holding an index into an array, which is fine right
/// up until the array is rebuilt between the click and the lookup and the button
/// fires somebody else's macro.
///
/// No initialisers of its own, deliberately. A subclass that adds only stored
/// properties *with defaults* inherits every one of its superclass's designated
/// initialisers; write one out and that inheritance stops, taking `init(coder:)`
/// with it and forcing a `required` stub that exists only to be a compile error
/// waiting to happen.
private final class MacroButton: NSButton {
    var macro: Macro?

    /// Set once, when the button is built, so the drawing has nothing to unwrap
    /// and no optional to have an opinion about.
    var fillColor: NSColor = .controlColor

    override func draw(_ dirtyRect: NSRect) {
        // Drawn here rather than set as a layer background. A layer colour is
        // resolved once, against whatever appearance was in force when it was
        // assigned, so the grey on a plain button would stay a dark-mode grey
        // after a switch to light. `draw` runs under the current appearance every
        // time it is called.
        let path = NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5)
        // The press state is *read* from the cell rather than tracked here. The
        // cell already follows the pointer for the whole gesture — press, drag
        // off to cancel, drag back to re-arm — and marks this view dirty each
        // time it flips, which is how every stock button repaints on a click.
        //
        // Tracking it by hand instead, around `mouseDown`, is the version that
        // looks right and isn't: `mouseDown` doesn't return until mouse-up, so
        // the fill would stay dark through a drag-off and disagree with the
        // title, which the cell dims correctly. And the action is sent from
        // inside that loop, where a rebuild of the palette can remove this very
        // button from its superview — leaving the two lines after `super` to
        // touch a view that has been let go of.
        //
        // `blended(withFraction:of:)` answers nil when two colours have no common
        // space to meet in, which a dynamic catalog colour can manage. Then the
        // press simply doesn't darken — a good deal better than not drawing.
        let fill = isHighlighted
            ? (fillColor.blended(withFraction: 0.22, of: .black) ?? fillColor)
            : fillColor
        fill.setFill()
        path.fill()

        // Then the cell, for the title. `isBordered` is off, so there is no bezel
        // to paint back over what was just filled.
        super.draw(dirtyRect)
    }
}

/// The palette's scrolling contents. Flipped so the first macro is at the top
/// and the list grows downwards, which is how a list is read.
private final class MacroListView: NSView {
    override var isFlipped: Bool { true }
}

/// The floating macro palette: one panel, showing whichever world is in front.
///
/// One panel rather than one per world. Two worlds' palettes on screen at once
/// would mean reading the title bar before every click to see which is which,
/// and a MUD client is a thing you use without looking. So the panel follows
/// you: switch tabs and it re-labels itself and swaps its buttons.
///
/// It never takes the caret away from the command box. That's `becomesKeyOnlyIfNeeded`
/// on a floating panel — a click on a control that doesn't need typing, which is
/// every control in here, leaves the key window alone. Without it, clicking a
/// macro would move focus to the palette and the next thing you typed would go
/// nowhere.
final class MacroPalette: NSObject {

    private static let autosaveName = "MacMUSH.macroPalette"

    private let panel: NSPanel
    private let scroll = NSScrollView()
    private let list = MacroListView()

    /// What's currently drawn. Compared against the world before rebuilding,
    /// because `worldStoreDidChange` arrives on every keystroke in a Settings
    /// text field and tearing down a stack of buttons for each one would be
    /// visible.
    private var shownWorldID: String?
    private var shownTitle = ""
    private var shownMacros: [Macro] = []

    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 230, height: 340),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        // Nothing above this line may read a property; see `WorldWindow.init`
        // for the two-phase initialisation rule this is following.
        super.init()

        panel.title = "Macros"
        panel.minSize = NSSize(width: 170, height: 140)
        // The app owns this panel for its whole life and shows it again on the
        // next ⌘K. Without this, closing it would free it out from under us.
        panel.isReleasedWhenClosed = false
        // Above the world windows, and — the part that matters — clicking a
        // button in here doesn't make it the key window.
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        // Standard palette manners: it goes away when you switch to another app
        // and comes back when you switch in. AppKit restores it itself.
        panel.hidesOnDeactivate = true
        // The Window menu lists the windows you can bring forward and work in.
        // A palette that follows the front window isn't one of those.
        panel.isExcludedFromWindowsMenu = true

        let container = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        panel.contentView = container

        scroll.frame = container.bounds
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        // The panel's own material shows through, so the list looks like part of
        // the window rather than a white box sitting inside it.
        scroll.drawsBackground = false
        container.addSubview(scroll)

        list.frame = NSRect(x: 0, y: 0, width: container.bounds.width, height: 0)
        // Springs and struts rather than constraints, deliberately: the width of
        // a scroll view's document view following its clip view is exactly what
        // this mask is for, and it needs no rebuild on resize.
        list.autoresizingMask = [.width]
        scroll.documentView = list

        // Restore first, name second — `setFrameAutosaveName` on its own doesn't
        // read the saved frame back.
        if !panel.setFrameUsingName(MacroPalette.autosaveName) {
            moveToDefaultCorner()
        }
        // The result says whether the name was already taken by another window.
        // It can't be — there is one palette — so it is thrown away deliberately
        // rather than left to look like an oversight.
        _ = panel.setFrameAutosaveName(MacroPalette.autosaveName)

        NotificationCenter.default.addObserver(
            self, selector: #selector(activeSessionChanged),
            name: .activeSessionDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(worldStoreChanged),
            name: .worldStoreDidChange, object: nil)

        rebuild()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Out of the way of the window you're playing in, and near the corner every
    /// other palette on the Mac starts in. Only used the first time; after that
    /// the autosaved frame wins.
    private func moveToDefaultCorner() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 20,
                                     y: visible.maxY - size.height - 20))
    }

    // MARK: Showing

    /// ⌘K.
    func toggle() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            show()
        }
    }

    func show() {
        // Rebuilt on the way up as well as on every change: the panel may have
        // been closed for an hour, and while it's off screen the notifications
        // still arrive but there is no reason to have acted on them.
        rebuild()
        // `orderFront`, not `makeKeyAndOrderFront`. The whole point of the
        // palette is that it appears without the command box losing the caret.
        panel.orderFront(nil)
    }

    // MARK: Staying current

    @objc private func activeSessionChanged() {
        rebuild()
    }

    @objc private func worldStoreChanged() {
        rebuild()
    }

    /// Redraw the buttons, if what they'd say has actually changed.
    private func rebuild() {
        let session = WindowManager.shared.activeSession
        let worldID = session?.worldID
        let title = session?.title ?? ""
        let macros = session?.macros ?? []

        guard worldID != shownWorldID || title != shownTitle || macros != shownMacros else {
            return
        }
        shownWorldID = worldID
        shownTitle = title
        shownMacros = macros

        panel.title = title.isEmpty ? "Macros" : "Macros — \(title)"

        for sub in list.subviews { sub.removeFromSuperview() }

        guard !macros.isEmpty else {
            layoutEmptyMessage(worldName: worldID == nil ? nil : title)
            return
        }
        layoutButtons(macros)
    }

    /// Explicit, rather than whatever `sizeToFit` says.
    ///
    /// A rounded push button reserves a few points above and below the artwork it
    /// actually draws, and `sizeToFit` reports the frame including that padding.
    /// Stack a few and the visible gap comes out half again the number the code
    /// asks for, with no sign in the code of where the rest came from. Drawing
    /// the bezel ourselves means the frame *is* the button, and the gap below is
    /// the gap you see.
    private static let buttonHeight: CGFloat = 22
    private static let buttonGap: CGFloat = 4
    private static let margin: CGFloat = 8

    private func layoutButtons(_ macros: [Macro]) {
        let margin = MacroPalette.margin
        let height = MacroPalette.buttonHeight
        let gap = MacroPalette.buttonGap
        let width = max(80, scroll.contentSize.width - margin * 2)
        var y = margin

        for macro in macros {
            let button = MacroButton(
                frame: NSRect(x: margin, y: y, width: width, height: height))
            button.macro = macro
            button.fillColor = macro.color.fillColor
            // No bezel: it would paint over the colour underneath it, and its
            // padding is what put the extra air between the buttons.
            button.isBordered = false
            button.setButtonType(.momentaryPushIn)
            button.focusRingType = .none
            button.attributedTitle = MacroPalette.buttonTitle(for: macro)
            button.toolTip = MacroPalette.tooltip(for: macro)
            button.target = self
            button.action = #selector(macroClicked(_:))
            button.autoresizingMask = [.width]
            list.addSubview(button)
            y += height + gap
        }

        // `y` is now one gap past the last button's bottom edge. That gap becomes
        // part of the bottom margin, so take it off and add the real one.
        list.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width,
                            height: y - gap + margin)
    }

    /// Two different nothings: no world open at all, and a world with no macros
    /// set up yet. The second one needs to say where to go and do something
    /// about it.
    private func layoutEmptyMessage(worldName: String?) {
        let text: String
        if let name = worldName, !name.isEmpty {
            text = "No macros for \(name) yet.\n\nSettings ▸ Macros — one row per button. "
                + "Give it a label, the command to send, and a key if you want one."
        } else if worldName != nil {
            text = "No macros for this world yet.\n\nAdd them in Settings ▸ Macros."
        } else {
            text = "No world is open."
        }

        let width = max(80, scroll.contentSize.width - 20)

        // Built as an attributed string rather than set with `font`/`textColor`
        // so the same object can be measured. `fittingSize` would answer for one
        // long line — it has no width to wrap at — and there is no AppKit
        // equivalent of UIKit's `sizeThatFits`, so the measuring is done here.
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ])

        // `wrappingLabelWithString:` for the wrapping behaviour, then the text
        // replaced: the attributed-string factory builds a label that doesn't
        // wrap, which is the opposite of what's wanted.
        let label = NSTextField(wrappingLabelWithString: "")
        label.attributedStringValue = attributed
        label.isSelectable = false

        // `.usesLineFragmentOrigin` is what makes this measure a wrapped
        // paragraph rather than a single line; `.usesFontLeading` matches how
        // the text system will actually space it. The result is fractional, so
        // round up — a rounded-down height clips the last line's descenders.
        let measured = attributed.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        label.frame = NSRect(x: 10, y: 10, width: width,
                             height: ceil(measured.height) + 4)
        label.autoresizingMask = [.width]
        list.addSubview(label)

        list.frame = NSRect(x: 0, y: 0,
                            width: scroll.contentSize.width,
                            height: label.frame.maxY + 10)
    }

    // MARK: Drawing a button

    /// The macro's name, an ellipsis if it waits for you rather than firing, and
    /// its key in a dimmer colour.
    ///
    /// All in one title, left-aligned, rather than the name on the left and the
    /// key hard against the right edge. Right-aligning it means a tab stop, and
    /// a tab stop means a position in points that would have to be recomputed
    /// every time the panel is resized — a lot of machinery for a caption.
    private static func buttonTitle(for macro: Macro) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        // A macro named after a long command has to lose its tail somewhere, and
        // the front of it is the part that identifies it.
        style.lineBreakMode = .byTruncatingTail
        // The cell hands the title the whole button to draw in, so the breathing
        // room has to come from the paragraph rather than from a smaller frame.
        // A negative tail indent is measured back from the trailing edge, which
        // is what keeps a truncated name from running into the right-hand side.
        style.firstLineHeadIndent = 8
        style.headIndent = 8
        style.tailIndent = -8

        // "…" is what it means everywhere else on the Mac: this doesn't act yet,
        // it asks you something first. Here the something is the rest of the
        // command, waiting in the command box.
        let name = macro.displayLabel + (macro.sendImmediately ? "" : "…")

        let title = NSMutableAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: macro.color.titleColor,
            .paragraphStyle: style,
        ])

        if let shortcut = macro.shortcut, !shortcut.label.isEmpty {
            title.append(NSAttributedString(string: "   " + shortcut.label, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: macro.color.keyColor,
                .paragraphStyle: style,
            ]))
        }
        return title
    }

    /// The whole command, which the button itself may have had to truncate, plus
    /// what clicking it will do.
    private static func tooltip(for macro: Macro) -> String {
        var lines = [macro.sendText]
        if !macro.sendImmediately {
            lines.append("")
            lines.append("Puts this in the command box for you to finish.")
        }
        if let shortcut = macro.shortcut, !shortcut.label.isEmpty {
            lines.append("")
            lines.append("Key: \(shortcut.label)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Clicking

    /// Takes `NSButton` and casts, rather than naming `MacroButton` in the
    /// signature: an `@objc` method's parameter types are part of what gets
    /// exposed to the runtime, and `MacroButton` is file-private. Every other
    /// action handler in this app takes a framework type for the same reason.
    @objc private func macroClicked(_ sender: NSButton) {
        guard let button = sender as? MacroButton, let macro = button.macro else { return }
        guard let session = WindowManager.shared.activeSession else { return }

        // The one thing that must never happen is world A's macro going to world
        // B. It shouldn't be reachable — every route that changes the frontmost
        // world posts `.activeSessionDidChange`, and this list is rebuilt from
        // that synchronously — but the cost of being sure is one string compare,
        // and the cost of being wrong is a password typed into a stranger's MUD.
        guard session.worldID == shownWorldID else {
            rebuild()
            NSSound.beep()
            return
        }

        // A macro that lands in the command line to be edited is useless if you
        // can't see the command line. The palette floats over everything and
        // keeps pointing at the world you were last in, so it is still clickable
        // while Settings is in front — and without this, the text would go into
        // a box hidden behind Settings, `focusInput` would fail quietly because
        // that window isn't key, and nothing at all would appear to happen.
        //
        // Only for this kind. A macro that sends outright has done its job
        // whether you're looking or not, and yanking a window forward
        // underneath you would be the rude answer to a click you meant as an
        // aside.
        if !macro.sendImmediately,
           let window = WindowManager.shared.activeWindow, !window.isKeyWindow {
            window.bringToFront()
        }
        session.runMacro(macro)
    }
}
#endif

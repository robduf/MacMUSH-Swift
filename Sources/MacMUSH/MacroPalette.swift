#if canImport(AppKit)
import AppKit
import MudEngine

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

    private func layoutButtons(_ macros: [Macro]) {
        let width = max(80, scroll.contentSize.width - 20)
        var y: CGFloat = 10

        for macro in macros {
            let button = MacroButton(frame: .zero)
            button.macro = macro
            button.bezelStyle = .rounded
            button.setButtonType(.momentaryPushIn)
            button.controlSize = .small
            button.attributedTitle = MacroPalette.buttonTitle(for: macro)
            button.toolTip = MacroPalette.tooltip(for: macro)
            button.target = self
            button.action = #selector(macroClicked(_:))
            // Height from the bezel rather than a number picked here: a rounded
            // push button has one it draws properly at, and forcing a different
            // one leaves the artwork floating in the middle of the frame.
            button.sizeToFit()
            let height = max(20, button.frame.height)

            button.frame = NSRect(x: 10, y: y, width: width, height: height)
            button.autoresizingMask = [.width]
            list.addSubview(button)
            y += height + 6
        }

        // The 6pt trailing the last button is the bottom margin; 4 more makes it
        // match the 10 at the top.
        list.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: y + 4)
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

        // "…" is what it means everywhere else on the Mac: this doesn't act yet,
        // it asks you something first. Here the something is the rest of the
        // command, waiting in the command box.
        let name = macro.displayLabel + (macro.sendImmediately ? "" : "…")

        let title = NSMutableAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ])

        if let shortcut = macro.shortcut, !shortcut.label.isEmpty {
            title.append(NSAttributedString(string: "   " + shortcut.label, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.tertiaryLabelColor,
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

#if canImport(AppKit)
import AppKit
import MudEngine

// MARK: - Modifier normalisation

extension NSEvent.ModifierFlags {
    /// The four modifiers a macro shortcut can be built from.
    ///
    /// Deliberately *not* `deviceIndependentFlagsMask`, which also carries caps
    /// lock, the numeric-keypad bit and the function bit. Those ride along on
    /// real key presses without anyone having chosen them, so matching on them
    /// would mean a shortcut recorded with caps lock up quietly stops firing the
    /// moment caps lock goes down.
    static let shortcutRelevant: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
}

extension NSEvent {
    /// This event's modifiers, reduced to the bits a shortcut is matched on.
    /// Both the recorder and the dispatcher go through here, which is what makes
    /// "what was recorded" and "what fires" the same question.
    var shortcutModifiers: UInt {
        modifierFlags.intersection(.shortcutRelevant).rawValue
    }
}

// MARK: - Drawing a key press

/// Turns a key press into the caption its shortcut is drawn with — "⇧⌘K", "F5",
/// "⌥Space".
///
/// Only ever used at the moment a shortcut is recorded. Afterwards the caption
/// is a stored string; see `KeyShortcut` for why it's kept rather than derived.
enum ShortcutFormat {

    /// Keys whose character is either invisible or a private-use codepoint that
    /// would draw as an empty box. Keyed by `NSEvent.SpecialKey.rawValue` rather
    /// than the values themselves, so this needs nothing of `SpecialKey` beyond
    /// its raw type.
    private static let specialNames: [Int: String] = {
        var names: [Int: String] = [
            NSEvent.SpecialKey.upArrow.rawValue: "↑",
            NSEvent.SpecialKey.downArrow.rawValue: "↓",
            NSEvent.SpecialKey.leftArrow.rawValue: "←",
            NSEvent.SpecialKey.rightArrow.rawValue: "→",
            NSEvent.SpecialKey.home.rawValue: "↖",
            NSEvent.SpecialKey.end.rawValue: "↘",
            NSEvent.SpecialKey.pageUp.rawValue: "⇞",
            NSEvent.SpecialKey.pageDown.rawValue: "⇟",
            NSEvent.SpecialKey.delete.rawValue: "⌫",
            NSEvent.SpecialKey.backspace.rawValue: "⌫",
            NSEvent.SpecialKey.deleteForward.rawValue: "⌦",
            NSEvent.SpecialKey.tab.rawValue: "⇥",
            NSEvent.SpecialKey.backTab.rawValue: "⇤",
            NSEvent.SpecialKey.carriageReturn.rawValue: "↩",
            NSEvent.SpecialKey.newline.rawValue: "↩",
            NSEvent.SpecialKey.enter.rawValue: "⌤",
            NSEvent.SpecialKey.insert.rawValue: "Ins",
            NSEvent.SpecialKey.help.rawValue: "Help",
        ]
        for (index, key) in functionKeys.enumerated() {
            names[key.rawValue] = "F\(index + 1)"
        }
        return names
    }()

    /// F1 through F20. Twenty rather than the full thirty-five AppKit knows
    /// about because no keyboard anyone is typing on has more, and the tail
    /// would only be reachable by a key remapper.
    private static let functionKeys: [NSEvent.SpecialKey] = [
        .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10,
        .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20,
    ]

    private static let functionKeyRawValues: Set<Int> = Set(functionKeys.map { $0.rawValue })

    /// Virtual key codes for the two keys that have an ordinary character but
    /// nothing worth drawing. These are the Carbon `kVK_` constants, which are
    /// fixed to physical positions and have not changed since the Apple
    /// Extended Keyboard.
    private static let escapeKeyCode: UInt16 = 53
    private static let spaceKeyCode: UInt16 = 49

    /// True for F1…F20, which are the only keys worth binding with no modifier
    /// at all. Everything else bare — a letter, an arrow, Return — is something
    /// the command box needs for itself.
    static func isFunctionKey(_ event: NSEvent) -> Bool {
        guard let raw = event.specialKey?.rawValue else { return false }
        return functionKeyRawValues.contains(raw)
    }

    /// The whole caption: modifier glyphs in the order macOS draws them, then
    /// the key.
    static func label(for event: NSEvent) -> String {
        modifierGlyphs(event.modifierFlags) + keyGlyph(event)
    }

    /// ⌃⌥⇧⌘ — always in that order, because that's the order every menu in the
    /// system draws them and a shortcut written any other way looks wrong even
    /// when it's right.
    private static func modifierGlyphs(_ flags: NSEvent.ModifierFlags) -> String {
        var glyphs = ""
        if flags.contains(.control) { glyphs += "⌃" }
        if flags.contains(.option) { glyphs += "⌥" }
        if flags.contains(.shift) { glyphs += "⇧" }
        if flags.contains(.command) { glyphs += "⌘" }
        return glyphs
    }

    private static func keyGlyph(_ event: NSEvent) -> String {
        if let raw = event.specialKey?.rawValue {
            // A function key AppKit knows and this table doesn't — F21 and up,
            // or something exotic. The number is at least identifiable, which a
            // private-use codepoint drawn as an empty box is not.
            return specialNames[raw] ?? "Key \(event.keyCode)"
        }
        switch event.keyCode {
        case escapeKeyCode: return "⎋"
        case spaceKeyCode: return "Space"
        default: break
        }
        // Ignoring modifiers so that ⌥K reads as "⌥K" rather than "⌥˚", and
        // uppercased so ⌘k and ⌘K draw the same way menus do.
        let characters = event.charactersIgnoringModifiers ?? ""
        let trimmed = characters.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Key \(event.keyCode)" : trimmed.uppercased()
    }
}

// MARK: - The control

/// A button that records the next key combination pressed after it's clicked.
///
/// The capture is done with a local event monitor rather than `keyDown`, because
/// a monitor is the only thing that sees a ⌘-combination before the main menu
/// claims it. Going through the responder chain would make every interesting
/// shortcut unrecordable: click here, press ⌘K, and the Macros menu item would
/// open the palette instead of the key landing in this field.
final class ShortcutRecorder: NSButton {

    /// The combination this field is showing.
    ///
    /// Setting it cancels any recording in progress — a table reuses these views
    /// between rows, and a recorder that kept listening after being handed a
    /// different macro would file the key press under the wrong one. Setting it
    /// does not fire the action; only the user recording a key does that.
    var shortcut: KeyShortcut? {
        get { recorded }
        set {
            cancelRecording()
            recorded = newValue
            updateTitle()
        }
    }

    /// Whichever recorder is listening for a key right now, if any.
    ///
    /// Only ever one: arming happens on a click, and any click cancels the one
    /// that was armed before. Weak, so a recorder that is thrown away while
    /// armed drops out of here on its own. Assigned only by the two methods
    /// below. Settings reads it to avoid rebuilding a table out from under a
    /// recording that is halfway through.
    static weak var armed: ShortcutRecorder?

    private var recorded: KeyShortcut?
    private var monitor: Any?
    private var isRecording: Bool { monitor != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        controlSize = .small
        setButtonType(.momentaryPushIn)
        font = NSFont.systemFont(ofSize: 11)
        alignment = .center
        toolTip = "Click, then press the keys you want.\n"
            + "Delete clears it. Escape leaves it alone."
        updateTitle()
    }

    required init?(coder: NSCoder) {
        fatalError("ShortcutRecorder is code-only; it is never unarchived from a nib.")
    }

    deinit {
        // Not `cancelRecording()`: that also touches `updateTitle`, and a view
        // being torn down has no business redrawing. The monitor is the only
        // thing here that outlives us if left behind.
        if let monitor = monitor { NSEvent.removeMonitor(monitor) }
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Interaction

    override func mouseDown(with event: NSEvent) {
        // No `super`: the inherited implementation runs a mouse-tracking loop
        // and sends the action on mouse-up, and the action here means "a key was
        // recorded", not "the button was clicked".
        if isRecording {
            cancelRecording()
        } else {
            beginRecording()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Scrolled out of the table, or the window went away mid-recording.
        if window == nil { cancelRecording() }
    }

    private func beginRecording() {
        guard monitor == nil else { return }

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowResignedKey),
            name: NSWindow.didResignKeyNotification, object: window)

        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self = self else { return event }
            return self.handle(event)
        }

        ShortcutRecorder.armed = self

        // After the monitor is in place, not before: the caption is driven by
        // `isRecording`, which *is* the monitor.
        updateTitle()
    }

    /// Stops listening. Safe to call when not recording.
    private func cancelRecording() {
        endMonitoring()
        updateTitle()
    }

    private func endMonitoring() {
        guard let monitor = monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        // Only if it is still us. Another recorder arming is one of the ways
        // this one stops, and by then `armed` names that other one.
        if ShortcutRecorder.armed === self { ShortcutRecorder.armed = nil }
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didResignKeyNotification, object: nil)
    }

    @objc private func windowResignedKey() {
        cancelRecording()
    }

    /// The monitor body. Returns the event to let it through, or nil to swallow
    /// it — swallowing only ever happens for the one key press being recorded.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.type == .keyDown else {
            // A click on this very control. Leave the recording alone and let it
            // through, because `mouseDown` is what toggles it: a monitor sees
            // the event *before* the view does, so cancelling here would turn
            // the click that was meant to stop recording into one that starts it
            // again, and the field would stick on "Press a key…" forever.
            // `if let` rather than comparing the two optionals directly: nil is
            // equal to nil, so a detached view would match a windowless event.
            if let own = window, event.window === own,
               bounds.contains(convert(event.locationInWindow, from: nil)) {
                return event
            }
            // A click anywhere else. Stop listening and let it land where it was
            // aimed; a click elsewhere is how you back out of this.
            cancelRecording()
            return event
        }

        // Someone else's window came forward while this was armed.
        guard window?.isKeyWindow == true else {
            cancelRecording()
            return event
        }

        // Escape backs out and leaves the existing binding alone. Delete clears
        // it. Neither is bindable itself, which is the price of using them for
        // this — and both are keys the command box wants anyway.
        if event.keyCode == 53 {                            // kVK_Escape
            cancelRecording()
            return nil
        }
        if event.specialKey?.rawValue == NSEvent.SpecialKey.delete.rawValue
            || event.specialKey?.rawValue == NSEvent.SpecialKey.backspace.rawValue {
            recorded = nil
            endMonitoring()
            updateTitle()
            sendAction(action, to: target)
            return nil
        }

        // A bare letter would fire the macro every time it was typed into the
        // command box, so a combination needs a modifier — unless it's a
        // function key, which is nobody's typing.
        //
        // Shift deliberately does not count on its own, even though it is a
        // modifier and `shortcutRelevant` includes it. Shift-2 is `@`, and `@`
        // is the most-typed character there is in MUSH soft-code; accepting it
        // here would bind a macro to it and then eat it every time you tried to
        // type one. Same for `"`, `*`, `&`, `:` and every capital letter. Shift
        // stays a qualifier — ⇧⌘K records, and stays distinct from ⌘K.
        let qualifying: NSEvent.ModifierFlags = [.control, .option, .command]
        guard !event.modifierFlags.intersection(qualifying).isEmpty
                || ShortcutFormat.isFunctionKey(event) else {
            NSSound.beep()
            return nil          // stay armed; they can try again or press Escape
        }

        recorded = KeyShortcut(keyCode: event.keyCode,
                               modifiers: event.shortcutModifiers,
                               label: ShortcutFormat.label(for: event))
        endMonitoring()
        updateTitle()
        sendAction(action, to: target)
        return nil
    }

    // MARK: Drawing

    private func updateTitle() {
        let text: String
        let color: NSColor

        if isRecording {
            text = "Press a key…"
            color = .secondaryLabelColor
        } else if let shortcut = recorded, !shortcut.label.isEmpty {
            text = shortcut.label
            color = .labelColor
        } else {
            text = "Set…"
            color = .tertiaryLabelColor
        }

        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: color,
            .paragraphStyle: ShortcutRecorder.centered,
        ])
    }

    private static let centered: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return style
    }()
}
#endif

#if canImport(AppKit)
import AppKit
import MudEngine

/// The command box. An `NSTextView` rather than an `NSTextField` so a long pose
/// wraps instead of scrolling off the end — which costs it the placeholder text
/// a text field gets for free, so it draws its own.
private final class CommandTextView: NSTextView {
    /// Drawn where the first character would go, whenever there is no first
    /// character. Deliberately not put *in* the storage: placeholder text that
    /// lives in the storage is placeholder text that eventually gets sent to the
    /// MUD, and it would land in the undo stack and the command history too.
    var placeholder: NSAttributedString? {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let placeholder = placeholder else { return }
        // `textContainerOrigin` is where the container starts inside the view;
        // the line fragment padding is the gap the text system leaves inside
        // *that* before the first glyph. Together they're exactly where the
        // caret is sitting, which is where the hint should start. The view is
        // flipped, so this point is the top-left of the string.
        var origin = textContainerOrigin
        origin.x += textContainer?.lineFragmentPadding ?? 0
        placeholder.draw(at: origin)
    }
}

/// The bottom half of the split view. Nothing but a background — but that
/// background is the whole point: it's a few percent lighter than the
/// scrollback, which is what separates "the world talking" from "you typing"
/// without drawing a box around either. See `Theme.commandBackground`.
private final class InputPaneView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.commandBackground.setFill()
        dirtyRect.fill()
    }
}

/// A clip view that refuses to scroll sideways.
///
/// Neither of this window's text views wraps at a width of its own choosing —
/// both are meant to wrap at exactly the width they're being shown at, so there
/// is never anything off to the right worth scrolling to. Any horizontal offset
/// is therefore a bug by definition, and this is where it gets caught, because
/// it's the one place *every* route to one has to pass through: a two-finger
/// swipe, a `scrollRectToVisible` for a glyph that a half-finished re-layout
/// still thinks is off-screen, or an autoresize that briefly leaves the document
/// wider than the space it's in.
///
/// Overriding this rather than snapping the offset back afterwards matters:
/// `constrainBoundsRect` runs *before* the scroll is committed, so the bad
/// offset is never drawn, not drawn and then corrected. Vertical scrolling —
/// including the elastic overscroll at the ends — is left entirely to `super`.
private final class VerticalOnlyClipView: NSClipView {
    /// Set the first time a sideways scroll actually has to be blocked, so the
    /// complaint below is printed once per view instead of once per frame.
    private var hasReportedSidewaysScroll = false

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)

        // Say something the one time this fires, because otherwise this class is
        // indistinguishable from a fix. `super` only hands back a nonzero x when
        // the document really is wider than the clip showing it — which, given
        // `syncWidth` is supposed to guarantee they're the same width, should
        // never happen. Neither scroll view has a horizontal scroller, so if it
        // *does* happen, the text off to the right is now unreachable rather
        // than merely awkward, and the symptom changes from "the left edge is
        // chopped" to "the right edge is missing" with nothing to show for it.
        // This line is that something.
        if abs(constrained.origin.x) > 0.5, !hasReportedSidewaysScroll {
            hasReportedSidewaysScroll = true
            let document = documentView?.frame.width ?? -1
            NSLog("""
                MacMUSH: blocked a sideways scroll to x=\(constrained.origin.x.rounded()). \
                The document is \(document.rounded())pt wide inside a \
                \(bounds.width.rounded())pt clip — those should match. \
                Text may be cut off at the right-hand edge; please report this.
                """)
        }

        constrained.origin.x = 0
        return constrained
    }
}

/// One of the small readouts at the right-hand end of the status line — "LOG",
/// the bell — which you can also click to change what it's reporting.
///
/// A button rather than a label, and always on screen rather than hidden when
/// off, because a status line that only shows you the things that happen to be
/// switched on can't tell you what's available to switch. Off is drawn in the
/// same muted grey for every toggle, so "dim" reads as "not doing anything"
/// wherever it appears; on is whatever colour suits the particular thing.
private final class StatusToggle: NSButton {
    /// What a toggle is up to, which is not always the two things you'd expect.
    enum Level {
        /// Off, and not asked for.
        case off
        /// Asked for, but not actually happening: logging ticked on while the
        /// world is disconnected, or a log whose folder couldn't be written to.
        /// Drawn in a faded version of the on colour — the distinction matters,
        /// because "I turned that on" and "that is running" being the same
        /// colour is exactly how a silently failed log goes unnoticed.
        case armed
        /// On and doing its job.
        case on
    }

    /// Shown when there's no symbol to draw, and used as the button's
    /// accessibility description when there is.
    private let label: String
    private let onColor: NSColor
    /// SF Symbol names for on and off, or nil to draw `label` as text.
    private let symbols: (on: String, off: String)?

    var level: Level = .off {
        // Only on a real change: `restyle` builds an image or an attributed
        // string, and the status line is refreshed far more often than these
        // actually flip.
        didSet { if level != oldValue { restyle() } }
    }

    init(label: String, onColor: NSColor, symbols: (on: String, off: String)? = nil) {
        self.label = label
        self.onColor = onColor
        self.symbols = symbols
        super.init(frame: .zero)
        isBordered = false
        // Not `.momentaryPushIn`, which draws a pressed-in bezel this has no
        // bezel to draw. Nothing visibly changes while the mouse is down; the
        // colour change on release is the feedback.
        setButtonType(.momentaryChange)
        focusRingType = .none
        // A status readout you can click is still a readout. It shouldn't be a
        // stop on the ⇥ tour of the window — especially not here, where ⇥ in the
        // command box is spoken for.
        refusesFirstResponder = true
        restyle()
    }

    required init?(coder: NSCoder) {
        fatalError("StatusToggle is code-only; it is never unarchived from a nib.")
    }

    /// The one thing that says "you can click me" before you've clicked it.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func restyle() {
        let color: NSColor
        switch level {
        case .off:   color = .tertiaryLabelColor
        case .armed: color = onColor.withAlphaComponent(0.45)
        case .on:    color = onColor
        }

        if let symbols = symbols {
            let name = level == .off ? symbols.off : symbols.on
            if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: label) {
                symbol.isTemplate = true
                let sizing = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                image = symbol.withSymbolConfiguration(sizing) ?? symbol
                imagePosition = .imageOnly
                contentTintColor = color
                return
            }
            // No such symbol in this macOS's catalogue — fall through and draw
            // the word instead. The toggle still works, it just reads differently.
        }
        imagePosition = .noImage
        attributedTitle = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: color,
        ])
    }
}

/// One world's live session: scrollback text view, command input, status line,
/// and the connection wiring. Code-only AppKit — no storyboards.
///
/// A session owns a view, not a window. `WorldWindow` hosts several of these
/// behind a tab bar and swaps `view` in and out as you click between them —
/// which is the whole reason this is separate from the window. Everything a
/// session needs to keep running while you're looking at a different tab (its
/// socket, its parser, its log, its timers, its scrollback) lives here, so a
/// background tab carries on exactly as if it were frontmost.
///
/// Output and input are the two halves of an `NSSplitView`, so the command box
/// can be dragged to whatever height suits the pose you're writing, and it word
/// wraps instead of scrolling sideways off the end of the world.
final class Session: NSObject, NSTextViewDelegate, NSSplitViewDelegate {
    /// The session's whole UI. Added to the window's container when this tab is
    /// frontmost, removed when it isn't — the session itself keeps running.
    let view = NSView()

    /// Fired whenever something the tab bar draws has changed: the world's name
    /// or its connected state. The window redraws its tabs in response.
    var onChange: (() -> Void)?

    private let splitView = NSSplitView()
    private let scrollView = NSScrollView()
    private let textView: NSTextView

    // Both `private` because their types are: a property can't be more visible
    // than the type it holds, and at file scope `private` means fileprivate.
    private let inputPane = InputPaneView()
    private let inputScroll = NSScrollView()
    private let inputView: CommandTextView
    private let promptLabel = NSTextField(labelWithString: "›")

    private let statusLabel = NSTextField(labelWithString: "Not connected")
    /// Both of these are on screen the whole time, dim when off. See
    /// `StatusToggle` for why that's better than hiding the one that's idle.
    private let logToggle = StatusToggle(label: "LOG", onColor: .systemGreen)
    private let chimeToggle = StatusToggle(label: "BELL", onColor: .systemYellow,
                                           symbols: (on: "bell.fill", off: "bell.slash"))
    /// Drawn as a word rather than a symbol. There is no glyph that says "your
    /// curly quotes are being straightened", and a wand or a broom would need a
    /// tooltip to mean anything — which is exactly what a status readout is
    /// supposed to save you.
    private let tidyToggle = StatusToggle(label: "TIDY", onColor: .systemTeal)
    private let elapsedLabel = NSTextField(labelWithString: "")

    private let renderer = AnsiRenderer()
    private var ansi = AnsiParser()
    private var connection: MudConnection?
    private let logger = SessionLogger()

    private var config: WorldConfig
    /// Read by the tab bar to draw the connected dot.
    private(set) var isConnected = false {
        didSet { if isConnected != oldValue { onChange?() } }
    }

    /// Lines the world has sent since you last looked at this tab. Drawn as the
    /// unread badge.
    private(set) var unread = 0 {
        didSet { if unread != oldValue { onChange?() } }
    }

    /// Set by the window when this session's tab becomes — or stops being — the
    /// frontmost one. Coming forward is what clears the unread count: you've now
    /// seen the traffic, and the scrollback is right there.
    var isFrontmost = false {
        didSet {
            guard isFrontmost != oldValue else { return }
            if isFrontmost { unread = 0 }
        }
    }
    private var currentHost = ""
    private var currentPort: UInt16 = 0
    private var connectedAt: Date?

    private var history: [String] = []
    private var historyIndex = -1
    private var draft = ""
    /// Whether the command box was empty last time anything changed in it — the
    /// one bit `textDidChange` needs to know when the placeholder has to appear
    /// or disappear.
    private var inputWasEmpty = true
    private var echoOn = true
    private var warnedNotConnected = false

    // Incoming lines are assembled here so triggers can match a whole line.
    private var pendingOps: [AnsiOp] = []
    private var pendingPlain = ""

    // Timer scheduling: next fire date per timer id.
    private var timerFireDates: [String: Date] = [:]
    private var tickTimer: Timer?

    /// One word this world has used, and how long ago — see `indexWords`.
    private struct SeenWord {
        /// Kept as the world spelled it, so completing "bob" offers "Bob".
        var spelling: String
        /// A counter, not a clock. All that's wanted is an ordering, and reading
        /// the time once per word of MUD output would be silly.
        var lastSeen: Int
    }
    /// Keyed by the lowercased word, so a name shouted in caps and the same name
    /// in a room description are one entry rather than two.
    private var wordsSeen: [String: SeenWord] = [:]
    private var wordClock = 0

    /// The ⇥ cycle in progress, if there is one. See `completeWord`.
    private var completion: Completion?
    /// Raised while `showCompletion` is writing into the command box, so that
    /// the `textDidChange` it causes doesn't read as you typing and cancel the
    /// very cycle it's part of.
    private var applyingCompletion = false

    /// The hint drawn in the empty command box. Same font as the text you type,
    /// so it sits on the same baseline and the first character you type lands
    /// exactly where the hint's first character was.
    private static func placeholder(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: Theme.promptIdle,
        ])
    }
    private static let commandHint = Session.placeholder("Type a command…    ⇧↩ for a new line")
    /// Swapped in when the MUD stops echoing, which it does exactly once: at the
    /// password prompt. Says what the client is doing about it, since the one
    /// thing you want to know while typing a password blind is whether it's
    /// going into the log.
    private static let passwordHint = Session.placeholder("Password — not echoed, not logged")

    init(world: WorldConfig) {
        config = world
        // `layout()` hands both text views their real geometry a few lines down.
        // These frames only have to be non-degenerate so the layout manager has
        // somewhere to put glyphs before the first pass — which is more than the
        // old code managed, since it sized the output view from the contentSize
        // of a scroll view that was still sitting at the origin with zero area.
        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 884, height: 452))
        inputView = CommandTextView(frame: NSRect(x: 0, y: 0, width: 860, height: 64))

        // Every stored property this class introduces now holds a value, so
        // control can pass up to NSObject.
        //
        // `renderer` is one of them, but it can't be configured from `world`
        // until after the call — see below.
        //
        // Nothing above this line may *read* a property. Swift's two-phase
        // initialisation lets a subclass assign to its own stored properties
        // before `super.init()` but not read them back, and `scrollView.foo = …`
        // is a read of `scrollView` followed by a write to the object it points
        // at — which is why every configuration statement lives below the call
        // rather than above it.
        super.init()

        applyWorldSettings()

        // --- output text view inside a scroll view ---
        // First, before anything else touches the scroll view. Two reasons, and
        // the second is the load-bearing one. `backgroundColor` and
        // `drawsBackground` are handed straight down to whichever clip view is
        // installed when they're set, so swapping the clip view afterwards would
        // put a fresh one in place still carrying its own default grey. And
        // `documentView` is installed *into* the clip view, so replacing the
        // clip view after assigning it would take the text view back out again.
        scrollView.contentView = VerticalOnlyClipView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        // The scroll view draws whatever the text view doesn't cover — the strip
        // under a short scrollback, and the elastic overscroll at the top of a
        // long one. Without this it uses `controlBackgroundColor`, which is a
        // light grey flashing into view every time you bounce the scroll.
        scrollView.backgroundColor = Theme.scrollback

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = renderer.background
        textView.textContainerInset = NSSize(width: 8, height: 6)
        // Only the height here is doing anything lasting: unbounded, so the text
        // keeps flowing instead of stopping at the bottom of the first screenful.
        // The width is a starting value that `widthTracksTextView` below
        // immediately takes ownership of and recomputes — don't try to keep it
        // accurate, and don't read it as the wrap width. The wrap width is the
        // text view's frame, which is what `syncWidth` exists to pin down.
        textView.textContainer?.size = NSSize(width: textView.frame.width,
                                              height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        // How a detected URL is drawn. Deliberately no `.foregroundColor`: these
        // are laid over whatever is in the storage, and the storage's colour is
        // the one the *world* chose — a link in the middle of a coloured line
        // should still be that line's colour, just underlined. The pointing hand
        // is what actually says "this one does something".
        textView.linkTextAttributes = [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        scrollView.documentView = textView
        // Lay out what's on screen instead of the whole document. The scrollback
        // runs to a couple of hundred thousand characters, TextKit otherwise
        // keeps glyph positions and line-fragment rectangles for every one of
        // them, and every open tab pays that separately — which is most of the
        // difference between this client's memory use and a modest one's. The
        // visible cost is that the scroller thumb estimates its size until
        // you've actually been somewhere, so it can resize slightly as you
        // scroll back. If scrolling ever feels wrong, this line is the first
        // thing to try taking out.
        textView.layoutManager?.allowsNonContiguousLayout = true

        // --- input: a real text view, so it wraps and can be resized ---
        // Clip view first, for the same two reasons as the scrollback above.
        inputScroll.contentView = VerticalOnlyClipView()
        inputScroll.hasVerticalScroller = true
        inputScroll.autohidesScrollers = true
        inputScroll.borderType = .noBorder
        inputScroll.drawsBackground = true
        inputScroll.backgroundColor = Theme.commandBackground

        inputView.minSize = NSSize(width: 0, height: 0)
        inputView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                   height: CGFloat.greatestFiniteMagnitude)
        inputView.isVerticallyResizable = true
        inputView.isHorizontallyResizable = false
        inputView.autoresizingMask = [.width]
        inputView.isRichText = false
        inputView.allowsUndo = true
        inputView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        inputView.drawsBackground = true
        inputView.backgroundColor = Theme.commandBackground
        inputView.textColor = renderer.defaultForeground
        inputView.insertionPointColor = renderer.defaultForeground
        inputView.textContainerInset = NSSize(width: 2, height: 4)
        inputView.textContainer?.size = NSSize(width: inputView.frame.width,
                                               height: CGFloat.greatestFiniteMagnitude)
        inputView.textContainer?.widthTracksTextView = true
        // macOS "helpfully" turns "don't" into "don’t" and -- into an em dash.
        // A MUSH takes those literally, so `page bob="don't"` would go out with
        // a curly quote the server has never heard of.
        inputView.isAutomaticQuoteSubstitutionEnabled = false
        inputView.isAutomaticDashSubstitutionEnabled = false
        inputView.isAutomaticTextReplacementEnabled = false
        inputView.isAutomaticSpellingCorrectionEnabled = false
        inputView.placeholder = Session.commandHint
        inputScroll.documentView = inputView

        promptLabel.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        promptLabel.textColor = Theme.promptIdle

        // --- status bar ---
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        logToggle.target = self
        logToggle.action = #selector(toggleLogging)
        chimeToggle.target = self
        chimeToggle.action = #selector(toggleChime)
        tidyToggle.target = self
        tidyToggle.action = #selector(toggleTidy)

        // Monospaced digits, or the timer jitters a pixel every second as the
        // glyph widths change under it.
        elapsedLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        elapsedLabel.textColor = .secondaryLabelColor

        // The scrollback has a delegate too now, for exactly one reason: to vet
        // a URL before the system is asked to open it. Every method on this
        // delegate that only applies to the command box already checks which
        // text view it was handed, so sharing one is safe.
        textView.delegate = self
        inputView.delegate = self
        splitView.delegate = self

        layout()

        // An NSTextView sizes itself to its text, so with a minimum height of
        // zero the blank space under a one-line command isn't part of the view
        // at all and clicking there does nothing. Keep the minimum matched to
        // whatever is visible, which changes every time the divider moves.
        inputScroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(inputClipResized(_:)),
            name: NSView.frameDidChangeNotification, object: inputScroll.contentView)

        // And the same for the scrollback, which needs it for a different
        // reason: not to stay clickable, but to stay the width of the window it
        // is being shown in. See `syncWidth`.
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(outputClipResized(_:)),
            name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        // Both of those name a particular clip view rather than listening to
        // every view in the app, so each is bound to whichever object is the
        // content view at this moment. That's the replacement installed at the
        // top of `init` and never swapped again — which is the reason the
        // replacing has to happen up there and not somewhere later on.
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // The run loop holds the ticker, not this object. Weak capture keeps it
        // from crashing, but without this it goes on waking once a second
        // forever after the window is gone.
        stopTicker()
    }

    private func layout() {
        buildInputPane()

        // NSSplitView positions its subviews itself, so those keep their
        // autoresizing masks — only the split view is constraint-driven. The
        // starting frames below decide the first-run proportions; after that,
        // `autosaveName` restores wherever the user left the divider.
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        scrollView.frame = NSRect(x: 0, y: 0, width: 884, height: 452)
        inputPane.frame = NSRect(x: 0, y: 0, width: 884, height: 76)
        // Setting that frame tiled the scroll view, so its clip view has a real
        // width for the first time — and a text view handed to a scroll view
        // that was still zero-sized is exactly the starting point `syncWidth`
        // exists to correct. Do it here, while there's a number to copy, rather
        // than in `init` where there wasn't one yet. If the split view has since
        // squashed the scroll view back to nothing this is a no-op and the
        // frame-change notification picks it up instead; no harm either way.
        syncWidth(of: textView, in: scrollView)
        splitView.addSubview(scrollView)
        splitView.addSubview(inputPane)
        // Set last: a saved divider position needs subviews to restore onto.
        splitView.autosaveName = "MacMUSH.outputInputSplit"

        // `sub`, not `view` — `view` is this session's root and shadowing it
        // here would quietly add every control to itself.
        for sub in [splitView, statusLabel, logToggle, chimeToggle,
                    tidyToggle, elapsedLabel] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(sub)
        }

        // A long host name shouldn't shove the timer off the right edge — let
        // the status text truncate and keep the readouts pinned.
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for readout in [logToggle, chimeToggle, tidyToggle, elapsedLabel] as [NSView] {
            readout.setContentCompressionResistancePriority(.required, for: .horizontal)
            readout.setContentHuggingPriority(.required, for: .horizontal)
        }
        // The clock is empty until you connect. Its width is reserved below so
        // the LOG badge doesn't slide sideways the moment it starts ticking —
        // which means hugging has to yield to that reservation rather than
        // fight it and log a broken-constraint warning.
        elapsedLabel.setContentHuggingPriority(NSLayoutConstraint.Priority(999), for: .horizontal)

        NSLayoutConstraint.activate([
            // Flush to the edges, not inset. The margins used to give the
            // terminal a frame; now the tab bar above and the status line below
            // do that, and a gutter of window background running down both sides
            // of the scrollback just makes the window look like three stacked
            // panels. The breathing room the text needs comes from
            // `textView.textContainerInset` instead, which keeps it *inside* the
            // dark area where it belongs.
            splitView.topAnchor.constraint(equalTo: view.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            statusLabel.topAnchor.constraint(equalTo: splitView.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            statusLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),

            logToggle.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            logToggle.leadingAnchor.constraint(greaterThanOrEqualTo: statusLabel.trailingAnchor, constant: 8),

            chimeToggle.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            chimeToggle.leadingAnchor.constraint(equalTo: logToggle.trailingAnchor, constant: 10),

            tidyToggle.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            tidyToggle.leadingAnchor.constraint(equalTo: chimeToggle.trailingAnchor, constant: 10),

            elapsedLabel.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            elapsedLabel.leadingAnchor.constraint(equalTo: tidyToggle.trailingAnchor, constant: 10),
            elapsedLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            elapsedLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 62),
        ])
    }

    /// The bottom half of the split: a "›" prompt beside the wrapping command
    /// box. The pane itself is frame-driven (the split view owns it); the two
    /// things inside it use constraints as usual.
    private func buildInputPane() {
        for sub in [promptLabel, inputScroll] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            inputPane.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            promptLabel.topAnchor.constraint(equalTo: inputPane.topAnchor, constant: 6),
            // 10, to line the "›" up with the status text below it — same
            // gutter down the left edge of the whole lower chrome.
            promptLabel.leadingAnchor.constraint(equalTo: inputPane.leadingAnchor, constant: 10),

            inputScroll.topAnchor.constraint(equalTo: inputPane.topAnchor, constant: 2),
            inputScroll.leadingAnchor.constraint(equalTo: promptLabel.trailingAnchor, constant: 4),
            inputScroll.trailingAnchor.constraint(equalTo: inputPane.trailingAnchor, constant: -2),
            inputScroll.bottomAnchor.constraint(equalTo: inputPane.bottomAnchor, constant: -2),
        ])
    }

    // MARK: Split view

    /// Window resizing grows and shrinks the scrollback; the command box keeps
    /// whatever height it was dragged to.
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        view === scrollView
    }

    func splitView(_ splitView: NSSplitView,
                   constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, 120)
    }

    func splitView(_ splitView: NSSplitView,
                   constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        // Always leave room for at least one line of input plus its insets,
        // otherwise the box can be collapsed to nothing and there's no obvious
        // way to get it back.
        let floor = splitView.bounds.height - splitView.dividerThickness - 34
        return min(proposedMaximumPosition, max(120, floor))
    }

    @objc private func inputClipResized(_ note: Notification) {
        // Width before height: `syncInputMinHeight` sizes the box to fit its
        // text, and how many lines that text takes depends on how wide it is.
        //
        // Both of these can re-enter: `inputScroll` autohides its scroller, so
        // changing the content height can add or remove a scroller, which
        // re-tiles, which lands back here. It terminates — a narrower box never
        // needs *fewer* lines, so the scroller can only appear, and only once —
        // but the inner pass can read a clip height mid-tile and set a minimum
        // that's a few points off for one frame. Harmless, and worth knowing
        // about before adding anything heavier to this method.
        syncWidth(of: inputView, in: inputScroll)
        syncInputMinHeight()
    }

    @objc private func outputClipResized(_ note: Notification) {
        syncWidth(of: textView, in: scrollView)
    }

    /// Keep a text view exactly as wide as the clip view showing it.
    ///
    /// Which is what the autoresizing mask is for, and mostly manages. Mostly:
    /// autoresizing works in *deltas*, so it only stays right if it started
    /// right, and neither of these views did. A text view here is handed to its
    /// scroll view while that scroll view is still zero-sized, so the first real
    /// resize adds the window's whole width as a delta on top of a frame that
    /// was already about that wide, and the view can come out close to twice the
    /// width it should be. Because the container tracks the view, that oversized
    /// frame *is* the width the text wraps at — hence long lines running off the
    /// right-hand edge instead of wrapping, and hence, once anything scrolls
    /// across to reach them, the first character or two chopped off the left.
    ///
    /// So state the width outright whenever the clip view changes size, instead
    /// of trusting that a chain of deltas still adds up. The autoresizing mask
    /// is deliberately left in place: it runs first and this runs second, so the
    /// absolute value wins either way, and if this notification ever stops
    /// arriving the result is a stale wrap width rather than a text view frozen
    /// at its initial size. The duplicated work costs almost nothing, because
    /// `NSLayoutManager` lays glyphs out lazily and two invalidations in a row
    /// are still only one re-wrap.
    ///
    /// This is half the fix. It does not explain the part where resizing a
    /// second time *corrects* the display, and the likeliest explanation for
    /// that half is a different one: re-wrapping is lazy, so between the
    /// container's width changing and the glyphs actually moving there's a
    /// window in which `scrollToEndOfDocument` — called on every single line
    /// arriving from the MUD — asks for a glyph the stale layout still thinks is
    /// off to the right, and gets scrolled there. Nothing re-constrains the clip
    /// afterwards, so the offset sticks until the next resize knocks it back.
    /// `VerticalOnlyClipView` is the other half, and covers that case whatever
    /// the width happens to be doing.
    ///
    /// One known rough edge: the height passed through here is the view's
    /// current one, which is stale for as long as the re-wrap is outstanding, so
    /// a resize while scrolled well back in the history can shift your position
    /// a little. It settles as soon as layout catches up.
    private func syncWidth(of text: NSTextView, in scroll: NSScrollView) {
        let width = scroll.contentView.bounds.width
        // `> 1` and not `> 0`: during teardown and before the first layout the
        // clip view measures zero, and snapping a text view to nothing there
        // would throw away the wrap it's about to be given properly.
        //
        // And a half-point of tolerance rather than `!=`, because these are
        // floating-point numbers arrived at by different routes — a backing-store
        // rounding of the same width shouldn't re-wrap the whole scrollback.
        guard width > 1, abs(text.frame.width - width) > 0.5 else { return }
        // Height unchanged: the layout manager owns it. Changing the width
        // re-wraps the text, and the view grows or shrinks to fit the result on
        // its own — `isVerticallyResizable` is what asks for that.
        text.setFrameSize(NSSize(width: width, height: text.frame.height))
    }

    /// Make the whole command box a click target rather than only the lines
    /// that happen to have text on them.
    private func syncInputMinHeight() {
        let visible = inputScroll.contentView.bounds.height
        guard visible > 1, inputView.minSize.height != visible else { return }
        inputView.minSize = NSSize(width: 0, height: visible)
        inputView.sizeToFit()
    }

    /// The world's display name — what the tab shows.
    var title: String { config.name }

    /// Run once, when the tab is created.
    func start() {
        updateStatus()
        showWelcome()
    }

    /// Put the caret back in the command box. The window calls this whenever
    /// this session's tab becomes the frontmost one.
    func focusInput() {
        syncInputMinHeight()
        _ = view.window?.makeFirstResponder(inputView)
    }

    private func showWelcome() {
        appendSystem("MacMUSH — a native Swift MUD client.")
        appendSystem("World: \(config.name)  —  ⌘R to connect (\(config.host) \(config.port)).")
        appendSystem("⌘T opens another world in a new tab, ⌘N in a new window. Every tab keeps its own connection.")
        appendSystem("Type /help for triggers, aliases and timers. They're saved per world, between sessions.")
        appendSystem("Test target:  node scripts/fake-mud.js  →  connect to 127.0.0.1 4000.\n")
    }

    // MARK: Connection

    func connect(host: String, port: UInt16) {
        disconnect()
        currentHost = host
        currentPort = port
        config.host = host
        config.port = port
        saveConfig()
        ansi.resetStyle()
        pendingOps = []
        pendingPlain = ""
        warnedNotConnected = false
        appendSystem("Connecting to \(host):\(port)…")

        let conn = MudConnection(host: host, port: port)
        conn.onText = { [weak self] text in self?.render(text) }
        conn.onPrompt = { [weak self] in self?.flushLine(isPrompt: true) }
        conn.onEcho = { [weak self] on in self?.setEcho(on) }
        conn.onNotice = { [weak self] message in self?.appendSystem(message) }
        conn.onStateChange = { [weak self] connected, message in
            guard let self = self else { return }
            self.isConnected = connected
            if connected {
                self.connectedAt = Date()
                // Open the log before the first line is printed, so "Connected."
                // and everything the MUD greets you with lands in the file.
                self.startLoggingIfEnabled()
                self.updateStatus()
                self.appendSystem("Connected.")
                self.sendConnectText()
                self.armTimers()
                self.startTicker()
            } else {
                if let message = message { self.appendSystem(message) }
                self.connectedAt = nil
                self.setEcho(true)
                self.stopTicker()
                self.stopLogging()
                self.updateStatus()
            }
        }
        conn.start()
        connection = conn
    }

    func disconnect() {
        // Whether there was anything to disconnect *from*, captured before the
        // teardown clears the flag. `MudConnection` used to announce its own
        // death, but its callbacks are cut below and the object is released
        // before the network stack reports back, so the notice never arrives.
        // Saying so here covers every route out — ⇧⌘D, /disconnect, closing a
        // tab — and says it exactly once.
        let wasLive = isConnected
        // Cut the callbacks before closing the socket, and before dropping our
        // reference to it. `disconnect()` is asynchronous underneath — the
        // network stack finishes cancelling on its own queue and reports back
        // afterwards — and the closures below hold the connection alive until
        // it does. On a ⌘R reconnect that report lands *after* the new session
        // is up, and the old socket's dying "Disconnected." then stops the new
        // one's timers, writes its log footer and closes its file. Nilling
        // these first means the corpse has nothing left to talk to.
        if let old = connection {
            old.onText = nil
            old.onPrompt = nil
            old.onEcho = nil
            old.onNotice = nil
            old.onStateChange = nil
            old.disconnect()
        }
        connection = nil
        isConnected = false
        connectedAt = nil
        // Dropping the connection deallocates the object whose callback would
        // otherwise have turned echo back on, so do it here. Otherwise a
        // disconnect during a password prompt leaves every line of the *next*
        // session missing from the scrollback and the log.
        setEcho(true)
        stopTicker()
        // Before `stopLogging()`, which writes the footer and closes the file:
        // the line that says why the log ends belongs inside it.
        if wasLive { appendSystem("Disconnected.") }
        stopLogging()
        // The next thing typed deserves its own "Not connected." — the warning
        // is once per batch, not once per lifetime of the window.
        warnedNotConnected = false
        updateStatus()
    }

    /// The world this session is currently bound to.
    var worldID: String { config.id }

    /// Push the settings that live somewhere other than `config` out to whoever
    /// holds them.
    ///
    /// A method rather than a line repeated at each of the three places `config`
    /// is assigned, because the fourth such place — added a year from now by
    /// someone who doesn't know this list exists — is exactly how a setting
    /// starts silently applying to some worlds and not others.
    private func applyWorldSettings() {
        renderer.linksEnabled = config.linkifyURLs
    }

    /// Switch this session to a different saved world. Drops any current
    /// connection; the new world connects on the next ⌘R / /connect.
    func activate(world: WorldConfig) {
        if isConnected || connection != nil {
            disconnect()
        }
        config = world
        applyWorldSettings()
        ansi.resetStyle()
        pendingOps = []
        pendingPlain = ""
        timerFireDates.removeAll()
        setEcho(true)
        onChange?()
        updateStatus()
        appendSystem("— Switched to \(world.name)  (\(world.host) \(world.port)).  ⌘R to connect. —")
    }

    /// Adopt edits to the world this window is already showing — a rename, or a
    /// change made in the Worlds window — without disturbing the connection or
    /// scrollback. New triggers and aliases take effect on the next line; timers
    /// are re-armed below.
    func syncActiveWorld(_ world: WorldConfig) {
        guard world.id == config.id else { return }
        let oldDirectory = config.logDirectory
        let wasEnabled = config.logEnabled
        config = world
        applyWorldSettings()
        onChange?()
        reconcileTimers()

        // Ticking the logging box takes effect on the session you're sitting in
        // rather than the next one. Keyed off the box *changing*, not off the
        // logger being inactive: this method also runs on every /alias, every
        // /timer and every one-shot timer expiry, so a retry-while-inactive
        // would re-attempt a failing folder — and print its error — over and
        // over for the rest of the evening. Untick and re-tick to retry.
        //
        // Changing the *folder* deliberately doesn't apply until you reconnect.
        // Honouring it live would roll the log file, and create a directory, for
        // every half-finished path on the way to the real one.
        if isConnected {
            if !config.logEnabled {
                stopLogging()
            } else if !wasEnabled {
                startLoggingIfEnabled()
            } else if oldDirectory != config.logDirectory {
                // Two different truths: if a log is running, the new folder is
                // simply queued for next time. If one *isn't* — the last start
                // failed — then saying "next time you connect" reads as though
                // something is being kept, when nothing is.
                appendSystem(logger.isActive
                    ? "Log folder changed — it takes effect next time you connect."
                    : "Log folder changed — untick and re-tick logging to start writing there now.")
            }
        }
        updateStatus()
    }

    /// Connect using the saved world's host/port.
    func connectDefault() {
        connect(host: config.host, port: config.port)
    }

    private func sendConnectText() {
        for line in config.connectText.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            send(line, echo: false)
        }
    }

    func promptConnect() {
        let alert = NSAlert()
        alert.messageText = "Connect to a MUD"
        alert.informativeText = "Enter a host and port (e.g. 127.0.0.1 4000)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = "\(config.host) \(config.port)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let parts = field.stringValue.split { $0 == " " || $0 == ":" }.map(String.init)
            if parts.count >= 2, let p = UInt16(parts[1]) {
                connect(host: parts[0], port: p)
            } else if parts.count == 1, !parts[0].isEmpty {
                connect(host: parts[0], port: 23)
            }
        }
    }

    // MARK: Incoming — line assembly + triggers

    private func render(_ text: String) {
        for op in ansi.feed(text) {
            switch op {
            case .text(let styled):
                pendingOps.append(op)
                pendingPlain += styled.text
            case .newline:
                flushLine(isPrompt: false)
            case .bell:
                NSSound.beep()
            }
        }
    }

    private func flushLine(isPrompt: Bool) {
        if pendingOps.isEmpty && pendingPlain.isEmpty && isPrompt { return }

        let plain = pendingPlain
        let lineOps = pendingOps
        pendingOps = []
        pendingPlain = ""

        var gagged = false
        // nil unless a trigger asked for a colour, which is the overwhelmingly
        // common case — and `append` skips the whole repaint when it's nil, so an
        // ordinary line costs nothing for this feature existing.
        var highlight: NSColor?
        if !isPrompt {
            let result = Matcher.evaluate(config.triggers, line: plain)
            gagged = result.gag
            highlight = result.highlight.textColor
            for match in result.matches where !match.sendText.isEmpty {
                send(match.sendText, echo: false)
            }
        }

        if !gagged {
            renderer.append(lineOps + [.newline], to: textView, highlight: highlight)
            textView.scrollToEndOfDocument(nil)
            // A gagged line stays out of the log too — if a trigger hid it from
            // you, writing it to disk anyway would be a nasty surprise.
            logLine(plain)
            // What's on screen is what ⇥ completes from, so this is fed from the
            // same branch that decides a line is on screen — a gagged line is
            // one you've asked not to see, and completing to a word out of it
            // would be the trigger leaking back.
            indexWords(in: plain)
            // Only real lines from the world count towards the badge. Prompts
            // are excluded, or a MUD that redraws its prompt after every line
            // would double every number; system notices and your own echoed
            // commands are excluded because you already know about those.
            if !isFrontmost && !isPrompt { unread += 1 }
            if !isPrompt { chimeIfWanted() }
        }
    }

    /// Ring once for traffic you aren't watching.
    ///
    /// "Aren't watching" is three conditions, because there are three separate
    /// ways for a line to land somewhere you can't see it: this might not be the
    /// frontmost tab in its window, that window might be buried behind another
    /// MacMUSH window or minimised into the Dock, or MacMUSH itself might be
    /// behind another application. Only the tab you are actually reading, in the
    /// window actually in front, stays quiet — otherwise a busy room turns the
    /// client into an alarm clock.
    private func chimeIfWanted() {
        guard config.chimeEnabled, !isBeingRead else { return }
        let now = Date()
        // A MUD sends a room description as a dozen lines in the same instant.
        // One sound for the burst: long enough to collapse a paragraph, short
        // enough that two pages a few seconds apart are still two chimes. The
        // gate is shared across worlds because the sound is — see `lastChimeAt`.
        if let last = Session.lastChimeAt, now.timeIntervalSince(last) < 2 { return }
        Session.lastChimeAt = now
        if let chime = Session.chimeSound {
            // One NSSound can't overlap itself. The throttle above is shared, so
            // by rights it has finished — but a chime cut short by a stop() it
            // didn't need is a worse noise than a rewind that costs nothing.
            if chime.isPlaying { _ = chime.stop() }
            _ = chime.play()
        } else {
            NSSound.beep()
        }
    }

    /// Whether this session's output is in front of a pair of eyes right now.
    ///
    /// `isFrontmost` alone isn't enough: it only says "the active tab of my own
    /// window", which is still true of a window sitting behind another one or
    /// shrunk into the Dock. Miniaturised is checked explicitly because a
    /// minimised window can still report itself visible.
    private var isBeingRead: Bool {
        guard isFrontmost, NSApplication.shared.isActive, let window = view.window
        else { return false }
        return window.isKeyWindow && window.isVisible && !window.isMiniaturized
    }

    /// When any world last chimed. Shared rather than per session, to match the
    /// sound it guards: with a throttle per session, two chatty worlds in the
    /// background each pass their own gate and the second one's `play()` cuts
    /// the first one's chime off mid-ring.
    private static var lastChimeAt: Date?

    /// The chime itself, loaded once and shared by every session. "Glass" is one
    /// of the sounds macOS ships in /System/Library/Sounds; if it has been
    /// removed, `chimeIfWanted` falls back to the ordinary alert beep.
    ///
    /// `NSSound.Name(_:)` spelled out rather than a bare literal: the name type
    /// has been both a string typealias and a struct across SDK versions, and
    /// this spelling compiles against either.
    private static let chimeSound = NSSound(named: NSSound.Name("Glass"))

    // MARK: Word completion

    /// Remember the words a line used, so ⇥ can complete from them later.
    ///
    /// This is the whole of the "context" MUSHClient completes against: not a
    /// dictionary, and not a list of commands, but the names of the people,
    /// rooms and things this particular world has been talking about. Which is
    /// exactly what's hard to type and easy to misspell.
    private func indexWords(in line: String) {
        for raw in line.components(separatedBy: Session.wordSeparators) {
            // Trim the two characters that only count as part of a word in the
            // middle of one: the apostrophe in "the guards'" isn't part of the
            // name, and neither is the dash in an em-dash-free "— Bob".
            let token = raw.trimmingCharacters(in: Session.wordEdges)
            // Under three characters completes to nothing you couldn't have
            // typed; over forty is a URL or a line of box-drawing, not a name.
            guard token.count >= 3, token.count <= 40 else { continue }
            // Numbers get in the way rather than help — "300" and "3000" are
            // never what you were reaching for.
            guard token.contains(where: { $0.isLetter }) else { continue }
            wordClock += 1
            wordsSeen[token.lowercased()] = SeenWord(spelling: token, lastSeen: wordClock)
        }

        // Forgetting in bulk rather than one word per new word: a dictionary of
        // this size is a few hundred kilobytes, and paying an O(n log n) sort
        // once every few thousand words is cheaper than keeping a sorted
        // structure honest on every line the world sends.
        guard wordsSeen.count > Session.wordsRemembered else { return }
        let keep = wordsSeen
            .sorted { $0.value.lastSeen > $1.value.lastSeen }
            .prefix(Session.wordsRemembered / 2)
        wordsSeen = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    /// Everything that isn't part of a word. Apostrophes, hyphens and
    /// underscores are on the word side of the line, because "Bob's",
    /// "half-elf" and "north_gate" are each one thing to a person.
    private static let wordSeparators = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "_-'"))
        .inverted
    /// The subset of those that can't start or end a word.
    private static let wordEdges = CharacterSet(charactersIn: "-'")
    /// How many distinct words to keep before dropping the oldest half.
    private static let wordsRemembered = 4000

    // MARK: Output helpers

    private func appendSystem(_ message: String) {
        let color = NSColor(srgbRed: 0.53, green: 0.53, blue: 0.80, alpha: 1)
        textView.textStorage?.append(renderer.systemLine(message + "\n", color: color))
        textView.scrollToEndOfDocument(nil)
        logLine(message)
    }

    /// Show a line you typed in the scrollback — if this world is set to.
    ///
    /// Turned off for worlds that echo your commands back at you themselves, or
    /// simply for anyone who would rather read the world's half of it. The guard
    /// is here rather than at the call sites because this is the one funnel
    /// every echoed line passes through, so there is nowhere to forget it.
    ///
    /// Nothing typed reaches the session log by either route. The log is the
    /// world's transcript; a server that echoes puts your commands in it in the
    /// world's own words, and one that doesn't was never going to.
    private func appendEcho(_ line: String) {
        guard config.echoInput else { return }
        // A MUSH login carries the password on the same line as the character
        // name, and most servers never negotiate telnet ECHO to hide it. Mask
        // it here, on the way to the only place it goes. What you typed is
        // still in the history buffer, so ↑ brings the real line back.
        let shown = "› " + SessionFormat.redactLogin(line)
        let color = NSColor(srgbRed: 0.91, green: 0.82, blue: 0.38, alpha: 1)
        textView.textStorage?.append(renderer.systemLine(shown + "\n", color: color))
        textView.scrollToEndOfDocument(nil)
    }

    // MARK: Status bar

    private func updateStatus() {
        statusLabel.stringValue = isConnected
            ? "\(config.name)  |  \(currentHost):\(currentPort)"
            : "Not connected"

        // Three states, not two, and the middle one is the point: full green
        // only while a file is genuinely open. Ticked-but-not-writing — the
        // world isn't connected yet, or the folder couldn't be written to —
        // gets the faded green instead, so a log that quietly failed to start
        // doesn't sit there looking exactly like one that's running.
        logToggle.level = logger.isActive ? .on : (config.logEnabled ? .armed : .off)
        // `isActive` as well as `fileURL`, because the logger deliberately keeps
        // the path after it stops so the window can say where the log went. Read
        // the URL alone and a stopped log still claims to be writing — and the
        // tooltip would offer to "stop" a thing that clicking would start.
        if logger.isActive, let url = logger.fileURL {
            logToggle.toolTip = "Logging \(config.name) to \(url.path)\nClick to stop."
        } else if config.logEnabled {
            logToggle.toolTip = isConnected
                ? "Logging is on, but no file is open — click twice to try again."
                : "Logging is on. It starts writing when you connect."
        } else {
            logToggle.toolTip = "Not logging \(config.name). Click to start."
        }

        chimeToggle.level = config.chimeEnabled ? .on : .off
        chimeToggle.toolTip = config.chimeEnabled
            ? "Chiming when \(config.name) talks and you're looking elsewhere.\nClick to silence."
            : "Silent. Click to chime when \(config.name) talks in the background."

        tidyToggle.level = config.tidyOutgoing ? .on : .off
        tidyToggle.toolTip = config.tidyOutgoing
            ? """
              Tidying what you send: line breaks become %r, tabs %t, and curly \
              quotes and dashes straighten out.
              Click for raw typing — needed to send several commands at once.
              """
            : """
              Raw: what you type goes out untouched, one command per line.
              Click to tidy it for the MUSH instead.
              """

        updateElapsed()
    }

    /// Start or stop logging this world, and remember which for next time.
    @objc private func toggleLogging() {
        config.logEnabled.toggle()

        // Open and close the file here rather than leaving it to
        // `syncActiveWorld`. That method spots a change by comparing the world
        // arriving from the store against the one this session is holding — and
        // this session is already holding the new value, being the thing that
        // changed it. Saving first and reacting to the notification second would
        // look like no change at all and quietly do nothing.
        if isConnected {
            if config.logEnabled { startLoggingIfEnabled() } else { stopLogging() }
        } else {
            // Nothing to open yet, and the badge can only go as far as its faded
            // "armed" state — so say what just happened, or the click reads as
            // one that didn't take.
            appendSystem(config.logEnabled
                ? "Logging is on for \(config.name) — it starts writing when you connect."
                : "Logging is off for \(config.name).")
        }

        saveConfig()
        updateStatus()
    }

    /// Turn the background chime on or off for this world. Remembered per world,
    /// so a busy channel you want to hear about and a quiet one you don't can
    /// each be set once and left alone.
    @objc private func toggleChime() {
        config.chimeEnabled.toggle()
        saveConfig()
        // The bell filling in or crossing out is the confirmation; no line goes
        // into the scrollback for this one. Ticking a preference isn't something
        // the world said, and it would be in the log forever.
        updateStatus()
    }

    /// Switch between tidied and raw typing, and remember which for this world.
    ///
    /// Per world rather than per app, like every other switch here: a MUSH wants
    /// `%r` and a Diku-style MUD would just be shown the two characters. Same
    /// silence as the chime — the word going dim is the confirmation, and a note
    /// in the scrollback would end up in the log.
    @objc private func toggleTidy() {
        config.tidyOutgoing.toggle()
        saveConfig()
        updateStatus()
    }

    private func updateElapsed() {
        guard let start = connectedAt else {
            if !elapsedLabel.stringValue.isEmpty { elapsedLabel.stringValue = "" }
            return
        }
        let text = SessionFormat.elapsed(Date().timeIntervalSince(start))
        // Only touch the label when the second actually rolls over; assigning
        // stringValue redraws, and this runs every tick forever.
        if elapsedLabel.stringValue != text { elapsedLabel.stringValue = text }
    }

    // MARK: Logging

    private func startLoggingIfEnabled() {
        guard config.logEnabled else { return }
        if let problem = logger.start(worldName: config.name,
                                      host: currentHost,
                                      port: currentPort,
                                      directory: config.logDirectory) {
            appendSystem(problem)
            return
        }
        if let url = logger.fileURL { appendSystem("Logging to \(url.path)") }
    }

    private func stopLogging() {
        guard logger.isActive else { return }
        let url = logger.fileURL
        logger.stop()
        if let url = url { appendSystem("Log saved: \(url.path)") }
    }

    /// Mirror one displayed line into the session log. Safe to call from the
    /// append helpers: a failed write closes the logger *before* returning the
    /// warning, so the `appendSystem` below can't recurse back in here.
    private func logLine(_ text: String) {
        guard logger.isActive else { return }
        guard let problem = logger.write(text) else { return }
        appendSystem(problem)
        updateStatus()
    }

    // MARK: Sending

    /// Send one or more lines to the MUD (multi-line text is split on "\n").
    private func send(_ text: String, echo: Bool) {
        // `isConnected` as well as the object: when the *server* closes the
        // link, `connection` stays non-nil — only `disconnect()` clears it — so
        // checking the object alone would swallow the line and still echo it to
        // the screen as though it had gone out.
        guard isConnected, connection != nil else {
            // Paste twenty lines while disconnected and you want to be told
            // once, not twenty times.
            if !warnedNotConnected {
                warnedNotConnected = true
                appendSystem("Not connected.")
            }
            return
        }
        for line in text.components(separatedBy: "\n") {
            connection?.send(line)
            if echo && echoOn { appendEcho(line) }
        }
    }

    // MARK: Input

    @objc private func sendFromInput() {
        let raw = inputView.string
        setInputText("")

        // The whole block goes into history as one entry, so ↑ brings back the
        // pose you just sent rather than only its last line.
        if !raw.isEmpty && history.last != raw {
            history.append(raw)
            if history.count > 200 { history.removeFirst() }
        }
        historyIndex = -1
        draft = ""

        // Tidied here and nowhere else. This is the one path carrying text a
        // *person* typed or pasted; triggers, aliases, timers, macros and the
        // connect script all reach `send` by other routes, and every one of them
        // is a list of commands where a line break means "next command" and has
        // to keep meaning that.
        //
        // Note what it does to the loop at the bottom: tidying leaves no
        // newlines, so the block arrives as a single `submit`. That is the whole
        // point — `page Caitlin=` then covers the entire pose rather than its
        // first line, with lines two and three landing on the game as bare
        // commands. Tidying off, and the loop behaves exactly as it always did.
        //
        // `history` above keeps `raw`: ↑ should bring back what you wrote, in
        // the shape you wrote it, not a line full of %r.
        let sensitive = mustNotRewrite(raw)
        let prepared = (config.tidyOutgoing && !sensitive) ? OutgoingText.tidy(raw) : raw

        // A misfire must not be silent. TIDY stays lit through this, so with no
        // word here it looks exactly like the bug tidying was built to fix: a
        // pose arriving in three pieces with its quotes still curly, and nothing
        // saying why. Only worth saying when tidying would have changed
        // something — an ordinary `connect Rob hunter2` already *is* the one
        // clean line it would have produced.
        if config.tidyOutgoing && sensitive && OutgoingText.tidy(raw) != raw {
            appendSystem("Sent as typed — that looked like it might carry a password.")
        }

        // Slash commands still work while disconnected, so the block can't be
        // rejected up front — `send` warns once for the whole batch instead.
        warnedNotConnected = false
        for line in prepared.components(separatedBy: "\n") { submit(line) }
    }

    /// Whether this text has to reach the world exactly as typed, tidying or no.
    ///
    /// Both cases are credentials, and both are ways for a rewrite to do real
    /// damage rather than cosmetic damage.
    ///
    /// `echoOn` is false exactly while the server has negotiated telnet ECHO off
    /// to collect a password. Fold an accented character out of one of those, or
    /// drop one the fold has no answer for, and the login fails — with nothing
    /// echoed anywhere that could show you why, because suppressing the echo is
    /// the entire point of the mode.
    ///
    /// `containsLogin` catches the commoner shape, where the password rides
    /// inline on `connect Rob hunter2`. Tidying turns a tab-separated paste of
    /// that into `connect%tRob%thunter2` — one token as far as `redactLogin` is
    /// concerned, so the mask never lands and `appendEcho` paints the password
    /// across the scrollback. The line then fails to log in, so it gets retried,
    /// and painted again.
    ///
    /// Deliberately broad, and it does misfire: any line whose first word is
    /// `connect`, `create`, `password` or a sibling makes the whole block
    /// sensitive, which a pose opening "Create a character sheet first." manages
    /// by accident. That costs you a tidy. The alternative is guessing which
    /// `connect` is prose, and the price of guessing wrong is a leaked password.
    private func mustNotRewrite(_ text: String) -> Bool {
        !echoOn || SessionFormat.containsLogin(text)
    }

    /// Replace everything in the command box without corrupting undo.
    ///
    /// Assigning `inputView.string` goes behind the text system's back: the
    /// undo manager keeps the ranges it recorded while you were typing, and
    /// replaying one of those against the now-empty storage raises
    /// NSRangeException — ⌘Z twice after sending a line would kill the app.
    /// Bracketing the edit the documented way re-points undo at what's there.
    private func setInputText(_ text: String) {
        let all = NSRange(location: 0, length: (inputView.string as NSString).length)
        guard inputView.shouldChangeText(in: all, replacementString: text) else { return }
        inputView.textStorage?.replaceCharacters(in: all, with: text)
        // A storage-level replace doesn't pick up typing attributes, so a
        // recalled line would otherwise come back in the system font.
        if !text.isEmpty {
            inputView.textStorage?.setAttributes(
                inputView.typingAttributes,
                range: NSRange(location: 0, length: (text as NSString).length))
        }
        inputView.didChangeText()
    }

    // MARK: Macros

    /// This world's quick-reference macros — what the palette draws, and what
    /// the key dispatcher searches.
    var macros: [Macro] { config.macros }

    /// Run a macro: fire it, or load it into the command box ready to edit.
    ///
    /// Which of the two is the macro's own setting rather than a global one,
    /// because both kinds are useful and a client that picks for you gets it
    /// wrong half the time. `+who` wants to go the instant you click it;
    /// `+who/find F H any/R29` has a bit in the middle you change every time.
    ///
    /// The firing path goes through `submit`, the same one Return in the command
    /// box uses. That's deliberate: a macro can then use an alias or a slash
    /// command exactly as you could by hand, and echoing is decided in one place
    /// for both rather than in two places that drift apart.
    /// Returns whether it did anything. The key dispatcher needs to know: a
    /// macro with a key but no text yet must not swallow that key, or binding
    /// ⌘V to a row you meant to fill in later silently kills Paste.
    @discardableResult
    func runMacro(_ macro: Macro) -> Bool {
        guard !macro.sendText.isEmpty else { return false }

        guard macro.sendImmediately else {
            // Whatever was half-typed in the box is replaced. `setInputText`
            // goes through the text system properly, so ⌘Z brings it back —
            // which is the difference between a slip and a loss.
            setInputText(macro.sendText)
            focusInput()
            // Caret at the end, not a selection of the whole thing: the next
            // thing typed should extend the command, not wipe it.
            //
            // Property, not `setSelectedRange(_:)` — that pair imports into
            // Swift as a settable property, the same way `recallHistory` and
            // the completion code below set it.
            inputView.selectedRange =
                NSRange(location: (macro.sendText as NSString).length, length: 0)
            return true
        }

        // One "Not connected." for a multi-line macro rather than one per line,
        // the same reason `sendFromInput` clears this before its own loop.
        warnedNotConnected = false
        // Not added to history. History is for recalling what you typed, and a
        // macro is already a click and a keystroke away — putting it in ↑ as
        // well would push the things that *are* hard to retype further back.
        for line in macro.sendText.components(separatedBy: "\n") { submit(line) }
        return true
    }

    /// One line of what the user typed: a slash command, an alias, or plain text
    /// straight to the MUD.
    private func submit(_ line: String) {
        if line.hasPrefix("/") {
            handleCommand(line)
            return
        }

        let result = Matcher.evaluate(config.aliases, line: line)
        if result.matches.isEmpty {
            send(line, echo: true)
        } else {
            if echoOn { appendEcho(line) }
            for match in result.matches where !match.sendText.isEmpty {
                send(match.sendText, echo: false)
            }
        }
    }

    /// The MUD asked us to stop echoing — it's collecting a password. The typed
    /// text isn't masked (you still need to see your own typos), but nothing is
    /// echoed to the scrollback, which also keeps it out of the session log.
    private func setEcho(_ on: Bool) {
        echoOn = on
        promptLabel.stringValue = on ? "›" : "•"
        promptLabel.textColor = on ? Theme.promptIdle : .systemOrange
        promptLabel.toolTip = on ? nil : "Password mode — this line won't be echoed or logged."
        inputView.placeholder = on ? Session.commandHint : Session.passwordHint
    }

    // MARK: Key handling in the command box

    /// Only here to keep the placeholder honest. The text view repaints the run
    /// of text that changed, which is not the same shape as the hint that has to
    /// appear or disappear behind it — so on the two edits that matter, the
    /// first character typed and the last one deleted, ask for the whole box.
    ///
    /// This covers history recall and sending a line as well as typing:
    /// `setInputText` ends in `didChangeText()`, which is what posts this.
    @objc func textDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextView) === inputView else { return }

        // Any edit that isn't the completion machinery writing its own result
        // ends the ⇥ cycle. ⇥⇥⇥ walks the candidates; typing a character in the
        // middle of that means you've settled on one and moved on.
        if !applyingCompletion { completion = nil }

        let empty = inputView.string.isEmpty
        guard empty != inputWasEmpty else { return }
        inputWasEmpty = empty
        inputView.needsDisplay = true
    }

    /// Open a link clicked in the scrollback — if it's the kind of link a world
    /// has any business sending. See `AnsiRenderer.isOpenable`.
    ///
    /// Returning true either way is deliberate: it stops AppKit falling back to
    /// its own behaviour, which is to hand whatever it's got to the system.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        // AppKit hands over whatever was in the `.link` attribute. Ours are
        // always URLs, but the attribute is documented as taking a string too.
        let clicked: URL?
        switch link {
        case let value as URL:    clicked = value
        case let value as String: clicked = URL(string: value)
        default:                  clicked = nil
        }
        guard let url = clicked else { return true }
        // Links turned off after this line was rendered. The `.link` attribute
        // is still sitting in the storage — repainting the whole scrollback to
        // strip it would be a lot of work to achieve what one comparison does —
        // so the setting is enforced here instead, at the only moment it
        // matters.
        guard renderer.linksEnabled else {
            appendSystem("Links are off for this world. Turn them back on in Settings ▸ Connection.")
            return true
        }
        guard AnsiRenderer.isOpenable(url) else {
            appendSystem("Not opening \(url.absoluteString) — MacMUSH only follows http and https links.")
            return true
        }
        if !NSWorkspace.shared.open(url) {
            appendSystem("Couldn't open \(url.absoluteString).")
        }
        return true
    }

    /// Put a line break in the command box.
    ///
    /// `insertText` rather than AppKit's own `insertLineBreak(_:)`, which inserts
    /// U+2028 LINE SEPARATOR. That looks like a newline on screen and is not one:
    /// `components(separatedBy: "\n")` in `sendFromInput` doesn't split on it, so
    /// the whole pose would go out as one line with a stray character sitting in
    /// the middle of it — and `OutgoingText.tidy` would then drop that character,
    /// silently welding two lines together.
    private func insertRealNewline(into textView: NSTextView) {
        textView.insertText("\n", replacementRange: textView.selectedRange)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === inputView else { return false }

        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            // Shift-Return has to be told apart from Return *here*, by looking at
            // the event, because AppKit will not do it for us. Shift is not in
            // the standard key-binding table at all for Return: it is part of how
            // a character is produced, not a command modifier, so ⇧↩ arrives as
            // plain `insertNewline:` — indistinguishable from ↩ unless you ask
            // what was actually held down. The cases below cover ⌃↩ and ⌥↩, which
            // *are* in the table, and covering Shift by adding it to that list is
            // the mistake this replaces: the selector never arrives, so the
            // placeholder advertised a key that sent your half-written pose.
            //
            // `NSApp.currentEvent` is the key event: `doCommandBy` runs
            // synchronously inside `interpretKeyEvents`, still within `keyDown`.
            let modifiers = NSApp.currentEvent?.modifierFlags
                .intersection(.deviceIndependentFlagsMask) ?? []
            if modifiers.contains(.shift) {
                insertRealNewline(into: textView)
                return true
            }
            sendFromInput()
            return true

        case #selector(NSResponder.insertLineBreak(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            // ⌃↩ and ⌥↩ respectively — both kept, because both are muscle memory
            // for somebody and neither costs anything.
            insertRealNewline(into: textView)
            return true

        case #selector(NSResponder.moveUp(_:)):
            // Only walk history from the top line, so the arrows still move the
            // caret normally inside a multi-line pose.
            guard caretOnFirstLine else { return false }
            recallHistory(delta: -1)
            return true

        case #selector(NSResponder.moveDown(_:)):
            // Nothing below the line you're still writing, so hand ↓ back to
            // AppKit rather than swallowing it — the caret should still move to
            // the end of the text the way it does in every other text view.
            guard caretOnLastLine, historyIndex != -1 else { return false }
            recallHistory(delta: 1)
            return true

        case #selector(NSResponder.insertTab(_:)):
            return completeWord(reverse: false)

        case #selector(NSResponder.insertBacktab(_:)):
            return completeWord(reverse: true)

        default:
            return false
        }
    }

    // MARK: ⇥ completion

    /// A ⇥ cycle in progress.
    ///
    /// Offsets are UTF-16, because that's what `NSTextView` deals in for
    /// selections and it's the only unit the two sides can agree on without
    /// converting back and forth on every keystroke.
    private struct Completion {
        /// Where the word being completed starts.
        let start: Int
        /// What you actually typed, which is one of the stops on the cycle —
        /// pressing ⇥ past the last candidate brings it back rather than
        /// stranding you on a word you didn't choose.
        let typed: String
        /// Candidates, best (most recently said) first. Never contains `typed`.
        let options: [String]
        /// -1 means `typed` is showing; otherwise an index into `options`.
        var index: Int
        /// What's in the box for this word right now, so the next ⇥ can tell
        /// whether the cycle is still standing or the text moved underneath it.
        var shown: String
    }

    /// Complete the partial word in front of the caret from the words this world
    /// has used, most recently said first. ⇥ again steps to the next candidate,
    /// ⇧⇥ steps back, and going past either end returns what you typed.
    ///
    /// Always returns true, even with nothing to complete. The alternative is
    /// handing ⇥ back to AppKit, which for a text view means putting a literal
    /// tab character in the command box — which is never what was wanted here,
    /// and would go down the socket looking like whitespace the MUD has to
    /// guess about.
    private func completeWord(reverse: Bool) -> Bool {
        let text = inputView.string as NSString
        let caret = inputView.selectedRange
        // With a selection there's no single partial word to work from, and
        // replacing the selection would be a surprising thing for ⇥ to do.
        guard caret.length == 0 else { return true }

        if var cycle = completion, standing(cycle, in: text, caret: caret.location) {
            // Wrapping through -1 is what puts `typed` back at the end of the
            // ring, in both directions.
            var next = cycle.index + (reverse ? -1 : 1)
            if next >= cycle.options.count { next = -1 }
            if next < -1 { next = cycle.options.count - 1 }
            cycle.index = next
            showCompletion(cycle)
            return true
        }

        // Fresh start: the word being typed runs from just after the last
        // separator before the caret, up to the caret itself.
        let before = NSRange(location: 0, length: caret.location)
        let lastBreak = text.rangeOfCharacter(from: Session.wordSeparators,
                                              options: .backwards, range: before)
        let start = lastBreak.location == NSNotFound ? 0 : lastBreak.location + lastBreak.length
        guard start < caret.location else { return true }
        let typed = text.substring(with: NSRange(location: start, length: caret.location - start))

        let lowered = typed.lowercased()
        let options = wordsSeen.values
            // `!= typed` rather than a case-insensitive comparison: if you typed
            // "bob" and the world says "Bob", offering the world's spelling is
            // the most useful thing ⇥ can do.
            .filter { $0.spelling != typed && $0.spelling.lowercased().hasPrefix(lowered) }
            .sorted { $0.lastSeen > $1.lastSeen }
            // Nobody cycles past a couple of dozen. The cap keeps a two-letter
            // prefix in a chatty world from building a thousand-entry ring.
            .prefix(40)
            .map { $0.spelling }
        guard !options.isEmpty else { return true }

        showCompletion(Completion(start: start,
                                  typed: typed,
                                  options: options,
                                  index: reverse ? options.count - 1 : 0,
                                  shown: typed))
        return true
    }

    /// Whether a cycle still describes what's in the command box.
    ///
    /// The caret can move without anything changing — arrow keys and clicks post
    /// no `textDidChange` — so the cycle can't rely on being told when it stops
    /// applying. It checks instead.
    private func standing(_ cycle: Completion, in text: NSString, caret: Int) -> Bool {
        let length = (cycle.shown as NSString).length
        guard cycle.start >= 0,
              cycle.start + length <= text.length,
              cycle.start + length == caret else { return false }
        return text.substring(with: NSRange(location: cycle.start, length: length)) == cycle.shown
    }

    /// Put a cycle's current candidate in the box and leave the caret after it.
    private func showCompletion(_ cycle: Completion) {
        let replacement = cycle.index < 0 ? cycle.typed : cycle.options[cycle.index]
        let range = NSRange(location: cycle.start, length: (cycle.shown as NSString).length)
        // The same dance as `setInputText`, and for the same reason: going
        // straight at the storage without bracketing leaves the undo manager
        // holding ranges that no longer exist.
        guard inputView.shouldChangeText(in: range, replacementString: replacement) else { return }

        applyingCompletion = true
        inputView.textStorage?.replaceCharacters(in: range, with: replacement)
        let placed = NSRange(location: cycle.start, length: (replacement as NSString).length)
        // A storage-level replace doesn't pick up typing attributes, so without
        // this the completed word comes back in the system font.
        inputView.textStorage?.setAttributes(inputView.typingAttributes, range: placed)
        inputView.didChangeText()
        applyingCompletion = false

        // Property, not `setSelectedRange(_:)` — that pair imports into Swift as
        // a settable property, the same way `recallHistory` sets it.
        let caret = NSRange(location: placed.upperBound, length: 0)
        inputView.selectedRange = caret
        // A long pose can have pushed the word being completed off the top of
        // the command box.
        inputView.scrollRangeToVisible(caret)

        var updated = cycle
        updated.shown = replacement
        completion = updated
    }

    // MARK: Timers

    private func armTimers() {
        let now = Date()
        timerFireDates.removeAll()
        for timer in config.timers where timer.enabled {
            timerFireDates[timer.id] = now.addingTimeInterval(timer.seconds)
        }
    }

    /// Keep the fire-date table in step with the current timer list after an
    /// edit: newly enabled timers start counting now, removed or disabled ones
    /// are forgotten, and timers already counting down keep their place.
    private func reconcileTimers() {
        guard isConnected else {
            timerFireDates.removeAll()
            return
        }
        let now = Date()
        var live: [String: Date] = [:]
        for timer in config.timers where timer.enabled {
            live[timer.id] = timerFireDates[timer.id] ?? now.addingTimeInterval(timer.seconds)
        }
        timerFireDates = live
    }

    private func startTicker() {
        tickTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // .common, not the default mode: otherwise the connected-time clock
        // freezes — and every world timer stops firing — for as long as a menu
        // is held open, a panel is up, or the window is being live-resized.
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTicker() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func tick() {
        guard isConnected else { return }
        updateElapsed()
        let now = Date()
        var changed = false
        for timer in config.timers where timer.enabled {
            guard let fire = timerFireDates[timer.id], fire <= now else { continue }
            if !timer.sendText.isEmpty { send(timer.sendText, echo: false) }
            if timer.oneShot {
                if let idx = config.timers.firstIndex(where: { $0.id == timer.id }) {
                    config.timers[idx].enabled = false
                }
                timerFireDates[timer.id] = nil
                changed = true
            } else {
                timerFireDates[timer.id] = now.addingTimeInterval(timer.seconds)
            }
        }
        if changed { saveConfig() }
    }

    // MARK: Persistence

    /// Save by id rather than "whichever world is selected": the Worlds window
    /// can move the selection around while this window stays on its own world,
    /// and a slash command here must never land in someone else's config.
    private func saveConfig() {
        WorldStore.shared.update(config)
    }

    // MARK: Slash commands

    private enum RuleKind { case trigger, alias }

    private func handleCommand(_ raw: String) {
        let body = String(raw.dropFirst())
        let spaceIdx = body.firstIndex(of: " ")
        let cmd = (spaceIdx.map { String(body[..<$0]) } ?? body).lowercased()
        let rest = spaceIdx.map { String(body[body.index(after: $0)...]) } ?? ""

        switch cmd {
        case "help", "?":
            showHelp()
        case "connect":
            let parts = rest.split { $0 == " " || $0 == ":" }.map(String.init)
            if parts.count >= 2, let p = UInt16(parts[1]) { connect(host: parts[0], port: p) }
            else { connectDefault() }
        case "disconnect":
            // `disconnect()` announces itself now, but only when there was a
            // live connection to drop — so typing /disconnect at a dead session
            // would otherwise print nothing at all, which reads like the client
            // didn't recognise the command. A connection object with the flag
            // still down means a dial in progress, and cancelling that is a
            // different event from hanging up on a MUD.
            if !isConnected {
                appendSystem(connection == nil
                    ? "Not connected."
                    : "Connection attempt cancelled.")
            }
            disconnect()
        case "alias":
            addRule(rest, kind: .alias)
        case "trigger":
            addRule(rest, kind: .trigger)
        case "timer":
            addTimer(rest)
        case "aliases":
            listRules(config.aliases, label: "Aliases")
        case "triggers":
            listRules(config.triggers, label: "Triggers")
        case "timers":
            listTimers()
        case "rmalias":
            removeRule(rest, kind: .alias)
        case "rmtrigger":
            removeRule(rest, kind: .trigger)
        case "rmtimer":
            removeTimer(rest)
        default:
            appendSystem("Unknown command: /\(cmd). Type /help.")
        }
    }

    private func addRule(_ spec: String, kind: RuleKind) {
        guard let eq = spec.firstIndex(of: "=") else {
            appendSystem("Usage: /\(kind == .alias ? "alias" : "trigger") <pattern>=<send>")
            return
        }
        let pattern = String(spec[..<eq]).trimmingCharacters(in: .whitespaces)
        let sendText = String(spec[spec.index(after: eq)...])
        guard !pattern.isEmpty else { appendSystem("Pattern can't be empty."); return }
        let rule = MatchRule(pattern: pattern, sendText: sendText)
        if kind == .alias { config.aliases.append(rule) } else { config.triggers.append(rule) }
        saveConfig()
        // Redacted for the same reason a typed login is: `/alias in=connect Rob
        // hunter2` is a perfectly ordinary thing to set up, and echoing it back
        // verbatim would write the password straight into the session log.
        appendSystem("Added \(kind == .alias ? "alias" : "trigger"): \(pattern)  →  \(SessionFormat.redactBlock(sendText))")
    }

    private func addTimer(_ spec: String) {
        guard let eq = spec.firstIndex(of: "=") else {
            appendSystem("Usage: /timer <seconds>=<send>")
            return
        }
        let secStr = String(spec[..<eq]).trimmingCharacters(in: .whitespaces)
        let sendText = String(spec[spec.index(after: eq)...])
        // isFinite matters: Double("inf") parses, and JSONEncoder refuses to
        // encode a non-finite Double. One `/timer inf=look` would make every
        // future save in the app fail silently, forever.
        guard let seconds = Double(secStr), seconds.isFinite, seconds > 0, seconds <= 31_536_000 else {
            appendSystem("Seconds must be a positive number (up to 31536000).")
            return
        }
        let timer = MudTimer(seconds: seconds, sendText: sendText)
        config.timers.append(timer)
        if isConnected { timerFireDates[timer.id] = Date().addingTimeInterval(seconds) }
        saveConfig()
        appendSystem("Added timer: every \(secStr)s  →  \(SessionFormat.redactBlock(sendText))")
    }

    private func listRules(_ rules: [MatchRule], label: String) {
        guard !rules.isEmpty else { appendSystem("\(label): (none)"); return }
        appendSystem("\(label):")
        for (i, r) in rules.enumerated() {
            let flags = (r.enabled ? "" : " [off]") + (r.gag ? " [gag]" : "") + (r.isRegex ? " [regex]" : "")
            appendSystem("  \(i + 1). \(r.pattern)  →  \(SessionFormat.redactBlock(r.sendText))\(flags)")
        }
    }

    private func listTimers() {
        guard !config.timers.isEmpty else { appendSystem("Timers: (none)"); return }
        appendSystem("Timers:")
        for (i, t) in config.timers.enumerated() {
            let flags = (t.enabled ? "" : " [off]") + (t.oneShot ? " [once]" : "")
            appendSystem("  \(i + 1). every \(t.seconds)s  →  \(SessionFormat.redactBlock(t.sendText))\(flags)")
        }
    }

    private func removeRule(_ arg: String, kind: RuleKind) {
        guard let n = Int(arg.trimmingCharacters(in: .whitespaces)), n >= 1 else {
            appendSystem("Usage: /rm\(kind == .alias ? "alias" : "trigger") <number>")
            return
        }
        if kind == .alias {
            guard n <= config.aliases.count else { appendSystem("No alias #\(n)."); return }
            appendSystem("Removed alias: \(config.aliases.remove(at: n - 1).pattern)")
        } else {
            guard n <= config.triggers.count else { appendSystem("No trigger #\(n)."); return }
            appendSystem("Removed trigger: \(config.triggers.remove(at: n - 1).pattern)")
        }
        saveConfig()
    }

    private func removeTimer(_ arg: String) {
        guard let n = Int(arg.trimmingCharacters(in: .whitespaces)), n >= 1, n <= config.timers.count else {
            appendSystem("Usage: /rmtimer <number>")
            return
        }
        let removed = config.timers.remove(at: n - 1)
        timerFireDates[removed.id] = nil
        saveConfig()
        appendSystem("Removed timer: every \(removed.seconds)s")
    }

    private func showHelp() {
        let lines = [
            "Commands (rules are saved between sessions):",
            "  /connect [host port]        connect (defaults to saved world)",
            "  /disconnect",
            "  /alias <pattern>=<send>     e.g.  /alias gt * *=give %2 to %1",
            "  /trigger <pattern>=<send>   e.g.  /trigger * tells you *=wave",
            "  /timer <seconds>=<send>     e.g.  /timer 60=look",
            "  /aliases  /triggers  /timers    list them",
            "  /rmalias N  /rmtrigger N  /rmtimer N    remove by number",
            "  Use * as a wildcard; %1..%9 insert wildcards into the send text.",
        ]
        for line in lines { appendSystem(line) }
    }

    // MARK: History (arrow keys)

    /// True when there is no newline anywhere before the caret — i.e. pressing ↑
    /// would leave the box entirely. Only then does ↑ mean "previous command";
    /// inside a multi-line pose it has to keep meaning "up one line".
    private var caretOnFirstLine: Bool {
        let text = inputView.string as NSString
        let caret = inputView.selectedRange.location
        guard caret != NSNotFound, caret <= text.length else { return true }
        return text.range(of: "\n", options: .backwards,
                          range: NSRange(location: 0, length: caret)).location == NSNotFound
    }

    private var caretOnLastLine: Bool {
        let text = inputView.string as NSString
        let end = NSMaxRange(inputView.selectedRange)
        guard end <= text.length else { return true }
        return text.range(of: "\n", range: NSRange(location: end,
                                                   length: text.length - end)).location == NSNotFound
    }

    private func recallHistory(delta: Int) {
        guard !history.isEmpty else { return }
        // ↓ from a line you're still writing has nowhere further down to go.
        // Without this it would stash the draft, come straight back to it, and
        // yank the caret to the end of what you were in the middle of typing.
        guard delta < 0 || historyIndex != -1 else { return }

        if historyIndex == -1 {
            // Stash whatever was half-typed so walking back down returns it.
            draft = inputView.string
            historyIndex = history.count
        }
        historyIndex = max(0, min(history.count, historyIndex + delta))

        let text: String
        if historyIndex >= history.count {
            historyIndex = -1
            text = draft
        } else {
            text = history[historyIndex]
        }
        setInputText(text)
        // Caret to the very end: for a multi-line entry that also means the next
        // ↑ walks up through the recalled text before reaching further back.
        let end = NSRange(location: (text as NSString).length, length: 0)
        inputView.selectedRange = end
        inputView.scrollRangeToVisible(end)
    }
}
#endif

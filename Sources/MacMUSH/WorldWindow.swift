#if canImport(AppKit)
import AppKit
import MudEngine

/// One MUD window: scrollback text view, command input, status line, and the
/// connection wiring. Code-only AppKit — no storyboards.
///
/// Output and input are the two halves of an `NSSplitView`, so the command box
/// can be dragged to whatever height suits the pose you're writing, and it word
/// wraps instead of scrolling sideways off the end of the world.
final class WorldWindow: NSObject, NSTextViewDelegate, NSSplitViewDelegate {
    private let window: NSWindow
    private let splitView = NSSplitView()
    private let scrollView = NSScrollView()
    private let textView: NSTextView

    private let inputPane = NSView()
    private let inputScroll = NSScrollView()
    private let inputView: NSTextView
    private let promptLabel = NSTextField(labelWithString: "›")

    private let statusLabel = NSTextField(labelWithString: "Not connected")
    private let logBadge = NSTextField(labelWithString: "LOG")
    private let elapsedLabel = NSTextField(labelWithString: "")

    private let renderer = AnsiRenderer()
    private var ansi = AnsiParser()
    private var connection: MudConnection?
    private let logger = SessionLogger()

    private var config = WorldStore.shared.selectedWorld
    private var isConnected = false
    private var currentHost = ""
    private var currentPort: UInt16 = 0
    private var connectedAt: Date?

    private var history: [String] = []
    private var historyIndex = -1
    private var draft = ""
    private var echoOn = true
    private var warnedNotConnected = false

    // Incoming lines are assembled here so triggers can match a whole line.
    private var pendingOps: [AnsiOp] = []
    private var pendingPlain = ""

    // Timer scheduling: next fire date per timer id.
    private var timerFireDates: [String: Date] = [:]
    private var tickTimer: Timer?

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // `layout()` hands both text views their real geometry a few lines down.
        // These frames only have to be non-degenerate so the layout manager has
        // somewhere to put glyphs before the first pass — which is more than the
        // old code managed, since it sized the output view from the contentSize
        // of a scroll view that was still sitting at the origin with zero area.
        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 884, height: 452))
        inputView = NSTextView(frame: NSRect(x: 0, y: 0, width: 860, height: 64))

        // Every stored property this class introduces now holds a value, so
        // control can pass up to NSObject.
        //
        // Nothing above this line may *read* a property. Swift's two-phase
        // initialisation lets a subclass assign to its own stored properties
        // before `super.init()` but not read them back, and `window.title = …`
        // is a read of `window` followed by a write to the object it points at —
        // which is why every configuration statement now lives below the call
        // rather than above it.
        super.init()

        window.title = "MacMUSH"
        window.minSize = NSSize(width: 520, height: 320)
        window.isReleasedWhenClosed = false

        // --- output text view inside a scroll view ---
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

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
        textView.textContainer?.size = NSSize(width: textView.frame.width,
                                              height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView

        // --- input: a real text view, so it wraps and can be resized ---
        inputScroll.hasVerticalScroller = true
        inputScroll.autohidesScrollers = true
        inputScroll.borderType = .noBorder
        inputScroll.drawsBackground = true
        inputScroll.backgroundColor = renderer.background

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
        inputView.backgroundColor = renderer.background
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
        inputScroll.documentView = inputView

        promptLabel.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        promptLabel.textColor = .tertiaryLabelColor

        // --- status bar ---
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        logBadge.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        logBadge.textColor = .systemGreen
        logBadge.isHidden = true

        // Monospaced digits, or the timer jitters a pixel every second as the
        // glyph widths change under it.
        elapsedLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        elapsedLabel.textColor = .secondaryLabelColor

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
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // The run loop holds the ticker, not this object. Weak capture keeps it
        // from crashing, but without this it goes on waking once a second
        // forever after the window is gone.
        stopTicker()
    }

    private func layout() {
        let content = NSView()

        buildInputPane()

        // NSSplitView positions its subviews itself, so those keep their
        // autoresizing masks — only the split view is constraint-driven. The
        // starting frames below decide the first-run proportions; after that,
        // `autosaveName` restores wherever the user left the divider.
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        scrollView.frame = NSRect(x: 0, y: 0, width: 884, height: 452)
        inputPane.frame = NSRect(x: 0, y: 0, width: 884, height: 76)
        splitView.addSubview(scrollView)
        splitView.addSubview(inputPane)
        // Set last: a saved divider position needs subviews to restore onto.
        splitView.autosaveName = "MacMUSH.outputInputSplit"

        for view in [splitView, statusLabel, logBadge, elapsedLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        // A long host name shouldn't shove the timer off the right edge — let
        // the status text truncate and keep the readouts pinned.
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [logBadge, elapsedLabel] {
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.setContentHuggingPriority(.required, for: .horizontal)
        }
        // The clock is empty until you connect. Its width is reserved below so
        // the LOG badge doesn't slide sideways the moment it starts ticking —
        // which means hugging has to yield to that reservation rather than
        // fight it and log a broken-constraint warning.
        elapsedLabel.setContentHuggingPriority(NSLayoutConstraint.Priority(999), for: .horizontal)

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            splitView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            splitView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),

            statusLabel.topAnchor.constraint(equalTo: splitView.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),

            logBadge.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            logBadge.leadingAnchor.constraint(greaterThanOrEqualTo: statusLabel.trailingAnchor, constant: 8),

            elapsedLabel.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            elapsedLabel.leadingAnchor.constraint(equalTo: logBadge.trailingAnchor, constant: 8),
            elapsedLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            elapsedLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 62),
        ])
        window.contentView = content
        window.center()
    }

    /// The bottom half of the split: a "›" prompt beside the wrapping command
    /// box. The pane itself is frame-driven (the split view owns it); the two
    /// things inside it use constraints as usual.
    private func buildInputPane() {
        for view in [promptLabel, inputScroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            inputPane.addSubview(view)
        }
        NSLayoutConstraint.activate([
            promptLabel.topAnchor.constraint(equalTo: inputPane.topAnchor, constant: 6),
            promptLabel.leadingAnchor.constraint(equalTo: inputPane.leadingAnchor, constant: 6),

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
        syncInputMinHeight()
    }

    /// Make the whole command box a click target rather than only the lines
    /// that happen to have text on them.
    private func syncInputMinHeight() {
        let visible = inputScroll.contentView.bounds.height
        guard visible > 1, inputView.minSize.height != visible else { return }
        inputView.minSize = NSSize(width: 0, height: visible)
        inputView.sizeToFit()
    }

    func showWindow() {
        window.title = "MacMUSH — \(config.name)"
        window.makeKeyAndOrderFront(nil)
        syncInputMinHeight()
        _ = window.makeFirstResponder(inputView)
        updateStatus()
        showWelcome()
    }

    private func showWelcome() {
        appendSystem("MacMUSH — a native Swift MUD client.")
        appendSystem("World: \(config.name)  —  ⌘R to connect (\(config.host) \(config.port)). Switch or add worlds in the Worlds menu.")
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
        connection?.disconnect()
        connection = nil
        isConnected = false
        connectedAt = nil
        // Dropping the connection deallocates the object whose callback would
        // otherwise have turned echo back on, so do it here. Otherwise a
        // disconnect during a password prompt leaves every line of the *next*
        // session missing from the scrollback and the log.
        setEcho(true)
        stopTicker()
        stopLogging()
        // The next thing typed deserves its own "Not connected." — the warning
        // is once per batch, not once per lifetime of the window.
        warnedNotConnected = false
        updateStatus()
    }

    /// The world this window is currently bound to.
    var currentWorldID: String { config.id }

    /// Switch the live window to a different saved world. Drops any current
    /// connection; the new world connects on the next ⌘R / /connect.
    func activate(world: WorldConfig) {
        if isConnected || connection != nil {
            disconnect()
        }
        config = world
        ansi.resetStyle()
        pendingOps = []
        pendingPlain = ""
        timerFireDates.removeAll()
        setEcho(true)
        window.title = "MacMUSH — \(world.name)"
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
        window.title = "MacMUSH — \(world.name)"
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
        if !isPrompt {
            let result = Matcher.evaluate(config.triggers, line: plain)
            gagged = result.gag
            for match in result.matches where !match.sendText.isEmpty {
                send(match.sendText, echo: false)
            }
        }

        if !gagged {
            renderer.append(lineOps + [.newline], to: textView)
            textView.scrollToEndOfDocument(nil)
            // A gagged line stays out of the log too — if a trigger hid it from
            // you, writing it to disk anyway would be a nasty surprise.
            logLine(plain)
        }
    }

    // MARK: Output helpers

    private func appendSystem(_ message: String) {
        let color = NSColor(srgbRed: 0.53, green: 0.53, blue: 0.80, alpha: 1)
        textView.textStorage?.append(renderer.systemLine(message + "\n", color: color))
        textView.scrollToEndOfDocument(nil)
        logLine(message)
    }

    private func appendEcho(_ line: String) {
        // A MUSH login carries the password on the same line as the character
        // name, and most servers never negotiate telnet ECHO to hide it. Mask
        // it here, which is the one funnel every echoed line passes through, so
        // it reaches neither the scrollback nor the log. What you typed is
        // still in the history buffer, so ↑ brings the real line back.
        let shown = "› " + SessionFormat.redactLogin(line)
        let color = NSColor(srgbRed: 0.91, green: 0.82, blue: 0.38, alpha: 1)
        textView.textStorage?.append(renderer.systemLine(shown + "\n", color: color))
        textView.scrollToEndOfDocument(nil)
        logLine(shown)
    }

    // MARK: Status bar

    private func updateStatus() {
        statusLabel.stringValue = isConnected
            ? "\(config.name)  |  \(currentHost):\(currentPort)"
            : "Not connected"
        logBadge.isHidden = !logger.isActive
        logBadge.toolTip = logger.fileURL?.path
        updateElapsed()
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

        // Slash commands still work while disconnected, so the block can't be
        // rejected up front — `send` warns once for the whole batch instead.
        warnedNotConnected = false
        for line in raw.components(separatedBy: "\n") { submit(line) }
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
        promptLabel.textColor = on ? .tertiaryLabelColor : .systemOrange
        promptLabel.toolTip = on ? nil : "Password mode — this line won't be echoed or logged."
    }

    // MARK: Key handling in the command box

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === inputView else { return false }

        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            sendFromInput()
            return true

        case #selector(NSResponder.insertLineBreak(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            // Shift-Return and Option-Return. AppKit's own insertLineBreak puts
            // in U+2028, which would go down the socket as a stray character —
            // insert a real newline instead.
            textView.insertText("\n", replacementRange: textView.selectedRange)
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

        default:
            return false
        }
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
            disconnect()
            appendSystem("Disconnected.")
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

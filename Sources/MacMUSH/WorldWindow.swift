#if canImport(AppKit)
import AppKit
import MudEngine

/// One MUD window: scrollback text view, command input, status line, and the
/// connection wiring. Code-only AppKit — no storyboards.
final class WorldWindow: NSObject, NSTextFieldDelegate {
    private let window: NSWindow
    private let scrollView = NSScrollView()
    private let textView: NSTextView
    private let input = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "Not connected")

    private let renderer = AnsiRenderer()
    private var ansi = AnsiParser()
    private var connection: MudConnection?

    private var config = WorldStore.shared.selectedWorld
    private var isConnected = false
    private var currentHost = ""
    private var currentPort: UInt16 = 0

    private var history: [String] = []
    private var historyIndex = -1
    private var draft = ""
    private var echoOn = true

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
        window.title = "MacMUSH"
        window.minSize = NSSize(width: 520, height: 320)
        window.isReleasedWhenClosed = false

        // --- output text view inside a scroll view ---
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        let contentSize = scrollView.contentSize
        textView = NSTextView(frame: NSRect(origin: .zero, size: contentSize))
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
        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView

        // --- input + status ---
        input.placeholderString = "Type a command…"
        input.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        input.focusRingType = .none
        input.bezelStyle = .roundedBezel

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        super.init()

        input.delegate = self
        input.target = self
        input.action = #selector(sendFromInput)

        layout()
    }

    private func layout() {
        let content = NSView()
        for v in [scrollView, input, statusLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),

            input.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 6),
            input.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            input.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),

            statusLabel.topAnchor.constraint(equalTo: input.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
        window.contentView = content
        window.center()
    }

    func showWindow() {
        window.title = "MacMUSH — \(config.name)"
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(input)
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
        appendSystem("Connecting to \(host):\(port)…")

        let conn = MudConnection(host: host, port: port)
        conn.onText = { [weak self] text in self?.render(text) }
        conn.onPrompt = { [weak self] in self?.flushLine(isPrompt: true) }
        conn.onEcho = { [weak self] on in self?.setEcho(on) }
        conn.onStateChange = { [weak self] connected, message in
            guard let self = self else { return }
            self.isConnected = connected
            if connected {
                self.statusLabel.stringValue = "Connected to \(self.currentHost):\(self.currentPort)"
                self.appendSystem("Connected.")
                self.sendConnectText()
                self.armTimers()
                self.startTicker()
            } else {
                self.statusLabel.stringValue = "Not connected"
                if let message = message { self.appendSystem(message) }
                self.setEcho(true)
                self.stopTicker()
            }
        }
        conn.start()
        connection = conn
    }

    func disconnect() {
        connection?.disconnect()
        connection = nil
        isConnected = false
        stopTicker()
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
        statusLabel.stringValue = "Not connected"
        window.title = "MacMUSH — \(world.name)"
        appendSystem("— Switched to \(world.name)  (\(world.host) \(world.port)).  ⌘R to connect. —")
    }

    /// Adopt edits to the world this window is already showing — a rename, or a
    /// change made in the Worlds window — without disturbing the connection or
    /// scrollback. New triggers and aliases take effect on the next line; timers
    /// are re-armed below.
    func syncActiveWorld(_ world: WorldConfig) {
        guard world.id == config.id else { return }
        config = world
        window.title = "MacMUSH — \(world.name)"
        reconcileTimers()
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
        }
    }

    // MARK: Output helpers

    private func appendSystem(_ message: String) {
        let color = NSColor(srgbRed: 0.53, green: 0.53, blue: 0.80, alpha: 1)
        textView.textStorage?.append(renderer.systemLine(message + "\n", color: color))
        textView.scrollToEndOfDocument(nil)
    }

    private func appendEcho(_ line: String) {
        let color = NSColor(srgbRed: 0.91, green: 0.82, blue: 0.38, alpha: 1)
        textView.textStorage?.append(renderer.systemLine("› " + line + "\n", color: color))
        textView.scrollToEndOfDocument(nil)
    }

    // MARK: Sending

    /// Send one or more lines to the MUD (multi-line text is split on "\n").
    private func send(_ text: String, echo: Bool) {
        guard connection != nil else {
            appendSystem("Not connected.")
            return
        }
        for line in text.components(separatedBy: "\n") {
            connection?.send(line)
            if echo && echoOn { appendEcho(line) }
        }
    }

    // MARK: Input

    @objc private func sendFromInput() {
        let raw = input.stringValue
        input.stringValue = ""
        if !raw.isEmpty && history.last != raw {
            history.append(raw)
            if history.count > 200 { history.removeFirst() }
        }
        historyIndex = -1
        draft = ""

        if raw.hasPrefix("/") {
            handleCommand(raw)
            return
        }

        let result = Matcher.evaluate(config.aliases, line: raw)
        if result.matches.isEmpty {
            send(raw, echo: true)
        } else {
            if echoOn { appendEcho(raw) }
            for match in result.matches where !match.sendText.isEmpty {
                send(match.sendText, echo: false)
            }
        }
    }

    private func setEcho(_ on: Bool) {
        echoOn = on
        input.placeholderString = on ? "Type a command…" : "Password (hidden)…"
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
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func stopTicker() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func tick() {
        guard isConnected else { return }
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
        appendSystem("Added \(kind == .alias ? "alias" : "trigger"): \(pattern)  →  \(sendText)")
    }

    private func addTimer(_ spec: String) {
        guard let eq = spec.firstIndex(of: "=") else {
            appendSystem("Usage: /timer <seconds>=<send>")
            return
        }
        let secStr = String(spec[..<eq]).trimmingCharacters(in: .whitespaces)
        let sendText = String(spec[spec.index(after: eq)...])
        guard let seconds = Double(secStr), seconds > 0 else {
            appendSystem("Seconds must be a positive number.")
            return
        }
        let timer = MudTimer(seconds: seconds, sendText: sendText)
        config.timers.append(timer)
        if isConnected { timerFireDates[timer.id] = Date().addingTimeInterval(seconds) }
        saveConfig()
        appendSystem("Added timer: every \(secStr)s  →  \(sendText)")
    }

    private func listRules(_ rules: [MatchRule], label: String) {
        guard !rules.isEmpty else { appendSystem("\(label): (none)"); return }
        appendSystem("\(label):")
        for (i, r) in rules.enumerated() {
            let flags = (r.enabled ? "" : " [off]") + (r.gag ? " [gag]" : "") + (r.isRegex ? " [regex]" : "")
            appendSystem("  \(i + 1). \(r.pattern)  →  \(r.sendText)\(flags)")
        }
    }

    private func listTimers() {
        guard !config.timers.isEmpty else { appendSystem("Timers: (none)"); return }
        appendSystem("Timers:")
        for (i, t) in config.timers.enumerated() {
            let flags = (t.enabled ? "" : " [off]") + (t.oneShot ? " [once]" : "")
            appendSystem("  \(i + 1). every \(t.seconds)s  →  \(t.sendText)\(flags)")
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

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            recallHistory(delta: -1)
            return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            recallHistory(delta: 1)
            return true
        }
        return false
    }

    private func recallHistory(delta: Int) {
        guard !history.isEmpty else { return }
        if historyIndex == -1 {
            draft = input.stringValue
            historyIndex = history.count
        }
        historyIndex = max(0, min(history.count, historyIndex + delta))
        if historyIndex >= history.count {
            historyIndex = -1
            input.stringValue = draft
        } else {
            input.stringValue = history[historyIndex]
        }
        input.currentEditor()?.selectedRange = NSRange(location: input.stringValue.count, length: 0)
    }
}
#endif

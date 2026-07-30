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

    private var history: [String] = []
    private var historyIndex = -1
    private var draft = ""
    private var echoOn = true
    private var currentHost = ""
    private var currentPort: UInt16 = 0

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
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(input)
        showWelcome()
    }

    private func showWelcome() {
        appendSystem("MacMUSH — a native Swift MUD client.")
        appendSystem("Press ⌘R to connect. For a test target, run:  node scripts/fake-mud.js")
        appendSystem("then connect to 127.0.0.1 port 4000.\n")
    }

    // MARK: Connection

    func connect(host: String, port: UInt16) {
        disconnect()
        currentHost = host
        currentPort = port
        ansi.resetStyle()
        appendSystem("Connecting to \(host):\(port)…")

        let conn = MudConnection(host: host, port: port)
        conn.onText = { [weak self] text in self?.render(text) }
        conn.onPrompt = { [weak self] in self?.render("\n") }
        conn.onEcho = { [weak self] on in self?.setEcho(on) }
        conn.onStateChange = { [weak self] connected, message in
            guard let self = self else { return }
            if connected {
                self.statusLabel.stringValue = "Connected to \(self.currentHost):\(self.currentPort)"
                self.appendSystem("Connected.")
            } else {
                self.statusLabel.stringValue = "Not connected"
                if let message = message { self.appendSystem(message) }
                self.setEcho(true)
            }
        }
        conn.start()
        connection = conn
    }

    func disconnect() {
        connection?.disconnect()
        connection = nil
    }

    func promptConnect() {
        let alert = NSAlert()
        alert.messageText = "Connect to a MUD"
        alert.informativeText = "Enter a host and port (e.g. 127.0.0.1 4000)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = currentHost.isEmpty ? "127.0.0.1 4000" : "\(currentHost) \(currentPort)"
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

    // MARK: Output

    private func render(_ text: String) {
        let ops = ansi.feed(text)
        renderer.append(ops, to: textView)
        textView.scrollToEndOfDocument(nil)
    }

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

    // MARK: Input

    @objc private func sendFromInput() {
        let line = input.stringValue
        input.stringValue = ""
        if !line.isEmpty && history.last != line {
            history.append(line)
            if history.count > 200 { history.removeFirst() }
        }
        historyIndex = -1
        draft = ""
        if echoOn { appendEcho(line) }
        connection?.send(line)
    }

    private func setEcho(_ on: Bool) {
        echoOn = on
        input.placeholderString = on ? "Type a command…" : "Password (hidden)…"
    }

    // Arrow-key history recall.
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

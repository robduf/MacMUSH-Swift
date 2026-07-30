#if canImport(Network)
import Foundation
import Network
import MudEngine

/// A live TCP connection to a MUD, wired through the telnet parser. All public
/// callbacks are delivered on the main queue so the UI can touch AppKit freely.
final class MudConnection {
    var onText: ((String) -> Void)?
    var onPrompt: (() -> Void)?
    var onStateChange: ((Bool, String?) -> Void)?   // (connected, message)
    var onEcho: ((Bool) -> Void)?
    /// Something worth printing that is *not* a change of connection state.
    var onNotice: ((String) -> Void)?

    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let telnet: TelnetParser
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.rob.macmush.connection")
    private var didReportClose = false
    private var didBecomeReady = false
    private var lastNotice: String?
    private var stallTimer: DispatchSourceTimer?

    /// How long a stall on an already-established connection may last before we
    /// call it a disconnect. Long enough to ride out a Wi-Fi handover or a lid
    /// closed for a moment; short enough that you are not typing into a dead
    /// socket all evening believing you are still in the room.
    private static let stallTimeout: TimeInterval = 45

    init(host: String, port: UInt16) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port) ?? 23
        self.telnet = TelnetParser()

        telnet.onText = { [weak self] text in
            DispatchQueue.main.async { self?.onText?(text) }
        }
        telnet.onPrompt = { [weak self] in
            DispatchQueue.main.async { self?.onPrompt?() }
        }
        telnet.onEcho = { [weak self] on in
            DispatchQueue.main.async { self?.onEcho?(on) }
        }
        telnet.onSend = { [weak self] data in
            self?.rawSend(data)
        }
    }

    func start() {
        let conn = NWConnection(host: host, port: port, using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                let firstTime = !self.didBecomeReady
                self.didBecomeReady = true
                self.lastNotice = nil
                self.cancelStallTimer()
                if firstTime {
                    DispatchQueue.main.async { self.onStateChange?(true, nil) }
                    self.receiveLoop()
                } else {
                    // Coming back from .waiting is a *recovery*, not a new
                    // session: re-reporting "connected" would restart the clock
                    // and roll the log, and starting a second receive loop
                    // would interleave two readers on one socket.
                    DispatchQueue.main.async { self.onNotice?("Connection recovered.") }
                }
            case .failed(let error):
                self.reportClose("Connection failed: \(error.localizedDescription)")
            case .waiting(let error):
                // NWConnection reports .waiting for everything from a Wi-Fi
                // hiccup to a host that will never answer, and it retries
                // forever rather than failing. Reporting the first one as a
                // disconnect would close the session log and restart the
                // connected-time clock over a blip that never cost us the
                // socket — so say so once, and start a clock instead.
                let notice = "Waiting: \(error.localizedDescription)"
                if self.lastNotice != notice {
                    self.lastNotice = notice
                    DispatchQueue.main.async { self.onNotice?(notice) }
                }
                // Before the first .ready, waiting *is* connecting: the window
                // still says "Not connected" and there is nothing to tear down.
                // Afterwards it means a live session has gone quiet, and sitting
                // there showing a ticking clock and an open log is the worst of
                // the available lies.
                if self.didBecomeReady { self.startStallTimer() }
            case .cancelled:
                self.reportClose("Disconnected.")
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.telnet.feed(data)
            }
            if let error = error {
                self.reportClose("Read error: \(error.localizedDescription)")
                return
            }
            if isComplete {
                self.reportClose("Connection closed by the server.")
                return
            }
            self.receiveLoop()
        }
    }

    /// Send a line of user input (alias/trigger processing happens above this).
    func send(_ line: String) {
        rawSend(telnet.encodeLine(line))
    }

    private func rawSend(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    func setWindowSize(cols: Int, rows: Int) {
        queue.async { [weak self] in self?.telnet.sendWindowSize(cols: cols, rows: rows) }
    }

    func disconnect() {
        queue.async { [weak self] in self?.cancelStallTimer() }
        connection?.cancel()
        connection = nil
    }

    deinit {
        // The run loop, not this object, owns a resumed dispatch source. Without
        // this it would keep waking every 45 seconds after the window let go.
        stallTimer?.cancel()
    }

    // MARK: Stall watchdog

    /// A stall on an established connection that never recovers has to end as a
    /// disconnect. NWConnection will retry a dead route indefinitely and never
    /// report `.failed`, so nothing else is ever going to tell us.
    private func startStallTimer() {
        guard stallTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + MudConnection.stallTimeout)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.reportClose("Connection lost — no response for \(Int(MudConnection.stallTimeout)) seconds.")
            self.connection?.cancel()
        }
        timer.resume()
        stallTimer = timer
    }

    private func cancelStallTimer() {
        stallTimer?.cancel()
        stallTimer = nil
    }

    private func reportClose(_ message: String) {
        cancelStallTimer()
        guard !didReportClose else { return }
        didReportClose = true
        DispatchQueue.main.async { self.onStateChange?(false, message) }
    }
}
#endif

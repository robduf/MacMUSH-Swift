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
    private var keepaliveTimer: DispatchSourceTimer?

    /// How long a stall on an already-established connection may last before we
    /// call it a disconnect. Long enough to ride out a Wi-Fi handover or a lid
    /// closed for a moment; short enough that you are not typing into a dead
    /// socket all evening believing you are still in the room.
    private static let stallTimeout: TimeInterval = 45

    /// How often to put a couple of bytes on the connection so that nothing in
    /// the middle decides it has gone quiet and forgets it.
    ///
    /// A minute is chosen against the thing that actually breaks this, which is
    /// the connection-tracking table in a router or a carrier NAT. The shortest
    /// eviction windows in common use are around five minutes, so a minute leaves
    /// room for a probe to go missing and the one after it still to land inside
    /// the window.
    private static let noOpInterval: TimeInterval = 60

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
        // Keep-alive at the transport layer, as well as the telnet NOP on a timer
        // below. The two are not redundant: these probes are empty TCP segments,
        // and a fair number of middleboxes decline to count a segment with no
        // payload as activity at all, while the NOP is real payload that every
        // one of them counts. The NOP is what keeps the connection *alive*; this
        // is what notices in good time when it isn't.
        //
        // The idle figure is the point of doing this by hand. macOS defaults to
        // two hours, which is no use against something measured in minutes — see
        // `noOpInterval` for the windows this is really up against. A dead socket
        // that nothing probes stays open and plausible until you type into it.
        //
        // Thirty, ten, three: three probes, the first after half a minute of
        // quiet and the next two ten seconds apart, and ten seconds after the
        // last of them goes unanswered the connection is dropped. A minute, near
        // enough. That minute is the best case rather than a promise, though,
        // because keep-alive probes only run with nothing outstanding.
        // If the route dies while the last NOP is still unacknowledged it is the
        // retransmit timer that governs instead, and macOS backs that off for
        // the better part of ten minutes. `tcp.connectionDropTime` would cap it,
        // and is deliberately not set: it would also hang up on the slow link
        // that was about to come back, which is the whole reason `.waiting` is
        // ridden out rather than reported. The stall watchdog below covers the
        // same ground from the other side, on a clock we choose.
        //
        // None of which is the case that brought this in. A NAT that has dropped
        // the connection from its table does not go quiet — it answers the next
        // NOP with a reset, inside a round trip.
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        tcp.keepaliveInterval = 10
        tcp.keepaliveCount = 3

        let conn = NWConnection(host: host, port: port,
                                using: NWParameters(tls: nil, tcp: tcp))
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
                    self.startKeepaliveTimer()
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

    /// Every write goes out from `queue`, whoever asked for it.
    ///
    /// The hop is not ceremony. `connection` is cleared by `disconnect` and read
    /// here, and the callers arrive on two different threads: `send` from the
    /// main thread as you type, `telnet.onSend` and the keep-alive from the
    /// queue. One thread letting go of the socket while another is reading that
    /// same reference is a use-after-free — and the keep-alive is what turns it
    /// from a race you would have to be unlucky to lose into one that is live
    /// every sixty seconds, on exactly the idle connections it was added for.
    ///
    /// So: every access to `connection` happens on `queue`, with the single
    /// exception of the write in `start`, which is off the queue and safe only
    /// because it happens before `conn.start(queue:)` — before this object has
    /// put anything on the queue at all, and before anything can call in. That
    /// is the whole of the rule. A reconnect-in-place that called `start` twice
    /// on a live object would break it and put the race straight back.
    private func rawSend(_ data: Data) {
        queue.async { [weak self] in
            self?.connection?.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    func setWindowSize(cols: Int, rows: Int) {
        queue.async { [weak self] in self?.telnet.sendWindowSize(cols: cols, rows: rows) }
    }

    /// All of it on the queue, the socket included — see `rawSend` for why.
    ///
    /// This is called from the main thread, and the timers and the writes all
    /// live on `queue`, so letting go of the socket here would be doing it out
    /// from under whichever of them is mid-flight.
    func disconnect() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.cancelStallTimer()
            self.cancelKeepaliveTimer()
            self.connection?.cancel()
            self.connection = nil
        }
    }

    deinit {
        // The run loop, not this object, owns a resumed dispatch source. Without
        // this they would both keep waking on their own schedules after the
        // window let go — and the keep-alive would go on writing to a socket
        // nobody is reading from.
        stallTimer?.cancel()
        keepaliveTimer?.cancel()
        // And the socket — which is usually this line's job rather than
        // `disconnect`'s. `Session.disconnect` cuts our callbacks and drops its
        // reference in the same breath as calling us, so by the ordinary route
        // the last reference is gone before the queue ever runs that block, and
        // the block wakes to a nil `weak self` and does nothing.
        //
        // It matters most at ⌘Q. `applicationWillTerminate` walks the windows
        // disconnecting as it goes, and the process exits without the queue
        // being scheduled again — so without this, no FIN is ever written and
        // every world is left for the MUD to time out, which is exactly what
        // that teardown exists to avoid.
        //
        // Touching queue-owned state from here is safe for one reason: every
        // closure in this class that runs on `queue` captures `self` weakly, so
        // none of them can be in flight while this runs. A single strong capture
        // added anywhere above would take that away.
        connection?.cancel()
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

    // MARK: Keep-alive

    /// Two bytes a minute, so the connection is still there when you next have
    /// something to say. See `TelnetParser.encodeNoOperation` for what they are
    /// and why they're those.
    ///
    /// Repeating, and unconditional rather than only-when-idle. Gating it on a
    /// last-wrote-at timestamp would be safe enough — `rawSend`'s body runs on
    /// this same queue — but it would buy nothing: the saving is two bytes a
    /// minute, and only during a conversation you are already typing into, which
    /// is the one time the connection was never at risk.
    private func startKeepaliveTimer() {
        guard keepaliveTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + MudConnection.noOpInterval,
                       repeating: MudConnection.noOpInterval)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            // Deliberately not gated on connection state. While the connection
            // is `.waiting` the send is simply queued, and a probe landing just
            // as a stalled route comes back is the moment this is most use.
            // What keeps this off a socket that is already finished is not a
            // check here but the two places that cancel this timer: `disconnect`
            // when you close it yourself, and `reportClose` for every other way
            // a connection ends. A third route out would need to do the same.
            self.rawSend(self.telnet.encodeNoOperation())
        }
        timer.resume()
        keepaliveTimer = timer
    }

    private func cancelKeepaliveTimer() {
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
    }

    private func reportClose(_ message: String) {
        cancelStallTimer()
        cancelKeepaliveTimer()
        guard !didReportClose else { return }
        didReportClose = true
        DispatchQueue.main.async { self.onStateChange?(false, message) }
    }
}
#endif

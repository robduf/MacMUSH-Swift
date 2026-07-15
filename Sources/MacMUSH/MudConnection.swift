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

    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let telnet: TelnetParser
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.rob.macmush.connection")
    private var didReportClose = false

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
                DispatchQueue.main.async { self.onStateChange?(true, nil) }
                self.receiveLoop()
            case .failed(let error):
                self.reportClose("Connection failed: \(error.localizedDescription)")
            case .waiting(let error):
                DispatchQueue.main.async { self.onStateChange?(false, "Waiting: \(error.localizedDescription)") }
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
        connection?.cancel()
        connection = nil
    }

    private func reportClose(_ message: String) {
        guard !didReportClose else { return }
        didReportClose = true
        DispatchQueue.main.async { self.onStateChange?(false, message) }
    }
}
#endif

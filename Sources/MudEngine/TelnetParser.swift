// Telnet protocol parser for MUD connections. Handles IAC negotiation,
// subnegotiation, TTYPE/NAWS replies, ECHO suppression (passwords), and GA/EOR
// prompt marking. Pure Foundation so it can be unit-tested off-device.
//
// Not yet handled (planned): MCCP2 compression and GMCP. The parser negotiates
// them down for now so plain connections work correctly.

import Foundation

public final class TelnetParser {
    // MARK: Callbacks
    /// Decoded UTF-8 text (ANSI codes still embedded).
    public var onText: ((String) -> Void)?
    /// Server sent IAC GA / IAC EOR — the current line is a prompt.
    public var onPrompt: (() -> Void)?
    /// Bytes the parser wants written back to the socket.
    public var onSend: ((Data) -> Void)?
    /// Server-controlled echo state. `false` => hide input (e.g. password).
    public var onEcho: ((Bool) -> Void)?

    // MARK: Telnet constants
    private let IAC: UInt8 = 255
    private let DONT: UInt8 = 254, DO: UInt8 = 253, WONT: UInt8 = 252, WILL: UInt8 = 251
    private let SB: UInt8 = 250, GA: UInt8 = 249, SE: UInt8 = 240, EOR_CMD: UInt8 = 239
    private let NOP: UInt8 = 241
    // Options
    private let OPT_ECHO: UInt8 = 1, OPT_SGA: UInt8 = 3, OPT_TTYPE: UInt8 = 24
    private let OPT_EOR: UInt8 = 25, OPT_NAWS: UInt8 = 31
    private let OPT_MCCP2: UInt8 = 86, OPT_GMCP: UInt8 = 201
    private let TTYPE_IS: UInt8 = 0, TTYPE_SEND: UInt8 = 1

    // MARK: State
    private enum State { case data, iac, negotiate, sbOption, sbData, sbIac }
    private var state: State = .data
    private var negotiateVerb: UInt8 = 0
    private var sbOption: UInt8 = 0
    private var sbBuffer: [UInt8] = []
    private var textBytes: [UInt8] = []
    private var decoder = UTF8Incremental()
    private var echoSuppressed = false
    private var weWill = Set<UInt8>()
    private var theyWill = Set<UInt8>()
    private var ttypeIndex = 0

    private let terminalName: String
    private var windowSize: (cols: Int, rows: Int)

    public init(terminalName: String = "MACMUSH", windowSize: (cols: Int, rows: Int) = (100, 40)) {
        self.terminalName = terminalName.uppercased()
        self.windowSize = windowSize
    }

    // MARK: Feed
    public func feed(_ data: Data) {
        for b in data { process(b) }
        flushText()
    }

    private func process(_ b: UInt8) {
        switch state {
        case .data:
            if b == IAC { state = .iac } else { textBytes.append(b) }

        case .iac:
            switch b {
            case IAC:                       // escaped 0xFF
                textBytes.append(IAC)
                state = .data
            case WILL, WONT, DO, DONT:
                negotiateVerb = b
                state = .negotiate
            case SB:
                state = .sbOption
            case GA, EOR_CMD:
                flushText()
                onPrompt?()
                state = .data
            default:
                state = .data               // NOP, DM, etc. — ignore
            }

        case .negotiate:
            handleNegotiation(verb: negotiateVerb, option: b)
            state = .data

        case .sbOption:
            sbOption = b
            sbBuffer = []
            state = .sbData

        case .sbData:
            if b == IAC { state = .sbIac } else { sbBuffer.append(b) }

        case .sbIac:
            if b == IAC {                   // escaped 0xFF inside subnegotiation
                sbBuffer.append(IAC)
                state = .sbData
            } else if b == SE {
                handleSubnegotiation(option: sbOption, data: sbBuffer)
                state = .data
            } else {
                state = .data               // malformed
            }
        }
    }

    private func flushText() {
        guard !textBytes.isEmpty else { return }
        let bytes = textBytes
        textBytes.removeAll(keepingCapacity: true)
        let s = decoder.decode(bytes)
        if !s.isEmpty { onText?(s) }
    }

    private func reply(_ bytes: UInt8...) {
        onSend?(Data(bytes))
    }

    // MARK: Negotiation
    private func handleNegotiation(verb: UInt8, option: UInt8) {
        switch verb {
        case WILL:
            switch option {
            case OPT_ECHO:
                theyWill.insert(option)
                reply(IAC, DO, OPT_ECHO)
                if !echoSuppressed { echoSuppressed = true; onEcho?(false) }
            case OPT_SGA:
                theyWill.insert(option)
                reply(IAC, DO, OPT_SGA)
            case OPT_EOR:
                theyWill.insert(option)
                reply(IAC, DO, OPT_EOR)
            default:
                // Includes MCCP2 / GMCP for now: decline until supported.
                reply(IAC, DONT, option)
            }

        case WONT:
            if option == OPT_ECHO && echoSuppressed {
                echoSuppressed = false
                onEcho?(true)
            }
            theyWill.remove(option)
            reply(IAC, DONT, option)

        case DO:
            switch option {
            case OPT_TTYPE:
                weWill.insert(option)
                reply(IAC, WILL, OPT_TTYPE)
            case OPT_NAWS:
                weWill.insert(option)
                reply(IAC, WILL, OPT_NAWS)
                sendWindowSize(cols: windowSize.cols, rows: windowSize.rows)
            case OPT_SGA:
                weWill.insert(option)
                reply(IAC, WILL, OPT_SGA)
            default:
                reply(IAC, WONT, option)
            }

        case DONT:
            weWill.remove(option)
            reply(IAC, WONT, option)

        default:
            break
        }
    }

    private func handleSubnegotiation(option: UInt8, data: [UInt8]) {
        if option == OPT_TTYPE, data.first == TTYPE_SEND {
            // MTTS-style cycle through terminal descriptions.
            let names = [terminalName, "XTERM-256COLOR", "MTTS 267"]
            let name = names[min(ttypeIndex, names.count - 1)]
            ttypeIndex += 1
            var payload: [UInt8] = [IAC, SB, OPT_TTYPE, TTYPE_IS]
            payload.append(contentsOf: Array(name.utf8))
            payload.append(contentsOf: [IAC, SE])
            onSend?(Data(payload))
        }
        // NAWS-from-server and other subnegotiations are ignored.
    }

    // MARK: Outgoing helpers
    /// Escape IAC bytes in user input and append CR LF.
    public func encodeLine(_ text: String) -> Data {
        var out: [UInt8] = []
        for b in text.utf8 {
            out.append(b)
            if b == IAC { out.append(IAC) }
        }
        out.append(13)
        out.append(10)
        return Data(out)
    }

    public func sendWindowSize(cols: Int, rows: Int) {
        windowSize = (cols, rows)
        guard weWill.contains(OPT_NAWS) else { return }
        var payload: [UInt8] = [IAC, SB, OPT_NAWS]
        for v in [UInt8((cols >> 8) & 0xff), UInt8(cols & 0xff),
                  UInt8((rows >> 8) & 0xff), UInt8(rows & 0xff)] {
            payload.append(v)
            if v == IAC { payload.append(IAC) }
        }
        payload.append(contentsOf: [IAC, SE])
        onSend?(Data(payload))
    }
}

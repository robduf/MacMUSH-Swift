import Foundation
import MudEngine

final class TelnetParserTests {

    private let IAC: UInt8 = 255, DO: UInt8 = 253, DONT: UInt8 = 254
    private let WILL: UInt8 = 251, WONT: UInt8 = 252, SB: UInt8 = 250, SE: UInt8 = 240
    private let GA: UInt8 = 249
    private let TTYPE: UInt8 = 24, NAWS: UInt8 = 31, ECHO: UInt8 = 1

    func testPlainTextPassesThrough() {
        let p = TelnetParser()
        var text = ""
        p.onText = { text += $0 }
        p.feed(Data("Hello, world!\r\n".utf8))
        XCTAssertEqual(text, "Hello, world!\r\n")
    }

    func testEscapedIACAndSplitMultibyte() {
        let p = TelnetParser()
        var text = ""
        p.onText = { text += $0 }
        let coffee = Array("café ☕".utf8)
        // IAC IAC (escaped 0xFF) then the first 4 bytes of the UTF-8...
        p.feed(Data([IAC, IAC] + coffee[0..<4]))
        p.feed(Data(coffee[4...]))
        // 0xFF alone is invalid UTF-8 -> replacement char, but the multibyte
        // characters survive the chunk split intact.
        XCTAssertTrue(text.contains("café ☕"))
    }

    func testNegotiationResponses() {
        let p = TelnetParser(terminalName: "MACMUSH", windowSize: (cols: 120, rows: 50))
        var sent = Data()
        p.onSend = { sent.append($0) }
        p.feed(Data([IAC, DO, 99]))            // unknown -> WONT
        p.feed(Data([IAC, WILL, 99]))          // unknown -> DONT
        p.feed(Data([IAC, DO, TTYPE]))         // -> WILL TTYPE
        p.feed(Data([IAC, DO, NAWS]))          // -> WILL NAWS + size
        p.feed(Data([IAC, SB, TTYPE, 1, IAC, SE]))  // TTYPE SEND -> IS name

        XCTAssertNotNil(sent.range(of: Data([IAC, WONT, 99])))
        XCTAssertNotNil(sent.range(of: Data([IAC, DONT, 99])))
        XCTAssertNotNil(sent.range(of: Data([IAC, WILL, TTYPE])))
        XCTAssertNotNil(sent.range(of: Data([IAC, WILL, NAWS])))
        // NAWS payload: 120 = 0x78, 50 = 0x32
        XCTAssertNotNil(sent.range(of: Data([IAC, SB, NAWS, 0, 120, 0, 50, IAC, SE])))
        XCTAssertNotNil(sent.range(of: Data("MACMUSH".utf8)))
    }

    func testEchoSuppression() {
        let p = TelnetParser()
        var echoes: [Bool] = []
        p.onEcho = { echoes.append($0) }
        p.feed(Data([IAC, WILL, ECHO]))
        p.feed(Data([IAC, WONT, ECHO]))
        XCTAssertEqual(echoes, [false, true])
    }

    func testGAPromptFlushesText() {
        let p = TelnetParser()
        var events: [String] = []
        p.onText = { events.append("text:\($0)") }
        p.onPrompt = { events.append("prompt") }
        p.feed(Data("Enter name: ".utf8) + Data([IAC, GA]))
        XCTAssertEqual(events, ["text:Enter name: ", "prompt"])
    }

    func testEncodeLineEscapesIACAndAddsCRLF() {
        let p = TelnetParser()
        let data = p.encodeLine("hi")
        XCTAssertEqual(Array(data), [104, 105, 13, 10])
    }

    func testUTF8IncrementalHoldsPartial() {
        var dec = UTF8Incremental()
        let euro = Array("€".utf8)   // 3 bytes: E2 82 AC
        XCTAssertEqual(dec.decode(Array(euro[0..<2])), "")   // incomplete
        XCTAssertEqual(dec.decode([euro[2]]), "€")           // completes
    }
}

// Every test in this file, listed because a plain executable has no runtime
// discovery to find them for us. A test missing from here never runs.
// See TestHarness.swift.
extension TelnetParserTests {
    static let suite = TestSuite("TelnetParserTests", [
        ("testPlainTextPassesThrough", { TelnetParserTests().testPlainTextPassesThrough() }),
        ("testEscapedIACAndSplitMultibyte", { TelnetParserTests().testEscapedIACAndSplitMultibyte() }),
        ("testNegotiationResponses", { TelnetParserTests().testNegotiationResponses() }),
        ("testEchoSuppression", { TelnetParserTests().testEchoSuppression() }),
        ("testGAPromptFlushesText", { TelnetParserTests().testGAPromptFlushesText() }),
        ("testEncodeLineEscapesIACAndAddsCRLF", { TelnetParserTests().testEncodeLineEscapesIACAndAddsCRLF() }),
        ("testUTF8IncrementalHoldsPartial", { TelnetParserTests().testUTF8IncrementalHoldsPartial() }),
    ])
}

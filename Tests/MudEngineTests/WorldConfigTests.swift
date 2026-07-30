import XCTest
@testable import MudEngine

final class WorldConfigTests: XCTestCase {

    func testCodableRoundTrip() throws {
        var config = WorldConfig(name: "Test", host: "mud.example.org", port: 4000)
        config.aliases.append(MatchRule(pattern: "gt * *", sendText: "give %2 to %1"))
        config.triggers.append(MatchRule(pattern: "* tells you *", sendText: "wave", gag: true))
        config.timers.append(MudTimer(seconds: 60, sendText: "look"))
        config.connectText = "connect Char pass"

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(WorldConfig.self, from: data)

        XCTAssertEqual(decoded, config)
        XCTAssertEqual(decoded.id, config.id)               // stable id round-trips
        XCTAssertEqual(decoded.aliases.count, 1)
        XCTAssertEqual(decoded.triggers.first?.gag, true)
        XCTAssertEqual(decoded.timers.first?.seconds, 60)
    }

    func testDefaults() {
        let config = WorldConfig()
        XCTAssertEqual(config.host, "127.0.0.1")
        XCTAssertEqual(config.port, 4000)
        XCTAssertTrue(config.triggers.isEmpty)
        XCTAssertFalse(config.id.isEmpty)
    }

    /// Two freshly-created worlds get distinct ids.
    func testDistinctIDs() {
        XCTAssertNotEqual(WorldConfig().id, WorldConfig().id)
    }

    /// JSON written by an older version (no `id` key, and missing several other
    /// fields) must still decode, filling defaults and minting a fresh id.
    func testLenientDecodeOfLegacyJSON() throws {
        let legacy = """
        { "name": "Legacy", "host": "old.example.net", "port": 5000 }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(WorldConfig.self, from: legacy)

        XCTAssertEqual(decoded.name, "Legacy")
        XCTAssertEqual(decoded.host, "old.example.net")
        XCTAssertEqual(decoded.port, 5000)
        XCTAssertFalse(decoded.id.isEmpty)          // minted, not crashed
        XCTAssertEqual(decoded.connectText, "")     // defaulted
        XCTAssertTrue(decoded.triggers.isEmpty)     // defaulted
        XCTAssertTrue(decoded.aliases.isEmpty)
        XCTAssertTrue(decoded.timers.isEmpty)
    }
}

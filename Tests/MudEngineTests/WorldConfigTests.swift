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
        XCTAssertEqual(decoded.aliases.count, 1)
        XCTAssertEqual(decoded.triggers.first?.gag, true)
        XCTAssertEqual(decoded.timers.first?.seconds, 60)
    }

    func testDefaults() {
        let config = WorldConfig()
        XCTAssertEqual(config.host, "127.0.0.1")
        XCTAssertEqual(config.port, 4000)
        XCTAssertTrue(config.triggers.isEmpty)
    }
}

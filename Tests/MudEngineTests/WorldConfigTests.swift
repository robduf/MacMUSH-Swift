import Foundation
import MudEngine

final class WorldConfigTests {

    func testCodableRoundTrip() throws {
        var config = WorldConfig(name: "Test", host: "mud.example.org", port: 4000)
        config.aliases.append(MatchRule(pattern: "gt * *", sendText: "give %2 to %1"))
        config.triggers.append(MatchRule(pattern: "* tells you *", sendText: "wave", gag: true))
        config.timers.append(MudTimer(seconds: 60, sendText: "look"))
        config.connectText = "connect Char pass"
        config.logEnabled = true
        config.logDirectory = "/Users/somebody/Logs"
        config.chimeEnabled = true
        config.echoInput = false

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(WorldConfig.self, from: data)

        XCTAssertEqual(decoded, config)
        XCTAssertEqual(decoded.id, config.id)               // stable id round-trips
        XCTAssertEqual(decoded.aliases.count, 1)
        XCTAssertEqual(decoded.triggers.first?.gag, true)
        XCTAssertEqual(decoded.timers.first?.seconds, 60)
        XCTAssertTrue(decoded.logEnabled)
        XCTAssertEqual(decoded.logDirectory, "/Users/somebody/Logs")
        XCTAssertTrue(decoded.chimeEnabled)
        XCTAssertFalse(decoded.echoInput)
    }

    /// Both of the per-world switches have to survive being set *away* from
    /// their default, which is the direction a missing `encode` line breaks: the
    /// decoder's fallback would quietly hand back the default and the setting
    /// would appear to un-tick itself between launches.
    func testTogglesSurviveTheirNonDefaultValue() throws {
        var config = WorldConfig(name: "Shang")
        config.echoInput = false        // defaults true
        config.chimeEnabled = true      // defaults false

        let decoded = try JSONDecoder().decode(
            WorldConfig.self, from: try JSONEncoder().encode(config))

        XCTAssertFalse(decoded.echoInput)
        XCTAssertTrue(decoded.chimeEnabled)
    }

    /// Logging off with a folder still remembered: turning the checkbox back on
    /// must not have lost where the user had pointed it.
    func testLogDirectorySurvivesLoggingBeingOff() throws {
        var config = WorldConfig(name: "Shang")
        config.logEnabled = false
        config.logDirectory = "~/Documents/Shang"

        let decoded = try JSONDecoder().decode(
            WorldConfig.self, from: try JSONEncoder().encode(config))

        XCTAssertFalse(decoded.logEnabled)
        XCTAssertEqual(decoded.logDirectory, "~/Documents/Shang")
    }

    func testDefaults() {
        let config = WorldConfig()
        XCTAssertEqual(config.host, "127.0.0.1")
        XCTAssertEqual(config.port, 4000)
        XCTAssertTrue(config.triggers.isEmpty)
        XCTAssertFalse(config.id.isEmpty)
        // Pinned because `echoInput` is the one field that defaults on. Without
        // this, tidying it to `false` to match its neighbours would pass every
        // other test in the file and quietly stop new worlds echoing.
        XCTAssertTrue(config.echoInput)
        XCTAssertFalse(config.chimeEnabled)
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

        // Logging arrived after this JSON was written: it must default to off,
        // not start silently recording a world the user never opted in for.
        XCTAssertFalse(decoded.logEnabled)
        XCTAssertEqual(decoded.logDirectory, "")

        // The chime is the same story: silent unless asked for.
        XCTAssertFalse(decoded.chimeEnabled)

        // Echo is the one field that defaults the other way. The client this
        // JSON was written by echoed what you typed, so decoding it as "off"
        // would look like an upgrade had thrown the setting away.
        XCTAssertTrue(decoded.echoInput)
    }
}

// Every test in this file, listed because a plain executable has no runtime
// discovery to find them for us. A test missing from here never runs.
// See TestHarness.swift.
extension WorldConfigTests {
    static let suite = TestSuite("WorldConfigTests", [
        ("testCodableRoundTrip", { try WorldConfigTests().testCodableRoundTrip() }),
        ("testLogDirectorySurvivesLoggingBeingOff", { try WorldConfigTests().testLogDirectorySurvivesLoggingBeingOff() }),
        ("testTogglesSurviveTheirNonDefaultValue", { try WorldConfigTests().testTogglesSurviveTheirNonDefaultValue() }),
        ("testDefaults", { WorldConfigTests().testDefaults() }),
        ("testDistinctIDs", { WorldConfigTests().testDistinctIDs() }),
        ("testLenientDecodeOfLegacyJSON", { try WorldConfigTests().testLenientDecodeOfLegacyJSON() }),
    ])
}

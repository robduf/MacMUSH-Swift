import XCTest
@testable import MudEngine

final class AppConfigTests: XCTestCase {

    func testCodableRoundTrip() throws {
        let a = WorldConfig(name: "Alpha", host: "a.example.org", port: 4000)
        let b = WorldConfig(name: "Beta", host: "b.example.org", port: 5000)
        let config = AppConfig(worlds: [a, b], selectedWorldID: b.id)

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertEqual(decoded, config)
        XCTAssertEqual(decoded.worlds.count, 2)
        XCTAssertEqual(decoded.selectedWorldID, b.id)
    }

    func testNormalizeCreatesAWorldWhenEmpty() {
        var config = AppConfig()
        XCTAssertTrue(config.worlds.isEmpty)
        config.normalize()
        XCTAssertEqual(config.worlds.count, 1)
        XCTAssertNotNil(config.selectedWorldID)
        XCTAssertEqual(config.selectedWorld?.id, config.worlds[0].id)
    }

    func testNormalizeRepairsDanglingSelection() {
        let a = WorldConfig(name: "Alpha")
        var config = AppConfig(worlds: [a], selectedWorldID: "does-not-exist")
        config.normalize()
        XCTAssertEqual(config.selectedWorldID, a.id)
        XCTAssertEqual(config.selectedWorld?.name, "Alpha")
    }

    func testSelectedWorldFallsBackToFirst() {
        let a = WorldConfig(name: "Alpha")
        let b = WorldConfig(name: "Beta")
        let config = AppConfig(worlds: [a, b], selectedWorldID: nil)
        XCTAssertEqual(config.selectedWorld?.id, a.id)
        XCTAssertEqual(config.selectedIndex, 0)
    }

    func testUpdateSelectedReplacesInPlace() {
        let a = WorldConfig(name: "Alpha")
        let b = WorldConfig(name: "Beta")
        var config = AppConfig(worlds: [a, b], selectedWorldID: b.id)

        var edited = b
        edited.host = "edited.example.org"
        config.updateSelected(edited)

        XCTAssertEqual(config.worlds.count, 2)
        XCTAssertEqual(config.worlds[1].host, "edited.example.org")
        XCTAssertEqual(config.selectedWorldID, b.id)
    }

    func testUpdateReplacesByIDWithoutTouchingSelection() {
        let a = WorldConfig(name: "Alpha")
        let b = WorldConfig(name: "Beta")
        var config = AppConfig(worlds: [a, b], selectedWorldID: b.id)

        // Edit the world that is *not* selected — the whole point of update(_:).
        var edited = a
        edited.host = "edited.example.org"
        edited.triggers.append(MatchRule(pattern: "* waves", sendText: "wave"))
        XCTAssertTrue(config.update(edited))

        XCTAssertEqual(config.worlds[0].host, "edited.example.org")
        XCTAssertEqual(config.worlds[0].triggers.count, 1)
        XCTAssertEqual(config.worlds[1], b)                 // Beta untouched
        XCTAssertEqual(config.selectedWorldID, b.id)        // selection unmoved
    }

    func testUpdateIgnoresUnknownWorld() {
        let a = WorldConfig(name: "Alpha")
        var config = AppConfig(worlds: [a], selectedWorldID: a.id)

        let stranger = WorldConfig(name: "Ghost")
        XCTAssertFalse(config.update(stranger))
        XCTAssertEqual(config.worlds.count, 1)
        XCTAssertEqual(config.worlds[0], a)
    }

    func testInsertWorldKeepsSelection() {
        let a = WorldConfig(name: "Alpha")
        let b = WorldConfig(name: "Beta")
        var config = AppConfig(worlds: [a, b], selectedWorldID: b.id)

        config.insertWorld(WorldConfig(name: "Gamma"))

        XCTAssertEqual(config.worlds.count, 3)
        XCTAssertEqual(config.worlds[2].name, "Gamma")
        XCTAssertEqual(config.selectedWorldID, b.id)        // still on Beta
    }

    func testAddWorldSelectsIt() {
        let a = WorldConfig(name: "Alpha")
        var config = AppConfig(worlds: [a], selectedWorldID: a.id)
        let c = WorldConfig(name: "Gamma")
        config.addWorld(c)
        XCTAssertEqual(config.worlds.count, 2)
        XCTAssertEqual(config.selectedWorldID, c.id)
        XCTAssertEqual(config.selectedWorld?.name, "Gamma")
    }

    func testRemoveWorldReselects() {
        let a = WorldConfig(name: "Alpha")
        let b = WorldConfig(name: "Beta")
        var config = AppConfig(worlds: [a, b], selectedWorldID: b.id)

        config.removeWorld(id: b.id)
        XCTAssertEqual(config.worlds.count, 1)
        XCTAssertEqual(config.selectedWorldID, a.id)     // reselected survivor

        // Removing the last remaining world normalizes back to one fresh world.
        config.removeWorld(id: a.id)
        XCTAssertEqual(config.worlds.count, 1)
        XCTAssertNotNil(config.selectedWorld)
    }

    func testLenientDecodeOfEmptyObject() throws {
        let empty = "{}".data(using: .utf8)!
        var decoded = try JSONDecoder().decode(AppConfig.self, from: empty)
        XCTAssertTrue(decoded.worlds.isEmpty)
        XCTAssertNil(decoded.selectedWorldID)
        decoded.normalize()
        XCTAssertEqual(decoded.worlds.count, 1)
    }
}

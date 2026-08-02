import Foundation
import MudEngine

final class MatcherTests {

    func testWildcardWithLiteralSpaces() {
        let t = MatchRule(pattern: "* gives you * apples.", sendText: "thank %1")
        let r = Matcher.evaluate([t], line: "Bob gives you 3 shiny apples.")
        XCTAssertEqual(r.matches.count, 1)
        XCTAssertEqual(r.matches[0].wildcards[1], "Bob")
        XCTAssertEqual(r.matches[0].wildcards[2], "3 shiny")
        XCTAssertEqual(r.matches[0].sendText, "thank Bob")
    }

    func testNoMatch() {
        let t = MatchRule(pattern: "A goblin arrives*")
        XCTAssertEqual(Matcher.evaluate([t], line: "A dragon arrives, roaring.").matches.count, 0)
    }

    func testRegexSpecialsInWildcardEscaped() {
        let t = MatchRule(pattern: "You say (to Bob): *")
        let r = Matcher.evaluate([t], line: "You say (to Bob): hello there")
        XCTAssertEqual(r.matches.count, 1)
        XCTAssertEqual(r.matches[0].wildcards[1], "hello there")
    }

    func testRegexTriggerWithGroups() {
        let t = MatchRule(pattern: "^HP: (\\d+)/(\\d+)", isRegex: true)
        let r = Matcher.evaluate([t], line: "HP: 87/100  Mana: 42/50")
        XCTAssertEqual(r.matches.count, 1)
        XCTAssertEqual(r.matches[0].wildcards[1], "87")
        XCTAssertEqual(r.matches[0].wildcards[2], "100")
    }

    func testGagFlag() {
        let t = MatchRule(pattern: "spammy line*", gag: true)
        let r = Matcher.evaluate([t], line: "spammy line of junk")
        XCTAssertEqual(r.matches.count, 1)
        XCTAssertTrue(r.gag)
    }

    func testStopsAtFirstMatchUnlessKeepEvaluating() {
        var a = MatchRule(pattern: "hello*", sendText: "first")
        let b = MatchRule(pattern: "hello*", sendText: "second")
        XCTAssertEqual(Matcher.evaluate([a, b], line: "hello world").matches.count, 1)
        a.keepEvaluating = true
        XCTAssertEqual(Matcher.evaluate([a, b], line: "hello world").matches.count, 2)
    }

    func testDisabledRulesSkipped() {
        let t = MatchRule(pattern: "x*", enabled: false)
        XCTAssertEqual(Matcher.evaluate([t], line: "xyz").matches.count, 0)
    }

    func testCaseSensitivity() {
        let ci = MatchRule(pattern: "GOBLIN*", ignoreCase: true)
        let cs = MatchRule(pattern: "GOBLIN*", ignoreCase: false)
        XCTAssertEqual(Matcher.evaluate([ci], line: "goblin snarls").matches.count, 1)
        XCTAssertEqual(Matcher.evaluate([cs], line: "goblin snarls").matches.count, 0)
    }

    func testAliasWithMultipleWildcards() {
        let alias = MatchRule(pattern: "gt * *", sendText: "give %2 to %1")
        let r = Matcher.evaluate([alias], line: "gt bob sword")
        XCTAssertEqual(r.matches.count, 1)
        XCTAssertEqual(r.matches[0].sendText, "give sword to bob")
    }

    func testExpandWildcardsLiteralPercentAndMissing() {
        // groups: [wholeMatch, firstCapture]
        let out = Matcher.expandWildcards("100%% %1 [%2]", groups: ["one", "one"])
        XCTAssertEqual(out, "100% one []")
    }

    func testBadRegexIsSkippedNotCrashing() {
        let t = MatchRule(pattern: "([bad", isRegex: true)
        XCTAssertEqual(Matcher.evaluate([t], line: "anything").matches.count, 0)
    }

    func testMultilineSendExpansion() {
        let alias = MatchRule(pattern: "prep", sendText: "wield sword\nwear shield\ncast armor")
        let r = Matcher.evaluate([alias], line: "prep")
        XCTAssertEqual(r.matches[0].sendText.split(separator: "\n").count, 3)
    }

    func testWholeMatchWildcardZero() {
        let t = MatchRule(pattern: "say *", sendText: "[%0]")
        let r = Matcher.evaluate([t], line: "say hello world")
        XCTAssertEqual(r.matches[0].sendText, "[say hello world]")
    }

    func testTimerModelDefaults() {
        let tm = MudTimer(name: "keepalive", seconds: 30, sendText: "look")
        XCTAssertEqual(tm.seconds, 30)
        XCTAssertTrue(tm.enabled)
        XCTAssertFalse(tm.oneShot)
    }
}

// Every test in this file, listed because a plain executable has no runtime
// discovery to find them for us. A test missing from here never runs.
// See TestHarness.swift.
extension MatcherTests {
    static let suite = TestSuite("MatcherTests", [
        ("testWildcardWithLiteralSpaces", { MatcherTests().testWildcardWithLiteralSpaces() }),
        ("testNoMatch", { MatcherTests().testNoMatch() }),
        ("testRegexSpecialsInWildcardEscaped", { MatcherTests().testRegexSpecialsInWildcardEscaped() }),
        ("testRegexTriggerWithGroups", { MatcherTests().testRegexTriggerWithGroups() }),
        ("testGagFlag", { MatcherTests().testGagFlag() }),
        ("testStopsAtFirstMatchUnlessKeepEvaluating", { MatcherTests().testStopsAtFirstMatchUnlessKeepEvaluating() }),
        ("testDisabledRulesSkipped", { MatcherTests().testDisabledRulesSkipped() }),
        ("testCaseSensitivity", { MatcherTests().testCaseSensitivity() }),
        ("testAliasWithMultipleWildcards", { MatcherTests().testAliasWithMultipleWildcards() }),
        ("testExpandWildcardsLiteralPercentAndMissing", { MatcherTests().testExpandWildcardsLiteralPercentAndMissing() }),
        ("testBadRegexIsSkippedNotCrashing", { MatcherTests().testBadRegexIsSkippedNotCrashing() }),
        ("testMultilineSendExpansion", { MatcherTests().testMultilineSendExpansion() }),
        ("testWholeMatchWildcardZero", { MatcherTests().testWholeMatchWildcardZero() }),
        ("testTimerModelDefaults", { MatcherTests().testTimerModelDefaults() }),
    ])
}

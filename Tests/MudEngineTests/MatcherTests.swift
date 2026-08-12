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

    // MARK: Highlight

    func testNoHighlightByDefault() {
        let t = MatchRule(pattern: "* pages: *")
        XCTAssertEqual(t.highlight, .plain)
        XCTAssertEqual(Matcher.evaluate([t], line: "Caitlin pages: hello").highlight, .plain)
    }

    func testLineThatMatchesNothingIsNotHighlighted() {
        let t = MatchRule(pattern: "You paged *", highlight: .teal)
        XCTAssertEqual(Matcher.evaluate([t], line: "Caitlin pages: hello").highlight, .plain)
    }

    func testHighlightComesFromTheMatchingRule() {
        let t = MatchRule(pattern: "You paged *", highlight: .teal)
        XCTAssertEqual(Matcher.evaluate([t], line: "You paged Caitlin with 'hi'").highlight, .teal)
    }

    /// Order in the list is priority, so a specific rule placed above a catch-all
    /// keeps its colour. Last-wins would mean a broad `*` rule added at the
    /// bottom of the list silently repainted lines an earlier rule had claimed.
    func testFirstColouredRuleWinsNotLast() {
        let specific = MatchRule(pattern: "You paged *", keepEvaluating: true, highlight: .teal)
        let catchAll = MatchRule(pattern: "*", keepEvaluating: true, highlight: .red)
        let r = Matcher.evaluate([specific, catchAll], line: "You paged Caitlin with 'hi'")

        XCTAssertEqual(r.matches.count, 2)          // both fired
        XCTAssertEqual(r.highlight, .teal)          // the first one's colour stuck
    }

    /// An uncoloured rule matching first must not swallow the colour of a later
    /// one. Plenty of rules exist only to send something, and they sit wherever
    /// they were added — above a colouring rule as often as below it.
    func testUncolouredMatchDoesNotBlockALaterColour() {
        let plain = MatchRule(pattern: "*paged*", sendText: "", keepEvaluating: true)
        let colour = MatchRule(pattern: "You paged *", keepEvaluating: true, highlight: .blue)
        XCTAssertEqual(Matcher.evaluate([plain, colour], line: "You paged Caitlin with 'hi'").highlight,
                       .blue)
    }

    /// A colouring rule below a rule that stops evaluation never gets a look in.
    /// That is the existing `keepEvaluating` contract and colour is not special;
    /// the test is here so it stays deliberate.
    func testColourBelowAStoppingRuleDoesNotApply() {
        let stopper = MatchRule(pattern: "*paged*")            // keepEvaluating: false
        let colour = MatchRule(pattern: "You paged *", highlight: .blue)
        XCTAssertEqual(Matcher.evaluate([stopper, colour], line: "You paged Caitlin with 'hi'").highlight,
                       .plain)
    }

    /// A gagged line is hidden, so its colour is moot — but the two flags are
    /// independent and one must not clear the other.
    func testGagAndHighlightAreIndependent() {
        let t = MatchRule(pattern: "spam*", gag: true, highlight: .red)
        let r = Matcher.evaluate([t], line: "spam spam spam")
        XCTAssertTrue(r.gag)
        XCTAssertEqual(r.highlight, .red)
    }

    // MARK: Rule persistence

    /// The whole reason `MatchRule` spells its `Codable` out by hand. Every rule
    /// in every world file written before `highlight` existed lacks the key, and
    /// the *synthesised* decoder requires every key — a default on the property
    /// is not consulted. Without the lenient decode each of those rules would
    /// throw, and a throw inside `worlds.json` costs the entire file: the
    /// fallback hands back one empty default world and every trigger, alias,
    /// timer and macro is silently gone.
    func testRuleWrittenBeforeHighlightExistedStillDecodes() throws {
        let json = """
        { "id": "abc", "name": "greet", "pattern": "* waves.", "isRegex": false,
          "ignoreCase": true, "enabled": true, "sendText": "wave", "script": "",
          "gag": false, "keepEvaluating": false }
        """.data(using: .utf8)!

        let rule = try JSONDecoder().decode(MatchRule.self, from: json)

        XCTAssertEqual(rule.highlight, .plain)   // the new field defaults
        XCTAssertEqual(rule.id, "abc")           // and nothing else was lost
        XCTAssertEqual(rule.pattern, "* waves.")
        XCTAssertEqual(rule.sendText, "wave")
        XCTAssertTrue(rule.enabled)
    }

    /// Nearly every key absent, not just the new one — a hand-written rule, or
    /// one from a much older build.
    func testSparseRuleDecodesToSensibleDefaults() throws {
        let json = #"{ "pattern": "hello*" }"#.data(using: .utf8)!
        let rule = try JSONDecoder().decode(MatchRule.self, from: json)

        XCTAssertEqual(rule.pattern, "hello*")
        XCTAssertEqual(rule.highlight, .plain)
        XCTAssertTrue(rule.enabled)              // absent means on
        XCTAssertTrue(rule.ignoreCase)           // absent means insensitive
        XCTAssertFalse(rule.isRegex)
        XCTAssertFalse(rule.gag)
        XCTAssertFalse(rule.id.isEmpty)          // a fresh one is minted
    }

    /// Same doctrine as `Macro.color`: an unknown or wrong-typed colour costs the
    /// colour and nothing else, rather than throwing away the rule around it.
    func testUnknownHighlightNameDecodesAsPlainRatherThanThrowing() throws {
        let json = #"{ "pattern": "hi*", "highlight": "chartreuse" }"#.data(using: .utf8)!
        let rule = try JSONDecoder().decode(MatchRule.self, from: json)

        XCTAssertEqual(rule.highlight, .plain)
        XCTAssertEqual(rule.pattern, "hi*")
    }

    func testNonStringHighlightDecodesAsPlainRatherThanThrowing() throws {
        let json = #"{ "pattern": "hi*", "highlight": 4 }"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(MatchRule.self, from: json).highlight, .plain)
    }

    /// Hand-written `encode(to:)` and `init(from:)` are two places to forget a
    /// field. This catches a colour that saves but doesn't load, or vice versa.
    func testRuleRoundTripsThroughJSON() throws {
        let original = MatchRule(id: "r1", name: "pages", pattern: "* pages: *",
                                 isRegex: false, ignoreCase: false, enabled: true,
                                 sendText: "reply", script: "s", gag: true,
                                 keepEvaluating: true, highlight: .purple)

        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(MatchRule.self, from: data), original)
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
        ("testNoHighlightByDefault", { MatcherTests().testNoHighlightByDefault() }),
        ("testLineThatMatchesNothingIsNotHighlighted", { MatcherTests().testLineThatMatchesNothingIsNotHighlighted() }),
        ("testHighlightComesFromTheMatchingRule", { MatcherTests().testHighlightComesFromTheMatchingRule() }),
        ("testFirstColouredRuleWinsNotLast", { MatcherTests().testFirstColouredRuleWinsNotLast() }),
        ("testUncolouredMatchDoesNotBlockALaterColour", { MatcherTests().testUncolouredMatchDoesNotBlockALaterColour() }),
        ("testColourBelowAStoppingRuleDoesNotApply", { MatcherTests().testColourBelowAStoppingRuleDoesNotApply() }),
        ("testGagAndHighlightAreIndependent", { MatcherTests().testGagAndHighlightAreIndependent() }),
        ("testRuleWrittenBeforeHighlightExistedStillDecodes", { try MatcherTests().testRuleWrittenBeforeHighlightExistedStillDecodes() }),
        ("testSparseRuleDecodesToSensibleDefaults", { try MatcherTests().testSparseRuleDecodesToSensibleDefaults() }),
        ("testUnknownHighlightNameDecodesAsPlainRatherThanThrowing", { try MatcherTests().testUnknownHighlightNameDecodesAsPlainRatherThanThrowing() }),
        ("testNonStringHighlightDecodesAsPlainRatherThanThrowing", { try MatcherTests().testNonStringHighlightDecodesAsPlainRatherThanThrowing() }),
        ("testRuleRoundTripsThroughJSON", { try MatcherTests().testRuleRoundTripsThroughJSON() }),
    ])
}

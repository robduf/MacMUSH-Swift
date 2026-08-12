// Entry point for the engine test suite: `swift run MudEngineTests`.
//
// Exits non-zero when anything fails, which is what makes it usable as a CI
// step. See TestHarness.swift for why this is an executable rather than a
// `swift test` target.

import Foundation

let suites: [TestSuite] = [
    AnsiParserTests.suite,
    AppConfigTests.suite,
    MacroTests.suite,
    MatcherTests.suite,
    OutgoingTextTests.suite,
    SessionFormatTests.suite,
    TelnetParserTests.suite,
    WorldConfigTests.suite,
]

exit(runAll(suites) == 0 ? 0 : 1)

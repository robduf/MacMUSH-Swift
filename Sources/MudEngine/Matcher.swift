// Trigger / alias matching engine (MUSHclient-flavoured).
//
// A rule matches an incoming line (trigger) or a typed command (alias). Plain
// patterns use "*" wildcards (each becomes a capture group); set isRegex for a
// full regular expression. On a match, sendText is expanded with %0 (whole
// match) and %1…%9 (wildcards), and/or a named script is invoked by the app.
//
// Foundation only — no AppKit — so it stays portable and fully unit-testable.

import Foundation

/// A trigger or alias rule.
public struct MatchRule: Equatable, Codable, Sendable {
    public var id: String
    public var name: String
    public var pattern: String
    public var isRegex: Bool
    public var ignoreCase: Bool
    public var enabled: Bool
    public var sendText: String
    public var script: String
    public var gag: Bool             // triggers only: hide the matching line
    public var keepEvaluating: Bool  // keep testing later rules after a match

    public init(id: String = UUID().uuidString,
                name: String = "",
                pattern: String,
                isRegex: Bool = false,
                ignoreCase: Bool = true,
                enabled: Bool = true,
                sendText: String = "",
                script: String = "",
                gag: Bool = false,
                keepEvaluating: Bool = false) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.isRegex = isRegex
        self.ignoreCase = ignoreCase
        self.enabled = enabled
        self.sendText = sendText
        self.script = script
        self.gag = gag
        self.keepEvaluating = keepEvaluating
    }
}

/// A timer that fires on an interval while connected.
public struct MudTimer: Equatable, Codable, Sendable {
    public var id: String
    public var name: String
    public var seconds: Double
    public var enabled: Bool
    public var sendText: String
    public var script: String
    public var oneShot: Bool

    public init(id: String = UUID().uuidString,
                name: String = "",
                seconds: Double = 60,
                enabled: Bool = true,
                sendText: String = "",
                script: String = "",
                oneShot: Bool = false) {
        self.id = id
        self.name = name
        self.seconds = seconds
        self.enabled = enabled
        self.sendText = sendText
        self.script = script
        self.oneShot = oneShot
    }
}

/// One rule that fired, with its captured wildcards and expanded send text.
public struct RuleMatch: Equatable, Sendable {
    public let rule: MatchRule
    /// wildcards[0] = whole match, wildcards[1…] = capture groups.
    public let wildcards: [String]
    public let sendText: String
}

/// The result of evaluating a line against a list of rules.
public struct MatchResult: Equatable, Sendable {
    public let matches: [RuleMatch]
    public let gag: Bool
}

public enum Matcher {
    // Compiled regexes are cached by (isRegex|ignoreCase|pattern); NSCache is
    // thread-safe, so evaluate() is safe to call from any queue.
    private static let cache = NSCache<NSString, NSRegularExpression>()

    /// Evaluate a line against rules in order. Stops after the first match
    /// unless that rule has keepEvaluating set.
    public static func evaluate(_ rules: [MatchRule], line: String) -> MatchResult {
        var matches: [RuleMatch] = []
        var gag = false

        for rule in rules {
            guard rule.enabled, !rule.pattern.isEmpty else { continue }
            guard let regex = compile(rule) else { continue }

            let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, options: [], range: fullRange) else { continue }

            var groups: [String] = []
            for i in 0..<match.numberOfRanges {
                if let r = Range(match.range(at: i), in: line) {
                    groups.append(String(line[r]))
                } else {
                    groups.append("")
                }
            }

            matches.append(RuleMatch(
                rule: rule,
                wildcards: groups,
                sendText: expandWildcards(rule.sendText, groups: groups)
            ))
            if rule.gag { gag = true }
            if !rule.keepEvaluating { break }
        }

        return MatchResult(matches: matches, gag: gag)
    }

    /// Expand %0…%9 (and %% -> %) in a template using the captured groups.
    public static func expandWildcards(_ template: String, groups: [String]) -> String {
        guard template.contains("%") else { return template }
        var result = ""
        let chars = Array(template)
        var i = 0
        while i < chars.count {
            if chars[i] == "%", i + 1 < chars.count {
                let next = chars[i + 1]
                if next == "%" {
                    result.append("%")
                    i += 2
                    continue
                }
                if let d = next.wholeNumberValue, (0...9).contains(d) {
                    if d < groups.count { result.append(groups[d]) }
                    i += 2
                    continue
                }
            }
            result.append(chars[i])
            i += 1
        }
        return result
    }

    /// Build (or fetch a cached) NSRegularExpression for a rule. Returns nil for
    /// an invalid regex, so a bad pattern is simply skipped rather than crashing.
    static func compile(_ rule: MatchRule) -> NSRegularExpression? {
        let key = "\(rule.isRegex)|\(rule.ignoreCase)|\(rule.pattern)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let source: String
        if rule.isRegex {
            source = rule.pattern
        } else {
            // Split on "*", escape each literal piece, rejoin with lazy capture
            // groups, and anchor whole-line.
            let parts = rule.pattern.components(separatedBy: "*")
                .map { NSRegularExpression.escapedPattern(for: $0) }
            source = "^" + parts.joined(separator: "(.*?)") + "$"
        }

        let options: NSRegularExpression.Options = rule.ignoreCase ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: source, options: options) else {
            return nil
        }
        cache.setObject(regex, forKey: key)
        return regex
    }
}

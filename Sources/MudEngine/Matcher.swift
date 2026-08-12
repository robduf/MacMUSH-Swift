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
    /// Triggers only: repaint the matching line in this colour. `.plain` leaves
    /// the world's own ANSI colours alone, which is what almost every rule wants.
    public var highlight: SwatchColor

    public init(id: String = UUID().uuidString,
                name: String = "",
                pattern: String,
                isRegex: Bool = false,
                ignoreCase: Bool = true,
                enabled: Bool = true,
                sendText: String = "",
                script: String = "",
                gag: Bool = false,
                keepEvaluating: Bool = false,
                highlight: SwatchColor = .plain) {
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
        self.highlight = highlight
    }

    // Codable is written out rather than synthesised, and decodes leniently, for
    // the reason `WorldConfig` gives at the top of its own file: a field added
    // here later must not make every world file written before it unreadable.
    //
    // That is not a hypothetical. `highlight` is exactly such a field, and the
    // synthesised decoder requires *every* key — a default value on the property
    // is not consulted. Adding it without this would have made each existing rule
    // throw on load, and a throw inside `worlds.json` costs the whole file: the
    // fallback path hands back one empty default world, and every trigger, alias,
    // timer and macro is silently gone.
    private enum CodingKeys: String, CodingKey {
        case id, name, pattern, isRegex, ignoreCase, enabled
        case sendText, script, gag, keepEvaluating, highlight
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.pattern = try c.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        self.isRegex = try c.decodeIfPresent(Bool.self, forKey: .isRegex) ?? false
        self.ignoreCase = try c.decodeIfPresent(Bool.self, forKey: .ignoreCase) ?? true
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.sendText = try c.decodeIfPresent(String.self, forKey: .sendText) ?? ""
        self.script = try c.decodeIfPresent(String.self, forKey: .script) ?? ""
        self.gag = try c.decodeIfPresent(Bool.self, forKey: .gag) ?? false
        self.keepEvaluating = try c.decodeIfPresent(Bool.self, forKey: .keepEvaluating) ?? false
        self.highlight = SwatchColor(lenient: try? c.decode(String.self, forKey: .highlight))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(pattern, forKey: .pattern)
        try c.encode(isRegex, forKey: .isRegex)
        try c.encode(ignoreCase, forKey: .ignoreCase)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(sendText, forKey: .sendText)
        try c.encode(script, forKey: .script)
        try c.encode(gag, forKey: .gag)
        try c.encode(keepEvaluating, forKey: .keepEvaluating)
        try c.encode(highlight, forKey: .highlight)
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
    /// What to repaint the line, from the first rule that matched and asked for a
    /// colour. `.plain` means leave it as the world sent it.
    ///
    /// First rather than last, so the colour follows the same rule everything
    /// else here does: order in the list is priority, and a specific rule put
    /// above a catch-all wins. Last-wins would invert that, and would mean a
    /// broad `*` rule added at the bottom quietly repainted lines that a rule
    /// above it had already claimed.
    public let highlight: SwatchColor
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
        var highlight = SwatchColor.plain

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
            // Only the first colour offered is kept; see `MatchResult.highlight`.
            if highlight == .plain { highlight = rule.highlight }
            if !rule.keepEvaluating { break }
        }

        return MatchResult(matches: matches, gag: gag, highlight: highlight)
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

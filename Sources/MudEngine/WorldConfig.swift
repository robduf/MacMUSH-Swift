// The saved state of a world: connection details plus its triggers, aliases,
// and timers. Codable so it round-trips to a JSON file. Foundation only.
//
// Codable is written out explicitly (rather than synthesised) and decodes
// leniently: any key missing from older JSON falls back to a default. That way
// a world saved by an earlier version — e.g. before `id` existed — still loads.

import Foundation

public struct WorldConfig: Codable, Equatable, Sendable {
    public var id: String                  // stable identity for selection/removal
    public var name: String
    public var host: String
    public var port: UInt16
    public var connectText: String         // commands sent right after connecting
    public var triggers: [MatchRule]
    public var aliases: [MatchRule]
    public var timers: [MudTimer]
    public var logEnabled: Bool            // write a session log while connected
    public var logDirectory: String        // "" means the per-world default folder
    public var chimeEnabled: Bool          // sound when this world talks in the background

    public init(id: String = UUID().uuidString,
                name: String = "My World",
                host: String = "127.0.0.1",
                port: UInt16 = 4000,
                connectText: String = "",
                triggers: [MatchRule] = [],
                aliases: [MatchRule] = [],
                timers: [MudTimer] = [],
                logEnabled: Bool = false,
                logDirectory: String = "",
                chimeEnabled: Bool = false) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.connectText = connectText
        self.triggers = triggers
        self.aliases = aliases
        self.timers = timers
        self.logEnabled = logEnabled
        self.logDirectory = logDirectory
        self.chimeEnabled = chimeEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, connectText, triggers, aliases, timers
        case logEnabled, logDirectory, chimeEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? "My World"
        self.host = try c.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        self.port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 4000
        self.connectText = try c.decodeIfPresent(String.self, forKey: .connectText) ?? ""
        self.triggers = try c.decodeIfPresent([MatchRule].self, forKey: .triggers) ?? []
        self.aliases = try c.decodeIfPresent([MatchRule].self, forKey: .aliases) ?? []
        self.timers = try c.decodeIfPresent([MudTimer].self, forKey: .timers) ?? []
        self.logEnabled = try c.decodeIfPresent(Bool.self, forKey: .logEnabled) ?? false
        self.logDirectory = try c.decodeIfPresent(String.self, forKey: .logDirectory) ?? ""
        // Absent from every world file written before the chime existed, hence
        // `decodeIfPresent` like the rest — off is the right default anyway.
        self.chimeEnabled = try c.decodeIfPresent(Bool.self, forKey: .chimeEnabled) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(connectText, forKey: .connectText)
        try c.encode(triggers, forKey: .triggers)
        try c.encode(aliases, forKey: .aliases)
        try c.encode(timers, forKey: .timers)
        try c.encode(logEnabled, forKey: .logEnabled)
        try c.encode(logDirectory, forKey: .logDirectory)
        try c.encode(chimeEnabled, forKey: .chimeEnabled)
    }
}

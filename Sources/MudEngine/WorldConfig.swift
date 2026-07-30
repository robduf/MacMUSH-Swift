// The saved state of a world: connection details plus its triggers, aliases,
// and timers. Codable so it round-trips to a JSON file. Foundation only.

import Foundation

public struct WorldConfig: Codable, Equatable, Sendable {
    public var name: String
    public var host: String
    public var port: UInt16
    public var connectText: String        // commands sent right after connecting
    public var triggers: [MatchRule]
    public var aliases: [MatchRule]
    public var timers: [MudTimer]

    public init(name: String = "My World",
                host: String = "127.0.0.1",
                port: UInt16 = 4000,
                connectText: String = "",
                triggers: [MatchRule] = [],
                aliases: [MatchRule] = [],
                timers: [MudTimer] = []) {
        self.name = name
        self.host = host
        self.port = port
        self.connectText = connectText
        self.triggers = triggers
        self.aliases = aliases
        self.timers = timers
    }
}

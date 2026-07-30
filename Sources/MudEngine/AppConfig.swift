// The whole persisted app state: the list of saved worlds and which one is
// active. Foundation only, so it stays fully unit-testable.
//
// Like WorldConfig, this decodes leniently so older or partial JSON still
// loads, and it exposes small helpers (selectedWorld / normalize / updateSelected)
// that keep the "there is always exactly one valid selection" invariant.

import Foundation

public struct AppConfig: Codable, Equatable, Sendable {
    public var worlds: [WorldConfig]
    public var selectedWorldID: String?

    public init(worlds: [WorldConfig] = [], selectedWorldID: String? = nil) {
        self.worlds = worlds
        self.selectedWorldID = selectedWorldID
    }

    private enum CodingKeys: String, CodingKey {
        case worlds, selectedWorldID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.worlds = try c.decodeIfPresent([WorldConfig].self, forKey: .worlds) ?? []
        self.selectedWorldID = try c.decodeIfPresent(String.self, forKey: .selectedWorldID)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(worlds, forKey: .worlds)
        try c.encodeIfPresent(selectedWorldID, forKey: .selectedWorldID)
    }

    /// The active world: the selected one, else the first. Nil only when the
    /// list is empty (call `normalize()` first to guarantee non-nil).
    public var selectedWorld: WorldConfig? {
        if let id = selectedWorldID, let w = worlds.first(where: { $0.id == id }) {
            return w
        }
        return worlds.first
    }

    /// Index of the active world in `worlds`, if any.
    public var selectedIndex: Int? {
        if let id = selectedWorldID, let i = worlds.firstIndex(where: { $0.id == id }) {
            return i
        }
        return worlds.isEmpty ? nil : 0
    }

    /// Guarantee at least one world and a valid selection pointing at a real world.
    public mutating func normalize() {
        if worlds.isEmpty {
            let world = WorldConfig()
            worlds = [world]
            selectedWorldID = world.id
        } else if selectedWorldID == nil || !worlds.contains(where: { $0.id == selectedWorldID }) {
            selectedWorldID = worlds[0].id
        }
    }

    /// Replace the active world with an edited copy (matched by the current
    /// selection), keeping it selected.
    public mutating func updateSelected(_ world: WorldConfig) {
        if let i = selectedIndex {
            worlds[i] = world
            selectedWorldID = world.id
        } else {
            worlds.append(world)
            selectedWorldID = world.id
        }
    }

    /// Add a world and make it active. Returns its id.
    @discardableResult
    public mutating func addWorld(_ world: WorldConfig) -> String {
        worlds.append(world)
        selectedWorldID = world.id
        return world.id
    }

    /// Remove the world with the given id, then re-establish a valid selection.
    public mutating func removeWorld(id: String) {
        worlds.removeAll { $0.id == id }
        if selectedWorldID == id { selectedWorldID = nil }
        normalize()
    }
}

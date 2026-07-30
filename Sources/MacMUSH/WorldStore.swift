#if canImport(AppKit)
import Foundation
import MudEngine

extension Notification.Name {
    /// Posted whenever the saved worlds or the active selection change, so open
    /// windows and the menu can refresh themselves.
    static let worldStoreDidChange = Notification.Name("MacMUSH.worldStoreDidChange")
}

/// The single runtime source of truth for saved worlds. Owns the AppConfig,
/// persists every change through Storage, and posts `.worldStoreDidChange`.
final class WorldStore {
    static let shared = WorldStore()

    private(set) var config: AppConfig

    private init() {
        var app = Storage.loadApp()
        app.normalize()
        config = app
    }

    // MARK: Reads

    var worlds: [WorldConfig] { config.worlds }

    /// The active world; always valid because config is kept normalized.
    var selectedWorld: WorldConfig {
        config.selectedWorld ?? WorldConfig()
    }

    var selectedWorldID: String? { config.selectedWorldID }

    // MARK: Mutations (each persists + notifies)

    /// Replace the entire config (used by the settings window's Save).
    func replace(_ newConfig: AppConfig) {
        var c = newConfig
        c.normalize()
        commit(c)
    }

    /// Persist edits to the active world (used by the live window's slash commands).
    func updateSelectedWorld(_ world: WorldConfig) {
        var c = config
        c.updateSelected(world)
        commit(c)
    }

    /// Switch which world is active.
    func select(id: String) {
        guard id != config.selectedWorldID else { return }
        var c = config
        c.selectedWorldID = id
        c.normalize()
        commit(c)
    }

    /// Add a world and make it active. Returns the stored world.
    @discardableResult
    func addWorld(_ world: WorldConfig) -> WorldConfig {
        var c = config
        c.addWorld(world)
        commit(c)
        return world
    }

    /// Rename the active world.
    func renameSelected(to name: String) {
        var world = selectedWorld
        world.name = name
        updateSelectedWorld(world)
    }

    /// Remove a world and re-establish a valid selection.
    func removeWorld(id: String) {
        var c = config
        c.removeWorld(id: id)
        commit(c)
    }

    private func commit(_ c: AppConfig) {
        config = c
        Storage.saveApp(c)
        NotificationCenter.default.post(name: .worldStoreDidChange, object: self)
    }
}
#endif

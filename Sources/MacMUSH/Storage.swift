#if canImport(AppKit)
import Foundation
import MudEngine

/// Loads and saves the app config (all worlds + selection) as JSON under
/// Application Support/MacMUSH. Migrates a single legacy `world.json` — written
/// by the pre-multi-world version — into the new `worlds.json` on first load.
enum Storage {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("MacMUSH", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var appFile: URL {
        directory.appendingPathComponent("worlds.json")
    }

    static var legacyWorldFile: URL {
        directory.appendingPathComponent("world.json")
    }

    /// Load the full app config. Order: new worlds.json, then a one-time
    /// migration of a legacy single world.json, then a fresh default. The
    /// result is always normalized (at least one world, a valid selection).
    static func loadApp() -> AppConfig {
        if let data = try? Data(contentsOf: appFile),
           var app = try? JSONDecoder().decode(AppConfig.self, from: data) {
            app.normalize()
            return app
        }

        if let data = try? Data(contentsOf: legacyWorldFile),
           let world = try? JSONDecoder().decode(WorldConfig.self, from: data) {
            var app = AppConfig(worlds: [world], selectedWorldID: world.id)
            app.normalize()
            saveApp(app)                 // write the new format immediately
            return app
        }

        var app = AppConfig()
        app.normalize()
        return app
    }

    static func saveApp(_ app: AppConfig) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(app) else { return }
        // Atomic: the settings window saves on every field edit and checkbox
        // toggle, so a crash or force-quit mid-write is no longer a rare event.
        // A truncated worlds.json fails to decode on launch and the fallback
        // path would hand back one empty default world — every trigger, alias
        // and timer gone, silently.
        try? data.write(to: appFile, options: .atomic)
    }
}
#endif

#if canImport(AppKit)
import Foundation
import MudEngine

/// Loads and saves the world config as JSON under Application Support/MacMUSH.
enum Storage {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("MacMUSH", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var worldFile: URL {
        directory.appendingPathComponent("world.json")
    }

    static func loadWorld() -> WorldConfig {
        guard let data = try? Data(contentsOf: worldFile),
              let config = try? JSONDecoder().decode(WorldConfig.self, from: data) else {
            return WorldConfig()
        }
        return config
    }

    static func saveWorld(_ config: WorldConfig) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: worldFile)
    }
}
#endif

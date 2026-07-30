#if canImport(AppKit)
import Foundation
import MudEngine

/// Writes one plain-text file per connected session: exactly the lines that
/// appeared in the window, with the ANSI colour codes already stripped out by
/// the parser upstream.
///
/// Nothing here throws at the caller. A logger that fails mid-session closes
/// itself and hands back a message to show — a failed `FileHandle` fails for
/// every subsequent line too, so quietly dropping the rest of the evening's log
/// would be far worse than one visible warning.
final class SessionLogger {
    private var handle: FileHandle?
    private var startedAt: Date?

    /// The file currently open, or the last one written. Kept after `stop()` so
    /// the window can tell the user where the log went.
    private(set) var fileURL: URL?

    var isActive: Bool { handle != nil }

    /// Where a world's logs go when it hasn't been given a folder of its own.
    static func defaultDirectory(worldName: String) -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return documents
            .appendingPathComponent("MacMUSH Logs", isDirectory: true)
            .appendingPathComponent(SessionFormat.sanitizeFileName(worldName), isDirectory: true)
    }

    static func resolveDirectory(_ configured: String, worldName: String) -> URL {
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultDirectory(worldName: worldName) }

        let expanded = (trimmed as NSString).expandingTildeInPath
        // A double-clicked .app runs with "/" as its working directory, so a
        // relative path would aim at the root of the disk. Read it from home,
        // which is what someone typing "Documents/Logs" means.
        let absolute = expanded.hasPrefix("/")
            ? expanded
            : (NSHomeDirectory() as NSString).appendingPathComponent(expanded)
        return URL(fileURLWithPath: absolute, isDirectory: true)
    }

    /// Open a fresh log file. Returns nil on success, or a message to show the
    /// user explaining why logging did not start.
    @discardableResult
    func start(worldName: String, host: String, port: UInt16,
               directory: String, now: Date = Date()) -> String? {
        let folder = SessionLogger.resolveDirectory(directory, worldName: worldName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return "Logging off — can't use \(folder.path): \(error.localizedDescription)"
        }

        let url = folder.appendingPathComponent(
            SessionFormat.logFileName(worldName: worldName, date: now))

        let created = !FileManager.default.fileExists(atPath: url.path)
        if created, !FileManager.default.createFile(atPath: url.path, contents: nil) {
            return "Logging off — can't create \(url.lastPathComponent) in \(folder.path)."
        }
        guard let opened = try? FileHandle(forWritingTo: url) else {
            // Created it and then couldn't open it — a permissions or ACL quirk.
            // Take the empty file back out rather than leaving a litter of
            // zero-byte logs behind every failed attempt.
            if created { try? FileManager.default.removeItem(at: url) }
            return "Logging off — can't open \(url.lastPathComponent) for writing."
        }

        // Only now that the replacement is definitely open is it safe to close
        // what's already running. Pointing a live session at an unwritable
        // folder must fail without ending the log you were happily keeping.
        stop(now: now)

        // Append rather than overwrite: two sessions started inside the same
        // second would otherwise land on the same name and the second would
        // erase the first. Seeking after the `stop` above also puts us past the
        // footer it just wrote, in the case where both are the same file.
        _ = try? opened.seekToEnd()

        handle = opened
        fileURL = url
        startedAt = now
        return append(SessionFormat.logHeader(worldName: worldName, host: host,
                                              port: port, date: now))
    }

    /// Append one line. Returns a message if the write failed and logging
    /// stopped as a result; nil when all is well or logging is already off.
    @discardableResult
    func write(_ line: String) -> String? {
        guard handle != nil else { return nil }
        return append(line)
    }

    func stop(now: Date = Date()) {
        guard let open = handle else { return }
        if let started = startedAt {
            let footer = SessionFormat.logFooter(date: now,
                                                 elapsed: now.timeIntervalSince(started))
            if let data = (footer + "\n").data(using: .utf8) {
                try? open.write(contentsOf: data)
            }
        }
        try? open.close()
        handle = nil
        startedAt = nil
    }

    // MARK: Writing

    private func append(_ line: String) -> String? {
        guard let open = handle else { return nil }

        // Normalise the line ending so the file gets exactly one "\n" per line,
        // whatever mix of CR and LF the MUD sent.
        var text = line
        while text.hasSuffix("\n") || text.hasSuffix("\r") { text.removeLast() }
        guard let data = (text + "\n").data(using: .utf8) else { return nil }

        do {
            try open.write(contentsOf: data)
            return nil
        } catch {
            // Disk full, or the volume the log lives on was unplugged.
            let name = fileURL?.lastPathComponent ?? "the log file"
            try? open.close()
            handle = nil
            startedAt = nil
            return "Logging stopped — couldn't write to \(name): \(error.localizedDescription)"
        }
    }
}
#endif

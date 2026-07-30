// Small pure helpers shared by the session log and the status bar: elapsed-time
// formatting, log file naming, and the header/footer written around a session.
//
// These live in MudEngine — Foundation only, no AppKit — so they can be unit
// tested without a window on screen.

import Foundation

public enum SessionFormat {

    // MARK: Elapsed time

    /// "01:23:45". Hours deliberately don't wrap: a marathon 30-hour connection
    /// reads "30:00:00" rather than resetting to "06:00:00" and looking fresh.
    public static func elapsed(_ interval: TimeInterval) -> String {
        // A non-finite interval would trap on the Int conversion below. That
        // can't happen from Date arithmetic today, but the status bar updates
        // once a second forever and a crash there is a crash of the whole app.
        guard interval.isFinite, interval > 0 else { return "00:00:00" }
        // The ceiling is only there so nonsense can't overflow the conversion.
        // It sits a year out on purpose: a real four-day session has to read as
        // four days, not as a clamped placeholder frozen in the log footer.
        let total = Int(min(interval, 31_536_000))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    // MARK: Log naming

    /// Make a world name safe to use as a file name. This is a security boundary
    /// as much as a cosmetic one: a world called "../../.ssh/config" must not be
    /// able to steer a write outside the folder the user chose.
    public static func sanitizeFileName(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = name
            .components(separatedBy: illegal)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // "." and ".." are directory references, not names, and a name made
        // only of separators comes out of the join above as bare dashes. Trim
        // both off each end and the fallback below catches what's left.
        let stripped = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        guard !stripped.isEmpty else { return "world" }

        // Bound the bytes, not the characters: sixty emoji are 240 UTF-8 bytes,
        // and the timestamp and extension still have to fit inside the file
        // system's 255-byte limit or logging simply never starts.
        var bounded = stripped
        while bounded.utf8.count > 60 { bounded.removeLast() }
        return bounded.isEmpty ? "world" : bounded
    }

    /// "Shang-2026-07-30-172335.log" — sorts chronologically in Finder, and one
    /// file per session means a crash can never cost you an earlier session.
    public static func logFileName(worldName: String, date: Date) -> String {
        "\(sanitizeFileName(worldName))-\(stamp(date, format: "yyyy-MM-dd-HHmmss")).log"
    }

    public static func logHeader(worldName: String, host: String, port: UInt16, date: Date) -> String {
        "==== \(worldName) — \(host):\(port) — connected \(stamp(date, format: "yyyy-MM-dd HH:mm:ss")) ===="
    }

    public static func logFooter(date: Date, elapsed interval: TimeInterval) -> String {
        "==== disconnected \(stamp(date, format: "yyyy-MM-dd HH:mm:ss")) — connected for \(elapsed(interval)) ===="
    }

    // MARK: Passwords

    /// Mask the password in a login line before it is echoed to the screen or
    /// written to a log file.
    ///
    /// MUSH and MUD logins carry the password inline — `connect Rob hunter2` —
    /// so without this the very first thing every session writes to a plain
    /// text file on disk is a working password. Telnet's ECHO negotiation only
    /// covers servers that ask for the password on a line of its own; most
    /// don't ask that way.
    ///
    /// Deliberately over-eager. Masking one token too many costs a little log
    /// fidelity; missing one costs the password.
    public static func redactLogin(_ line: String) -> String {
        // Split on tabs as well as spaces. A pasted line can easily be tab
        // separated, and treating "connect\tRob\thunter2" as a single token
        // would hand the whole thing back unmasked.
        var tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let command = tokens.first?.lowercased() else { return line }

        let keep: Int
        if loginCommands.contains(command) {
            keep = 2                // the command and the character name
        } else if passwordCommands.contains(command) {
            keep = 1                // everything after the command is a secret
        } else {
            return line
        }

        guard tokens.count > keep else { return line }      // no password on this line
        for i in keep..<tokens.count { tokens[i] = "********" }
        return tokens.joined(separator: " ")
    }

    /// `redactLogin` applied to each line of a multi-line block — an alias body
    /// or a world's auto-connect text, which are shown back to the user and so
    /// reach the same scrollback and the same log file.
    public static func redactBlock(_ text: String) -> String {
        text.components(separatedBy: "\n").map(redactLogin).joined(separator: "\n")
    }

    /// `connect <name> <password>` and its usual abbreviations, including
    /// TinyMUX's connect-dark and connect-hidden forms.
    private static let loginCommands: Set<String> = [
        "connect", "conn", "co", "cd", "cc", "ch", "create",
    ]

    /// Commands where the very next token is already secret.
    private static let passwordCommands: Set<String> = [
        "password", "@password", "newpassword", "@newpassword", "pcreate", "@pcreate",
    ]

    // MARK: Helpers

    /// Fixed-format, POSIX locale: log file names must not change shape because
    /// the user's Mac is set to a Japanese calendar or a 12-hour clock.
    private static func stamp(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

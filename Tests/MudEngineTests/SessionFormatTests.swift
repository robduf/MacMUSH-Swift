import XCTest
@testable import MudEngine

final class SessionFormatTests: XCTestCase {

    // MARK: Elapsed time

    func testElapsedFormatting() {
        XCTAssertEqual(SessionFormat.elapsed(0), "00:00:00")
        XCTAssertEqual(SessionFormat.elapsed(1), "00:00:01")
        XCTAssertEqual(SessionFormat.elapsed(59), "00:00:59")
        XCTAssertEqual(SessionFormat.elapsed(60), "00:01:00")
        XCTAssertEqual(SessionFormat.elapsed(3599), "00:59:59")
        XCTAssertEqual(SessionFormat.elapsed(3600), "01:00:00")
        XCTAssertEqual(SessionFormat.elapsed(5025), "01:23:45")
    }

    /// Fractions of a second are floor-ed, not rounded: the clock must never
    /// read 00:00:01 before a full second has passed.
    func testElapsedTruncatesFractions() {
        XCTAssertEqual(SessionFormat.elapsed(0.9), "00:00:00")
        XCTAssertEqual(SessionFormat.elapsed(1.99), "00:00:01")
    }

    /// Hours accumulate rather than wrapping at 24 — a two-day connection should
    /// look like a two-day connection.
    func testElapsedDoesNotWrapAtADay() {
        XCTAssertEqual(SessionFormat.elapsed(86_400), "24:00:00")
        XCTAssertEqual(SessionFormat.elapsed(108_000), "30:00:00")
    }

    /// The status bar ticks once a second forever, so nothing here may trap.
    /// `Int(.infinity)` and `Int(.nan)` are both crashes, not warnings.
    func testElapsedSurvivesNonsenseInput() {
        XCTAssertEqual(SessionFormat.elapsed(-5), "00:00:00")
        XCTAssertEqual(SessionFormat.elapsed(.nan), "00:00:00")
        XCTAssertEqual(SessionFormat.elapsed(.infinity), "00:00:00")
        XCTAssertEqual(SessionFormat.elapsed(1e18), "8760:00:00")     // capped at a year
    }

    /// The log footer records the length of the session. A long weekend has to
    /// come out as a long weekend, not as a clamped placeholder — that number
    /// is the whole reason the footer is there.
    func testElapsedDoesNotClampARealisticallyLongSession() {
        XCTAssertEqual(SessionFormat.elapsed(432_000), "120:00:00")   // five days
        XCTAssertTrue(SessionFormat.logFooter(date: fixedDate, elapsed: 432_000)
            .contains("120:00:00"))
    }

    // MARK: File-name safety

    func testSanitizeLeavesOrdinaryNamesAlone() {
        XCTAssertEqual(SessionFormat.sanitizeFileName("Shang"), "Shang")
        XCTAssertEqual(SessionFormat.sanitizeFileName("Two Moons MUSH"), "Two Moons MUSH")
    }

    /// A world name is user text, and it ends up in a path. Separators must not
    /// survive into the file name or the write escapes the chosen folder.
    func testSanitizeStripsPathSeparators() {
        XCTAssertFalse(SessionFormat.sanitizeFileName("../../.ssh/config").contains("/"))
        XCTAssertFalse(SessionFormat.sanitizeFileName("a/b\\c:d").contains("/"))
        XCTAssertFalse(SessionFormat.sanitizeFileName("a/b\\c:d").contains("\\"))
        XCTAssertFalse(SessionFormat.sanitizeFileName("a/b\\c:d").contains(":"))
    }

    func testSanitizeRejectsDirectoryReferences() {
        XCTAssertEqual(SessionFormat.sanitizeFileName("."), "world")
        XCTAssertEqual(SessionFormat.sanitizeFileName(".."), "world")
        XCTAssertEqual(SessionFormat.sanitizeFileName("/"), "world")
        XCTAssertEqual(SessionFormat.sanitizeFileName(""), "world")
        XCTAssertEqual(SessionFormat.sanitizeFileName("   "), "world")
    }

    func testSanitizeStripsControlCharacters() {
        let sanitized = SessionFormat.sanitizeFileName("Sha\u{0}ng\n")
        XCTAssertFalse(sanitized.contains("\u{0}"))
        XCTAssertFalse(sanitized.contains("\n"))
    }

    /// Long enough to stay under any file-system name limit, with room left for
    /// the timestamp and extension the log name appends.
    func testSanitizeBoundsLength() {
        let long = String(repeating: "x", count: 500)
        XCTAssertEqual(SessionFormat.sanitizeFileName(long).count, 60)
    }

    /// APFS counts bytes, not characters. Sixty emoji are 240 UTF-8 bytes, and
    /// with the timestamp on the end that busts the 255-byte name limit — the
    /// open fails and the whole session goes unlogged.
    func testSanitizeBoundsBytesNotCharacters() {
        let emoji = String(repeating: "🐉", count: 200)
        let sanitized = SessionFormat.sanitizeFileName(emoji)
        XCTAssertLessThanOrEqual(sanitized.utf8.count, 60)
        XCTAssertFalse(sanitized.isEmpty)
        XCTAssertLessThan(SessionFormat.logFileName(worldName: emoji, date: fixedDate).utf8.count, 255)
    }

    // MARK: Passwords

    /// The whole point of the log is that it survives on disk, which is exactly
    /// why the login line must not.
    func testRedactLoginHidesThePassword() {
        XCTAssertEqual(SessionFormat.redactLogin("connect Rob hunter2"), "connect Rob ********")
        XCTAssertEqual(SessionFormat.redactLogin("Connect Rob hunter2"), "Connect Rob ********")
        XCTAssertEqual(SessionFormat.redactLogin("cd Rob hunter2"), "cd Rob ********")
        XCTAssertEqual(SessionFormat.redactLogin("create Rob hunter2"), "create Rob ********")
        XCTAssertEqual(SessionFormat.redactLogin("@password old new"), "@password ******** ********")
        XCTAssertEqual(SessionFormat.redactLogin("@pcreate Rob=hunter2"), "@pcreate ********")
    }

    /// A quoted multi-word character name splits into more tokens than there
    /// are fields. Masking too much is the right way to be wrong.
    func testRedactLoginErrsTowardsMasking() {
        let masked = SessionFormat.redactLogin("connect \"Two Words\" hunter2")
        XCTAssertFalse(masked.contains("hunter2"))
    }

    /// A pasted login is as likely to be tab separated as space separated, and
    /// splitting on spaces alone would see one token and wave the whole line
    /// through untouched.
    func testRedactLoginHandlesTabs() {
        XCTAssertFalse(SessionFormat.redactLogin("connect\tRob\thunter2").contains("hunter2"))
        XCTAssertFalse(SessionFormat.redactLogin("  connect Rob hunter2").contains("hunter2"))
        XCTAssertFalse(SessionFormat.redactLogin("co Rob hunter2").contains("hunter2"))
    }

    /// An alias body is echoed back when you define it and again when you list
    /// it, so `/alias in=connect Rob hunter2` has to be masked on both trips.
    func testRedactBlockCoversEveryLine() {
        let block = "look\nconnect Rob hunter2\nsay hi"
        let masked = SessionFormat.redactBlock(block)
        XCTAssertFalse(masked.contains("hunter2"))
        XCTAssertTrue(masked.contains("look"))
        XCTAssertTrue(masked.contains("say hi"))
        XCTAssertEqual(masked.components(separatedBy: "\n").count, 3)
    }

    func testRedactLoginLeavesOrdinaryLinesAlone() {
        XCTAssertEqual(SessionFormat.redactLogin("look"), "look")
        XCTAssertEqual(SessionFormat.redactLogin("say hello there"), "say hello there")
        XCTAssertEqual(SessionFormat.redactLogin("connecting to the hub"), "connecting to the hub")
        XCTAssertEqual(SessionFormat.redactLogin(""), "")
        // No password on the line yet — the server will prompt for it, and the
        // telnet ECHO path covers that.
        XCTAssertEqual(SessionFormat.redactLogin("connect Rob"), "connect Rob")
    }

    // MARK: Log naming

    func testLogFileNameIsSortableAndStable() {
        let name = SessionFormat.logFileName(worldName: "Shang", date: fixedDate)
        XCTAssertEqual(name, "Shang-2026-07-30-172335.log")
    }

    /// The name must not change shape because the Mac is set to a 12-hour clock
    /// or a non-Gregorian calendar — hence the POSIX locale inside.
    func testLogFileNameIgnoresSystemLocale() {
        let name = SessionFormat.logFileName(worldName: "../etc/passwd", date: fixedDate)
        XCTAssertFalse(name.contains("/"))
        XCTAssertTrue(name.hasSuffix("-2026-07-30-172335.log"))
    }

    func testHeaderAndFooterCarryTheDetailsYouWantMonthsLater() {
        let header = SessionFormat.logHeader(worldName: "Shang", host: "mud.example.org",
                                             port: 4201, date: fixedDate)
        XCTAssertTrue(header.contains("Shang"))
        XCTAssertTrue(header.contains("mud.example.org:4201"))
        XCTAssertTrue(header.contains("2026-07-30 17:23:35"))

        let footer = SessionFormat.logFooter(date: fixedDate, elapsed: 5025)
        XCTAssertTrue(footer.contains("2026-07-30 17:23:35"))
        XCTAssertTrue(footer.contains("01:23:45"))
    }

    // MARK: Helpers

    /// The instant that reads as 2026-07-30 17:23:35 on *this* machine.
    ///
    /// `SessionFormat` stamps in the current time zone, so the date is built in
    /// the current time zone too. That keeps the expected strings above correct
    /// whether CI runs in UTC and Rob's Mac runs in US/Eastern — without any
    /// test mutating `NSTimeZone.default` out from under the rest of the suite.
    private var fixedDate: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 30
        components.hour = 17
        components.minute = 23
        components.second = 35
        let calendar = Calendar(identifier: .gregorian)
        return calendar.date(from: components)!
    }
}

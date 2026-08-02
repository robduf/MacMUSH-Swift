// A small stand-in for XCTest.
//
// XCTest.framework ships inside Xcode.app. A Mac with only the Command Line
// Tools installed has a perfectly good Swift compiler but no XCTest at all, so
// `swift test` fails at `import XCTest` before it ever reaches a test body.
// This target sidesteps that by being an ordinary executable: `swift run
// MudEngineTests`. It needs nothing beyond the compiler, and it behaves the
// same way in CI as it does on a laptop.
//
// The assertion names below are deliberately the XCTest ones. Test bodies then
// read exactly as they would under XCTest, and the whole suite could move back
// to it by changing six import lines and deleting six `suite` blocks.
//
// The one thing that can't be reproduced is discovery. XCTest finds test
// methods through the Objective-C runtime; a plain executable has no such
// facility, so each test file lists its own methods in a `suite` at the bottom.
// That list is the price of the arrangement — a new test that isn't added to it
// silently never runs.

import Foundation

// MARK: - Recording

/// One failed assertion, with the source location that produced it.
struct Failure {
    let test: String
    let detail: String
    let file: String
    let line: UInt
}

/// Collects failures for the duration of a run.
///
/// Global mutable state is normally worth avoiding, but it's what lets the
/// assertions be free functions that read like XCTest's. Tests run one at a
/// time on a single thread, so there's nothing here to race.
enum Report {
    static var failures: [Failure] = []

    /// Labels any failure recorded while it's set.
    static var currentTest = "<none>"

    static func record(_ detail: String,
                       _ message: String,
                       _ file: StaticString,
                       _ line: UInt) {
        failures.append(Failure(
            test: currentTest,
            detail: message.isEmpty ? detail : "\(detail) — \(message)",
            file: URL(fileURLWithPath: "\(file)").lastPathComponent,
            line: line))
    }
}

/// Renders a value the way a failure message wants it: quoted strings, visible
/// `Optional(...)` wrappers. Plain interpolation prints `red` and `Optional(…)`
/// identically to a bare value, which hides exactly the differences a failing
/// assertion is trying to show you.
private func show<T>(_ value: T) -> String {
    String(reflecting: value)
}

// MARK: - Assertions

func XCTAssertEqual<T: Equatable>(_ actual: @autoclosure () throws -> T,
                                  _ expected: @autoclosure () throws -> T,
                                  _ message: @autoclosure () -> String = "",
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
    do {
        let a = try actual(), e = try expected()
        if a != e {
            Report.record("expected \(show(e)), got \(show(a))", message(), file, line)
        }
    } catch {
        Report.record("threw \(error)", message(), file, line)
    }
}

func XCTAssertNotEqual<T: Equatable>(_ actual: @autoclosure () throws -> T,
                                     _ unexpected: @autoclosure () throws -> T,
                                     _ message: @autoclosure () -> String = "",
                                     file: StaticString = #filePath,
                                     line: UInt = #line) {
    do {
        let a = try actual(), u = try unexpected()
        if a == u {
            Report.record("expected anything but \(show(u))", message(), file, line)
        }
    } catch {
        Report.record("threw \(error)", message(), file, line)
    }
}

func XCTAssertTrue(_ expression: @autoclosure () throws -> Bool,
                   _ message: @autoclosure () -> String = "",
                   file: StaticString = #filePath,
                   line: UInt = #line) {
    do {
        if try !expression() {
            Report.record("expected true, got false", message(), file, line)
        }
    } catch {
        Report.record("threw \(error)", message(), file, line)
    }
}

func XCTAssertFalse(_ expression: @autoclosure () throws -> Bool,
                    _ message: @autoclosure () -> String = "",
                    file: StaticString = #filePath,
                    line: UInt = #line) {
    do {
        if try expression() {
            Report.record("expected false, got true", message(), file, line)
        }
    } catch {
        Report.record("threw \(error)", message(), file, line)
    }
}

func XCTAssertNil(_ expression: @autoclosure () throws -> Any?,
                  _ message: @autoclosure () -> String = "",
                  file: StaticString = #filePath,
                  line: UInt = #line) {
    do {
        if let value = try expression() {
            Report.record("expected nil, got \(show(value))", message(), file, line)
        }
    } catch {
        Report.record("threw \(error)", message(), file, line)
    }
}

func XCTAssertNotNil(_ expression: @autoclosure () throws -> Any?,
                     _ message: @autoclosure () -> String = "",
                     file: StaticString = #filePath,
                     line: UInt = #line) {
    do {
        if try expression() == nil {
            Report.record("expected a value, got nil", message(), file, line)
        }
    } catch {
        Report.record("threw \(error)", message(), file, line)
    }
}

func XCTAssertLessThan<T: Comparable>(_ lhs: @autoclosure () throws -> T,
                                      _ rhs: @autoclosure () throws -> T,
                                      _ message: @autoclosure () -> String = "",
                                      file: StaticString = #filePath,
                                      line: UInt = #line) {
    do {
        let a = try lhs(), b = try rhs()
        if !(a < b) {
            Report.record("expected \(show(a)) < \(show(b))", message(), file, line)
        }
    } catch {
        Report.record("threw \(error)", message(), file, line)
    }
}

func XCTAssertLessThanOrEqual<T: Comparable>(_ lhs: @autoclosure () throws -> T,
                                             _ rhs: @autoclosure () throws -> T,
                                             _ message: @autoclosure () -> String = "",
                                             file: StaticString = #filePath,
                                             line: UInt = #line) {
    do {
        let a = try lhs(), b = try rhs()
        if !(a <= b) {
            Report.record("expected \(show(a)) <= \(show(b))", message(), file, line)
        }
    } catch {
        Report.record("threw \(error)", message(), file, line)
    }
}

func XCTFail(_ message: @autoclosure () -> String = "",
             file: StaticString = #filePath,
             line: UInt = #line) {
    Report.record("unconditional failure", message(), file, line)
}

// MARK: - Suites

/// A named group of tests, one per test file.
///
/// Each entry pairs a method name with a closure that makes a fresh instance
/// and calls it — fresh because XCTest gives every test method its own
/// instance, and tests written against that promise shouldn't quietly start
/// sharing state.
struct TestSuite {
    let name: String
    let tests: [(String, () throws -> Void)]

    init(_ name: String, _ tests: [(String, () throws -> Void)]) {
        self.name = name
        self.tests = tests
    }
}

/// Left-pads for column alignment without truncating, which `padding(toLength:)`
/// would do to any name longer than the width.
private func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

/// Runs every suite and returns the number of failed tests.
func runAll(_ suites: [TestSuite]) -> Int {
    let started = Date()
    var passed = 0
    var failed = 0

    print("MudEngine tests\n")

    for suite in suites {
        var suitePassed = 0

        for (name, body) in suite.tests {
            Report.currentTest = "\(suite.name).\(name)"
            let before = Report.failures.count

            do {
                try body()
            } catch {
                // A throwing test that actually threw. There's no source
                // location for this the way there is for an assertion, so the
                // failure carries the test name alone.
                Report.failures.append(Failure(test: Report.currentTest,
                                               detail: "threw \(error)",
                                               file: "",
                                               line: 0))
            }

            if Report.failures.count == before {
                passed += 1
                suitePassed += 1
            } else {
                failed += 1
            }
        }

        let total = suite.tests.count
        let mark = suitePassed == total ? "ok  " : "FAIL"
        print("  \(mark)  \(pad(suite.name, 22)) \(suitePassed)/\(total)")
    }

    if !Report.failures.isEmpty {
        print("")
        for failure in Report.failures {
            let site = failure.file.isEmpty ? "" : "  (\(failure.file):\(failure.line))"
            print("FAIL  \(failure.test)\(site)")
            print("      \(failure.detail)")
        }
    }

    let elapsed = String(format: "%.2fs", Date().timeIntervalSince(started))
    print("")
    print("\(passed + failed) tests, \(passed) passed, \(failed) failed  (\(elapsed))")

    return failed
}

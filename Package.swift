// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacMUSH",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // Pure-logic engine: telnet + ANSI parsing. Foundation only, no AppKit,
        // so it's fully unit-testable and portable.
        .target(
            name: "MudEngine"
        ),
        // The macOS app (AppKit + Network.framework). Code-only, no storyboards.
        .executableTarget(
            name: "MacMUSH",
            dependencies: ["MudEngine"]
        ),
        // The engine test suite. An executable rather than a `.testTarget`
        // because a test target needs XCTest, and XCTest ships inside Xcode.app
        // — a machine with only the Command Line Tools can build and run this
        // app but cannot run `swift test`. Run it with:
        //
        //     swift run MudEngineTests
        //
        // It exits non-zero on failure, so CI treats it the same as any other
        // test command. See Tests/MudEngineTests/TestHarness.swift.
        .executableTarget(
            name: "MudEngineTests",
            dependencies: ["MudEngine"],
            path: "Tests/MudEngineTests"
        ),
    ]
)

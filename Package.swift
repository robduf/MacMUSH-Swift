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
        .testTarget(
            name: "MudEngineTests",
            dependencies: ["MudEngine"]
        ),
    ]
)

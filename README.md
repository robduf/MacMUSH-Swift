# MacMUSH (Swift)

[![tests](https://github.com/robduf/MacMUSH-Swift/actions/workflows/test.yml/badge.svg)](https://github.com/robduf/MacMUSH-Swift/actions/workflows/test.yml)

**A native, minimal MUD client for macOS — written in Swift, no Electron.**

This is a ground-up Swift rewrite of MacMUSH: a small AppKit app with a
Foundation-only engine underneath. No bundled browser, no JavaScript — just a
real Mac app that launches instantly and sips memory.

> Status: early MVP. It connects, negotiates telnet, renders ANSI colour, and
> sends commands with history. Triggers, aliases, timers, Lua scripting, logging,
> MCCP2 and GMCP are the next layers (the engine is structured for them).

## What you need

The Swift compiler and the macOS SDK. Either:

- **Xcode** (free, Mac App Store) — the simplest, gives you everything, or
- **Command Line Tools**: `xcode-select --install`

You never have to *open* Xcode — VS Code (with the official **Swift** extension)
or any editor works, since this is a plain Swift Package.

## Run it

From the project folder:

```
swift run MacMUSH
```

To test against something, start the bundled fake MUD in another terminal:

```
node scripts/fake-mud.js        # listens on 127.0.0.1:4000
```

…then in MacMUSH press **⌘R** and connect to `127.0.0.1 4000`. Try `look`,
`score`, `say hi`, `gmcp`, `wide`, `spam`.

## Build the .app

Double-click **`Build MacMUSH.command`** (or run it), which compiles a release
build and assembles `dist/MacMUSH.app` with its icon, ready to drag into
Applications.

## Tests

The engine (telnet + ANSI parsing) is fully unit-tested — 68 tests:

```
swift run MudEngineTests
```

That's the part with the fiddly logic, so it's covered end-to-end — escape
sequences split across packets, 256/true-colour, telnet negotiation, echo
suppression, GA prompts, incremental UTF-8.

Not `swift test`, deliberately. A test target has to `import XCTest`, and
XCTest lives inside Xcode.app — a Mac with only the Command Line Tools can
build and run this app perfectly well but cannot run `swift test` at all. So
the suite is an ordinary executable with a small assertion harness that keeps
the XCTest function names. It exits non-zero on failure, so CI runs the exact
same command. See `Tests/MudEngineTests/TestHarness.swift`.

Because there are now two executables, plain `swift run` is ambiguous — name
the one you want: `swift run MacMUSH` or `swift run MudEngineTests`.

## Layout

```
Package.swift
Sources/
  MudEngine/          Foundation-only, portable, tested
    TelnetParser.swift    IAC negotiation, TTYPE/NAWS, ECHO, GA/EOR prompts
    AnsiParser.swift      SGR → styled runs (16/256/truecolor, bold/italic/…)
    TextStyle.swift       colour + style model (no AppKit)
    UTF8Incremental.swift streaming UTF-8 decoder
    WorldConfig.swift     one world: host, port, triggers, aliases, timers
    AppConfig.swift       the saved world list + which one is active
    Matcher.swift         trigger/alias matching (wildcards or regex)
    SessionFormat.swift   elapsed time, log filenames, log header/footer
  MacMUSH/            the AppKit app (code-only, no storyboards)
    main.swift            NSApplication entry
    AppDelegate.swift     menus
    WorldWindow.swift     window, text view, input, history, status bar
    SettingsWindow.swift  world editor (connection, triggers, aliases, logging)
    MudConnection.swift   TCP via Network.framework
    AnsiRenderer.swift    MudColor → NSColor, attributed text
    SessionLogger.swift   per-world plain-text session logs
    WorldStore.swift      loads/saves the world list
    Storage.swift         where on disk that lives
Tests/MudEngineTests/  the engine suite + its assertion harness
scripts/fake-mud.js    a tiny test MUD server
```

The engine imports only Foundation, so it stays testable and could be reused on
other platforms; everything Mac-specific lives in the `MacMUSH` target behind
`#if canImport(AppKit)`.

## License

MIT.

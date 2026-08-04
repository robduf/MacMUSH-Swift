# MacMUSH (Swift)

[![tests](https://github.com/robduf/MacMUSH-Swift/actions/workflows/test.yml/badge.svg)](https://github.com/robduf/MacMUSH-Swift/actions/workflows/test.yml)

**A native, minimal MUD client for macOS — written in Swift, no Electron.**

This is a ground-up Swift rewrite of MacMUSH: a small AppKit app with a
Foundation-only engine underneath. No bundled browser, no JavaScript — just a
real Mac app that launches instantly and sips memory.

> Status: usable daily. Multiple worlds open at once, each in its own tab, each
> with its own live connection and log; telnet negotiation, ANSI colour, command
> history, triggers, aliases and timers all work. Lua scripting, MCCP2 and GMCP
> are the next layers (the engine is structured for them).

## Windows and tabs

**⌘N** opens a new window, **⌘T** adds a tab to the one you're using, **⌘W**
closes the current tab (or the window, if it's down to its last one). Drag a
window to a second monitor and watch two worlds side by side.

A world can only be open in one tab at a time — two tabs on one world would mean
two sockets logging in as the same character and two logs appending to the same
file — so opening a world that's already open just brings its tab forward.

Each tab shows a green dot while it's connected. Tabs you aren't looking at
keep running: they stay connected, keep logging, and keep firing their triggers
and timers.

**⌘1**…**⌘9** go straight to a tab by its position across the top of the
window you're in, with ⌘9 always the last one however many there are, and
**⌃⇥** / **⌃⇧⇥** step through them in order.

The Worlds menu numbers your *saved* worlds separately, on **⌃1**…**⌃9** — a
different list, in the order you created the worlds rather than the order the
tabs are in, and only the first nine get keys. ⌃1 goes to that world's tab
wherever it is, including in another window, which ⌘1…⌘9 can't do; if it has
no tab open yet, it gets one. (If ⌃1…⌃4 do nothing, macOS has them: System
Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Mission Control.)

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
    WindowManager.swift   every open window; one world, one tab, app-wide
    WorldWindow.swift     one window: its tab bar and the sessions in it
    TabBarView.swift      the row of tabs, with connected dot and unread badge
    Session.swift         one tab: socket, text view, input, history, log
    SettingsWindow.swift  world editor (connection, triggers, aliases, logging)
    MudConnection.swift   TCP via Network.framework
    Theme.swift           the window's colours, in one place
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

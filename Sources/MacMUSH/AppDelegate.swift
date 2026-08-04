#if canImport(AppKit)
import AppKit
import MudEngine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var settingsWindow: SettingsWindow?
    private var worldsMenu: NSMenu?
    /// Built the first time ⌘K is pressed and kept for the life of the app.
    private var macroPalette: MacroPalette?
    /// The key dispatcher for macros and tab navigation. Held so it's installed
    /// exactly once; it is never removed, because it lives as long as the app.
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Before `buildMenu`, because this is what stops AppKit adding its own
        // tab items to whatever menu becomes `NSApp.windowsMenu` — including a
        // "Show Next Tab" on ⌃⇥ and a "Show Previous Tab" on ⌃⇧⇥, which are the
        // two this app is about to claim for its own tab bar. It also stops the
        // system merging world windows into native tabs, which would put a
        // second row of tabs above the one `TabBarView` draws.
        NSWindow.allowsAutomaticWindowTabbing = false
        buildMenu()
        installKeyMonitor()

        WindowManager.shared.openInitialWindow()

        // Keep the Worlds menu in sync whenever the store changes (add / rename /
        // delete / switch, or a slash-command edit).
        NotificationCenter.default.addObserver(
            self, selector: #selector(worldStoreChanged),
            name: .worldStoreDidChange, object: nil)
        rebuildWorldsMenu()

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// ⌘Q with a world still on the other end of a socket. Closing a window
    /// asks separately and disconnects as it goes, so by the time the last one
    /// closes there's nothing live left and this doesn't fire a second prompt.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard WindowManager.shared.hasConnectedSession else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit while still connected?"
        alert.informativeText = "You're connected to at least one world. Quitting disconnects and closes any session logs."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    /// Quitting mid-session still closes the logs properly — footers written,
    /// file handles released — and shuts the sockets instead of leaving the MUDs
    /// to time the connections out on their own.
    func applicationWillTerminate(_ notification: Notification) {
        WindowManager.shared.disconnectAll()
    }

    // MARK: Menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        // Application menu
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About MacMUSH",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide MacMUSH", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit MacMUSH", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File menu — Safari's arrangement, because that's the one everybody
        // already has in their fingers: ⌘N window, ⌘T tab, ⌘W tab, ⇧⌘W window.
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        let newWindowItem = fileMenu.addItem(withTitle: "New Window", action: #selector(newWindow), keyEquivalent: "n")
        newWindowItem.target = self
        let newTabItem = fileMenu.addItem(withTitle: "New Tab…", action: #selector(newTab), keyEquivalent: "t")
        newTabItem.target = self
        fileMenu.addItem(.separator())
        let connectItem = fileMenu.addItem(withTitle: "Connect…", action: #selector(connect), keyEquivalent: "r")
        connectItem.target = self
        let disconnectItem = fileMenu.addItem(withTitle: "Disconnect", action: #selector(disconnect), keyEquivalent: "d")
        disconnectItem.keyEquivalentModifierMask = [.command, .shift]
        disconnectItem.target = self
        fileMenu.addItem(.separator())
        let closeTabItem = fileMenu.addItem(withTitle: "Close Tab", action: #selector(closeTab), keyEquivalent: "w")
        closeTabItem.target = self
        let closeWindowItem = fileMenu.addItem(withTitle: "Close Window", action: #selector(closeWindow), keyEquivalent: "w")
        closeWindowItem.keyEquivalentModifierMask = [.command, .shift]
        closeWindowItem.target = self

        // Worlds menu (populated by rebuildWorldsMenu)
        let worldsItem = NSMenuItem()
        mainMenu.addItem(worldsItem)
        let worldsMenu = NSMenu(title: "Worlds")
        worldsItem.submenu = worldsMenu
        self.worldsMenu = worldsMenu

        // Edit menu (enables Cut/Copy/Paste/Select-All in the text views)
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // Window menu. AppKit fills the bottom of this in with one item per open
        // window once `NSApp.windowsMenu` is set, which is exactly what you want
        // the moment there's more than one.
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        // ⌘K. Free, unlike ⌘1…⌘9 — those go to the tabs — and unlike the dozen
        // combinations File and Edit already hold.
        let macrosItem = windowMenu.addItem(withTitle: "Macros",
                                            action: #selector(toggleMacroPalette),
                                            keyEquivalent: "k")
        macrosItem.target = self
        windowMenu.addItem(.separator())

        // ⌃⇥ and ⌃⇧⇥, the pair Safari and Chrome already use for this.
        //
        // Not bare ⇥ or ⇧⇥: the command box has both, for completing a word from
        // what's on screen. ⌘1…⌘9 go to tabs as well, but by position rather than
        // by which one you're on, and they are handled entirely in the monitor
        // with nothing in a menu — see `selectNumberedTab(for:)` for why.
        //
        // These are the captions. The key presses themselves are caught by the
        // monitor in `installKeyMonitor`, which matches the physical key code;
        // see there for why that's the reliable half of this.
        //
        // The two key equivalents are spelled differently on purpose. A menu
        // matches its equivalent against `charactersIgnoringModifiers`, and that
        // property keeps shift — so ⌃⇧⇥ arrives as back tab, U+0019, and never
        // as a tab. Give both items "\t" and the second one is a caption with a
        // dead key behind it.
        //
        // Which means the second item is likely drawn "⌃⇧⇤" rather than "⌃⇧⇥",
        // since ⇤ is the glyph for back tab — the same one `ShortcutFormat` uses
        // for it. Redundant, because ⇤ already says shift, but it is the honest
        // spelling of the key that actually fires.
        let nextTabItem = windowMenu.addItem(withTitle: "Next Tab",
                                             action: #selector(nextTab),
                                             keyEquivalent: "\t")
        nextTabItem.keyEquivalentModifierMask = [.control]
        nextTabItem.target = self
        let previousTabItem = windowMenu.addItem(withTitle: "Previous Tab",
                                                 action: #selector(previousTab),
                                                 keyEquivalent: "\u{19}")
        previousTabItem.keyEquivalentModifierMask = [.control, .shift]
        previousTabItem.target = self

        windowMenu.addItem(.separator())
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    /// Rebuild the Worlds menu from the store: one checkable item per world
    /// (⌃1…⌃9 for the first nine), then add / rename / delete actions. The tick
    /// marks the world in the frontmost tab.
    private func rebuildWorldsMenu() {
        guard let menu = worldsMenu else { return }
        menu.removeAllItems()

        let store = WorldStore.shared
        let selectedID = store.selectedWorldID
        for (i, world) in store.worlds.enumerated() {
            let key = i < 9 ? "\(i + 1)" : ""
            let item = menu.addItem(withTitle: world.name, action: #selector(switchWorld(_:)), keyEquivalent: key)
            // ⌃, not ⌘. ⌘1…⌘9 are the tabs across the top of the front window,
            // which is what you can see and what anything else with tabs numbers
            // with them. These number the *saved worlds* instead, in the order
            // they were made — a different list, and one where picking a world
            // with no tab yet opens a new tab for it. That is the point of them,
            // and it is not what you want to happen when you meant to go back to
            // the first tab. See `selectNumberedTab(for:)`.
            //
            // Set on the item afterwards rather than passed in, because
            // `addItem(withTitle:action:keyEquivalent:)` takes no modifier
            // argument and `NSMenuItem`'s mask starts out as ⌘.
            //
            // ⌃1…⌃9 are worth knowing about: macOS has its own claim on them for
            // Mission Control's "Switch to Desktop N". Off unless you've turned
            // them on, and there is one row per desktop you actually have, so
            // most people never see them — but the system takes them before any
            // application does, before a local event monitor even, so if one of
            // these does nothing that is where it went. System Settings ▸
            // Keyboard ▸ Keyboard Shortcuts ▸ Mission Control is where it comes
            // back from.
            if i < 9 { item.keyEquivalentModifierMask = [.control] }
            item.target = self
            item.representedObject = world.id
            item.state = (world.id == selectedID) ? .on : .off
        }

        menu.addItem(.separator())
        let newItem = menu.addItem(withTitle: "New World…", action: #selector(newWorld), keyEquivalent: "n")
        newItem.keyEquivalentModifierMask = [.command, .shift]
        newItem.target = self
        let renameItem = menu.addItem(withTitle: "Rename Current World…", action: #selector(renameWorld), keyEquivalent: "")
        renameItem.target = self
        let deleteItem = menu.addItem(withTitle: "Delete Current World…", action: #selector(deleteWorld), keyEquivalent: "")
        deleteItem.target = self
        menu.addItem(.separator())
        let manageItem = menu.addItem(withTitle: "Manage Worlds…", action: #selector(showSettings), keyEquivalent: "")
        manageItem.target = self
    }

    @objc private func worldStoreChanged() {
        rebuildWorldsMenu()
        WindowManager.shared.syncAll()
    }

    /// Ticks the Macros item while the palette is up, and greys Next / Previous
    /// Tab when there's nowhere to go. Everything else targeted at this object
    /// stays enabled, which is what AppKit was doing before this method existed.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleMacroPalette) {
            menuItem.state = (macroPalette?.isVisible == true) ? .on : .off
        }
        // Nothing to move between with one tab, and nothing to move *in* when
        // the front window isn't a world at all. Greyed out rather than quietly
        // doing nothing, so the menu says so.
        if menuItem.action == #selector(nextTab) || menuItem.action == #selector(previousTab) {
            return frontWorldWindow()?.hasMultipleTabs == true
        }
        return true
    }

    // MARK: Macros

    @objc private func toggleMacroPalette() {
        if macroPalette == nil { macroPalette = MacroPalette() }
        macroPalette?.toggle()
    }

    /// Watch every key press for one a macro in the frontmost world has claimed,
    /// or for one of the ones that move between that window's tabs.
    ///
    /// A local monitor rather than the responder chain, because a monitor sees
    /// the event *before* the main menu gets to claim its key equivalents. That
    /// is the only way a macro on a ⌘-combination can work at all: route this
    /// through `keyDown` and ⌘C would reach Edit ▸ Copy first and the macro
    /// would never run. The same technique the shortcut recorder uses, for the
    /// same reason.
    ///
    /// Its one visible consequence: a macro bound to ⌘K wins over the Macros
    /// menu item above. That's the right way round — the person who bound it
    /// said what they wanted more recently than this file did — but it does mean
    /// the palette is then reachable only from the menu.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            // nil swallows the event; returning it lets it carry on to the menu
            // and then the responder chain, exactly as if this weren't here.
            //
            // Macros get first refusal and tab navigation only sees what they
            // didn't want, on the same principle as ⌘K above: someone who binds
            // a macro to ⌃⇥ has said so more recently than this file did.
            if self.runMacro(for: event) { return nil }
            if self.switchTab(for: event) { return nil }
            if self.selectNumberedTab(for: event) { return nil }
            return event
        }
    }

    /// Whether this key press belonged to a macro — and if so, having run it.
    private func runMacro(for event: NSEvent) -> Bool {
        // Only when a world window is the thing you're typing into. Deliberately
        // *not* `WindowManager.activeSession`, which falls back to the last
        // window you used: that would let a key pressed in Settings, or in the
        // palette's own title bar, fire a command into a world behind them.
        //
        // It's also what keeps this out of the shortcut recorder's way. While
        // you're recording a key in Settings, the key window is Settings, so
        // this returns here and the recorder's own monitor gets the press.
        guard let window = NSApp.keyWindow,
              let worldWindow = window.delegate as? WorldWindow,
              let session = worldWindow.activeSession else { return false }

        // An alert or a sheet is up. Whatever it's asking, the answer isn't a
        // command sent to the MUD behind it.
        guard NSApp.modalWindow == nil, window.attachedSheet == nil else { return false }

        let modifiers = event.shortcutModifiers
        // A macro with no text yet doesn't count as a match. Otherwise a row
        // given a key before its command — which is the order you'd fill one in
        // if you got distracted — swallows that key and does nothing with it:
        // put ⌘V on a blank row and Paste quietly stops working in that world,
        // with nothing on screen to say why.
        guard let macro = session.macros.first(where: {
            !$0.sendText.isEmpty
                && $0.shortcut?.matches(keyCode: event.keyCode, modifiers: modifiers) == true
        }) else { return false }

        // Swallowed, but not run again: holding the key down would otherwise
        // send the command as fast as the keyboard repeats. Letting the repeats
        // through instead would type the macro's own key into the command box.
        guard !event.isARepeat else { return true }

        return session.runMacro(macro)
    }

    // MARK: Tabs

    /// The physical Tab key. A Carbon `kVK_` constant, fixed to a position on
    /// the keyboard rather than to what that position types, and unchanged since
    /// the Apple Extended Keyboard — the same reasoning `ShortcutFormat` uses
    /// for Escape and Space.
    private static let tabKeyCode: UInt16 = 48

    /// Whether this key press was ⌃⇥ or ⌃⇧⇥ — and if so, having moved.
    ///
    /// Matched on the key *code* rather than on the character, because ⇧⇥ does
    /// not report a tab character at all. It reports back-tab, a different
    /// codepoint entirely, so a character comparison needs two spellings and
    /// would still be at the mercy of the layout. One number, the same on every
    /// keyboard, is why `KeyShortcut` stores codes too.
    ///
    /// This is also the half that does the work. The two Window menu items carry
    /// the same key presses as captions — ⌃⇥ on the first, and back tab on the
    /// second, which AppKit will most likely draw as ⌃⇧⇤ — and they will fire if
    /// AppKit matches them, but a tab character as a menu key equivalent is not
    /// something to rest on. Nothing can fire twice either way, because a match
    /// here swallows the event before the menu is asked.
    private func switchTab(for event: NSEvent) -> Bool {
        guard event.keyCode == AppDelegate.tabKeyCode else { return false }

        // Exactly ⌃, or exactly ⌃⇧. `shortcutModifiers` has already dropped caps
        // lock and the function bit, which ride along on real presses without
        // anyone having chosen them.
        let modifiers = NSEvent.ModifierFlags(rawValue: event.shortcutModifiers)
        guard modifiers.subtracting(.shift) == .control else { return false }

        // Scoped exactly as macros are: only when a world window is the thing
        // you're typing into, and not while a sheet or an alert is up. Without
        // it, ⌃⇥ pressed in Settings would shuffle the tabs of a window behind.
        guard let window = NSApp.keyWindow,
              let worldWindow = window.delegate as? WorldWindow,
              NSApp.modalWindow == nil, window.attachedSheet == nil else { return false }

        // Swallowed from here on whether or not it moves — with a single tab
        // there's nowhere to go, but the key is still spoken for, and letting it
        // through would put a tab character in the command box instead.
        //
        // Repeats are dropped for the same reason macros drop them: holding the
        // key would cycle at the keyboard's repeat rate, and every switch tears
        // the session view down and builds it back.
        guard !event.isARepeat else { return true }

        if modifiers.contains(.shift) {
            worldWindow.selectPreviousTab()
        } else {
            worldWindow.selectNextTab()
        }
        return true
    }

    /// Whether this key press was ⌘1…⌘9 — and if so, having gone to that tab.
    ///
    /// A *position in the front window*, which is what every browser on the
    /// machine means by ⌘1 and what these used not to mean here. (Not every
    /// app: Finder puts view modes on ⌘1…⌘4, Mail puts mailboxes there. But
    /// tabs across the top of a window is the thing this is, and where anything
    /// has tabs it numbers them.) They were on the Worlds menu,
    /// numbering the saved worlds in the order they were made — so ⌘1 meant "the
    /// first world I ever set up", in no particular relation to the tabs on
    /// screen, and picking one with no tab open yet opened a *new tab* for it.
    /// Ask for the first tab, get a fourth tab on a world you weren't thinking
    /// about; and since selecting a tab names the current world, Worlds ▸ Rename
    /// and Delete Current World then pointed at it too. The worlds keep their
    /// numbers, one modifier over — see `rebuildWorldsMenu`. Those stayed a menu
    /// key equivalent rather than moving in here, so they don't get the shift
    /// tolerance below: a menu matches its modifier mask exactly.
    ///
    /// Matched on the character rather than the key code, which is the opposite
    /// of `switchTab` above and for the opposite reason: a digit has only the one
    /// spelling, so there is nothing to disambiguate, and matching what the key
    /// *types* is most of what a menu key equivalent does. Most of — AppKit also
    /// falls back to an ASCII-capable layout, which is how ⌘C keeps working on a
    /// Cyrillic one, and this does not. What this does instead is take shift.
    ///
    /// Shift, because on AZERTY and on the Czech and Slovak layouts the number
    /// row types punctuation and letters unshifted and shift is how you type a
    /// digit at all. `charactersIgnoringModifiers` keeps shift — the same fact
    /// that makes `switchTab` match back tab by key code instead — so on those
    /// layouts the digit only ever arrives with shift held, and an exact ⌘ test
    /// would put this feature entirely out of reach there. Where the digits are
    /// unshifted nothing is claimed that wasn't asked for, because ⇧⌘1 types "!"
    /// on such a layout and never reaches the `Int`.
    ///
    /// It buys back six of the nine, not all of them. On those same layouts
    /// "⌘3", "⌘4" and "⌘5" are physically ⇧⌘ on the 3, 4 and 5 keys, which are
    /// where macOS keeps its screenshot shortcuts — and those are registered on
    /// key codes and taken above the app, so nothing here can reach them. Same
    /// class of thing as the note on ⌃1…⌃9 in `rebuildWorldsMenu`, and with the
    /// same remedy: System Settings ▸ Keyboard ▸ Keyboard Shortcuts, under
    /// Screenshots this time.
    ///
    /// No menu items to go with these: nine of them, captioned with the same tab
    /// titles the tab bar is already showing, is most of the Window menu for no
    /// new information. The price is that they are discoverable only from the
    /// README, and can't be remapped in System Settings ▸ Keyboard ▸ App
    /// Shortcuts, which works off menu titles.
    private func selectNumberedTab(for event: NSEvent) -> Bool {
        // ⌘, or ⌘⇧ — see above. Not ⌥⌘ or ⌃⌘, which are unspoken for, and
        // swallowing them here would be claiming keys this hasn't earned.
        //
        // `shortcutModifiers` has already dropped caps lock, the function bit
        // and the numeric-keypad bit, none of which anyone chose to press. The
        // last of those is why the keypad's digits work here too.
        let modifiers = NSEvent.ModifierFlags(rawValue: event.shortcutModifiers)
        guard modifiers.subtracting(.shift) == .command,
              let characters = event.charactersIgnoringModifiers,
              characters.count == 1,
              // ASCII only, which is what `Int(String)` accepts — and so ⌘0
              // falls through unclaimed, having no tab to be.
              let number = Int(characters), number >= 1 else { return false }

        // Scoped exactly as `switchTab` is, and for the same reasons.
        guard let window = NSApp.keyWindow,
              let worldWindow = window.delegate as? WorldWindow,
              NSApp.modalWindow == nil, window.attachedSheet == nil else { return false }

        // Swallowed from here on whether or not there's a tab there. ⌘4 with
        // three tabs open has still been spoken for, and letting it through
        // would only reach a responder chain with nothing bound to it, and beep.
        //
        // Repeats are dropped for the same reason macros and ⌃⇥ drop them:
        // holding ⌘1 down would re-run the switch at the keyboard's repeat rate.
        // Harmless here, since going to the tab you're on is now a no-op, but
        // there is nothing for the second press to do either.
        guard !event.isARepeat else { return true }

        worldWindow.selectTab(numbered: number)
        return true
    }

    // MARK: Actions

    @objc private func connect() { WindowManager.shared.activeSession?.promptConnect() }
    @objc private func disconnect() { WindowManager.shared.activeSession?.disconnect() }

    @objc private func newWindow() { WindowManager.shared.newWindow() }
    @objc private func newTab() { WindowManager.shared.newTab() }
    @objc private func closeTab() {
        guard let window = frontWorldWindow() else {
            NSApp.keyWindow?.performClose(nil)
            return
        }
        window.closeActiveTab()
    }

    @objc private func closeWindow() {
        guard let window = frontWorldWindow() else {
            NSApp.keyWindow?.performClose(nil)
            return
        }
        window.closeWindow()
    }

    /// Picked from the Window menu. No fallback when the front window isn't
    /// ours, unlike ⌘W: there is nothing sensible to hand "next tab" back to,
    /// and `validateMenuItem` has greyed the item out in that case anyway.
    @objc private func nextTab() { frontWorldWindow()?.selectNextTab() }
    @objc private func previousTab() { frontWorldWindow()?.selectPreviousTab() }

    /// The world window the user is actually looking at, or nil if something
    /// else is in front.
    ///
    /// ⌘W and ⇧⌘W are wired to this object rather than to a window, which means
    /// they fire no matter what's frontmost. Without this check, pressing ⌘W
    /// with Settings in front would reach straight past it and close a tab in
    /// some world window behind — one the user isn't even looking at. When the
    /// front window isn't ours, the callers hand ⌘W back to it, which is what
    /// AppKit would have done with it anyway.
    ///
    /// No key window means no answer — deliberately. Falling back to the *last*
    /// world window looks helpful and isn't: miniaturise everything and there is
    /// no key window, so ⌘W would close a window you can't see, and a window
    /// down to its last tab closes for real, which takes the app with it.
    private func frontWorldWindow() -> WorldWindow? {
        NSApp.keyWindow?.delegate as? WorldWindow
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let settings = SettingsWindow()
            settings.onActivateWorld = { world in
                WindowManager.shared.openWorld(world)
            }
            settingsWindow = settings
        }
        settingsWindow?.show()
    }

    /// ⌃1…⌃9. Focuses the world's tab if it's already open anywhere, otherwise
    /// opens it in a new tab — a world is never in two tabs at once. Opening it
    /// does not connect it; the new tab says ⌘R for that, same as any other.
    ///
    /// That second half is why these are not on ⌘. "Go to it, opening it if you
    /// have to" is a reasonable thing to want, but it is not what a number with
    /// a command key in front of it means to anyone, and it meant ⌘1 opened a
    /// tab you hadn't asked for. ⌘1…⌘9 select tabs now — see
    /// `selectNumberedTab(for:)`.
    @objc private func switchWorld(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let world = WorldStore.shared.worlds.first(where: { $0.id == id }) else { return }
        WindowManager.shared.openWorld(world)
    }

    @objc private func newWorld() {
        guard let name = promptText(title: "New World",
                                    info: "Name this world. You can set its host and port with ⌘R after its tab opens.",
                                    defaultValue: "New World"),
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        // `insertWorld` leaves the selection alone; opening the tab is what makes
        // the new world current, and having both do it would fight.
        let world = WorldConfig(name: name)
        WorldStore.shared.insertWorld(world)
        WindowManager.shared.openWorld(world)
    }

    @objc private func renameWorld() {
        let current = WorldStore.shared.selectedWorld
        guard let name = promptText(title: "Rename World",
                                    info: "Enter a new name for “\(current.name)”.",
                                    defaultValue: current.name),
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        WorldStore.shared.renameSelected(to: name)
    }

    @objc private func deleteWorld() {
        let store = WorldStore.shared
        guard store.worlds.count > 1 else {
            let alert = NSAlert()
            alert.messageText = "Can’t delete your only world"
            alert.informativeText = "Create another world first, then delete this one."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        let current = store.selectedWorld
        let alert = NSAlert()
        alert.messageText = "Delete “\(current.name)”?"
        alert.informativeText = "This removes the world and its triggers, aliases, and timers. This can’t be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // The store notifies, and every window closes the orphaned tab itself.
        store.removeWorld(id: current.id)
    }

    // MARK: Helpers

    /// Modal single-line text prompt. Returns the entered string, or nil on Cancel.
    private func promptText(title: String, info: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}
#endif

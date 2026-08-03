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
        // ⌘K. Free, unlike ⌘1…⌘9 — those are the Worlds menu — and unlike the
        // dozen combinations File and Edit already hold.
        let macrosItem = windowMenu.addItem(withTitle: "Macros",
                                            action: #selector(toggleMacroPalette),
                                            keyEquivalent: "k")
        macrosItem.target = self
        windowMenu.addItem(.separator())

        // ⌃⇥ and ⌃⇧⇥, the pair Safari and Chrome already use for this.
        //
        // Not bare ⇥ or ⇧⇥: the command box has both, for completing a word from
        // what's on screen. And not ⌘1…⌘9 either — the Worlds menu holds those,
        // and they mean a different thing anyway (a named *world*, wherever its
        // tab happens to be, rather than a position in this window).
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
    /// (⌘1…⌘9 for the first nine), then add / rename / delete actions. The tick
    /// marks the world in the frontmost tab.
    private func rebuildWorldsMenu() {
        guard let menu = worldsMenu else { return }
        menu.removeAllItems()

        let store = WorldStore.shared
        let selectedID = store.selectedWorldID
        for (i, world) in store.worlds.enumerated() {
            let key = i < 9 ? "\(i + 1)" : ""
            let item = menu.addItem(withTitle: world.name, action: #selector(switchWorld(_:)), keyEquivalent: key)
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
    /// or for the two that move between that window's tabs.
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

    /// ⌘1…⌘9. Focuses the world's tab if it's already open anywhere, otherwise
    /// opens it in a new tab — a world is never in two tabs at once.
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

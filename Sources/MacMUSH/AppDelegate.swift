#if canImport(AppKit)
import AppKit
import MudEngine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settingsWindow: SettingsWindow?
    private var worldsMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()

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

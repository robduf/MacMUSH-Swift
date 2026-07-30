#if canImport(AppKit)
import AppKit
import MudEngine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var worldWindow: WorldWindow?
    private var settingsWindow: SettingsWindow?
    private var worldsMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()

        let world = WorldWindow()
        world.showWindow()
        worldWindow = world

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

        // File menu
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        let connectItem = fileMenu.addItem(withTitle: "Connect…", action: #selector(connect), keyEquivalent: "r")
        connectItem.target = self
        let disconnectItem = fileMenu.addItem(withTitle: "Disconnect", action: #selector(disconnect), keyEquivalent: "d")
        disconnectItem.keyEquivalentModifierMask = [.command, .shift]
        disconnectItem.target = self

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

        // Window menu
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    /// Rebuild the Worlds menu from the store: one checkable item per world
    /// (⌘1…⌘9 for the first nine), then add / rename / delete actions.
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
        syncLiveWindow()
    }

    /// Push store changes into the live window: edits made in the Worlds window
    /// apply in place, and if the world it was showing has been deleted it moves
    /// to whatever the store selected in its stead.
    private func syncLiveWindow() {
        guard let window = worldWindow else { return }
        let store = WorldStore.shared
        if let current = store.worlds.first(where: { $0.id == window.currentWorldID }) {
            window.syncActiveWorld(current)
        } else {
            window.activate(world: store.selectedWorld)
        }
    }

    // MARK: Actions

    @objc private func connect() { worldWindow?.promptConnect() }
    @objc private func disconnect() { worldWindow?.disconnect() }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let settings = SettingsWindow()
            settings.onActivateWorld = { [weak self] world in
                WorldStore.shared.select(id: world.id)
                self?.worldWindow?.activate(world: world)
            }
            settingsWindow = settings
        }
        settingsWindow?.show()
    }

    @objc private func switchWorld(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        guard id != WorldStore.shared.selectedWorldID else { return }
        WorldStore.shared.select(id: id)
        worldWindow?.activate(world: WorldStore.shared.selectedWorld)
    }

    @objc private func newWorld() {
        guard let name = promptText(title: "New World",
                                    info: "Name this world. You can set its host and port with ⌘R after it opens.",
                                    defaultValue: "New World"),
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let world = WorldConfig(name: name)
        WorldStore.shared.addWorld(world)
        worldWindow?.activate(world: WorldStore.shared.selectedWorld)
    }

    @objc private func renameWorld() {
        let current = WorldStore.shared.selectedWorld
        guard let name = promptText(title: "Rename World",
                                    info: "Enter a new name for “\(current.name)”.",
                                    defaultValue: current.name),
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        WorldStore.shared.renameSelected(to: name)
        worldWindow?.syncActiveWorld(WorldStore.shared.selectedWorld)
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
        store.removeWorld(id: current.id)
        worldWindow?.activate(world: store.selectedWorld)
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

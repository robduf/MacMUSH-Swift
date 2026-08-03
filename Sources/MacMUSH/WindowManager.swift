#if canImport(AppKit)
import AppKit
import MudEngine

/// Owns every open window and answers "where is world X?".
///
/// The rule the whole design hangs on: **one world, one tab, app-wide.** Two
/// tabs on the same world would mean two live sockets logging in as the same
/// character and two `SessionLogger`s appending to the same file — so opening a
/// world that's already open brings its window forward and switches to its tab
/// instead of making a second one. This class is the only thing that can
/// enforce that, because it's the only thing that can see across windows.
final class WindowManager {
    static let shared = WindowManager()

    private(set) var windows: [WorldWindow] = []
    /// Weak: `windows` is what keeps windows alive. This only remembers which
    /// one you were last using.
    private weak var lastKeyWindow: WorldWindow?
    /// Set for the duration of `syncAll()`, which can re-enter itself.
    private var isSyncing = false

    private init() {}

    /// The window a menu command should act on: the one you're using, or —
    /// while a panel like Settings holds focus — the last one you used.
    var activeWindow: WorldWindow? {
        if let key = windows.first(where: { $0.isKeyWindow }) { return key }
        if let remembered = lastKeyWindow { return remembered }
        return windows.last
    }

    var activeSession: Session? { activeWindow?.activeSession }

    var hasConnectedSession: Bool {
        windows.contains { $0.hasConnectedSession }
    }

    // MARK: Opening

    /// The window the app starts with, showing whichever world was last active.
    func openInitialWindow() {
        let window = makeWindow(world: WorldStore.shared.selectedWorld)
        window.show()
    }

    /// ⌘N. A second window, so a world can live on another monitor.
    func newWindow() {
        guard let world = firstUnopenedWorld() else {
            offerToCreateWorld(into: nil)
            return
        }
        let window = makeWindow(world: world)
        window.show()
    }

    /// ⌘T. Adds to the window you're using rather than making a new one.
    func newTab() {
        guard let window = activeWindow else {
            newWindow()
            return
        }
        // Nothing left to put in a tab: offer to make a world rather than
        // popping up a menu where every item is ticked and greyed out.
        guard firstUnopenedWorld() != nil else {
            offerToCreateWorld(into: window)
            return
        }
        window.bringToFront()
        // Deferred, because this arrives from a menu key-equivalent and the
        // picker is a menu of its own. Starting a second menu's tracking loop
        // from inside the first one's dispatch is a fight you don't need.
        DispatchQueue.main.async { window.promptNewTab() }
    }

    /// Show a world: focus its tab if it's open anywhere, otherwise open it in
    /// a new tab in the window you're using.
    func openWorld(_ world: WorldConfig) {
        // Switch the tab *first*, then raise. Raising a window makes it key,
        // and becoming key re-asserts its frontmost tab as the current world —
        // so doing it the other way round briefly selects the world you're
        // leaving before selecting the one you asked for.
        if let (window, index) = locate(worldID: world.id) {
            window.selectTab(at: index)
            window.bringToFront()
            return
        }
        guard let window = activeWindow else {
            makeWindow(world: world).show()
            return
        }
        window.addTab(world: world)
        window.bringToFront()
    }

    /// Which window and tab a world is open in, if any.
    func locate(worldID: String) -> (window: WorldWindow, index: Int)? {
        for window in windows {
            if let index = window.indexOfTab(worldID: worldID) {
                return (window, index)
            }
        }
        return nil
    }

    @discardableResult
    private func makeWindow(world: WorldConfig) -> WorldWindow {
        let window = WorldWindow()
        window.cascade(from: windows.last)
        windows.append(window)
        window.addTab(world: world)
        lastKeyWindow = window
        return window
    }

    /// The first saved world that isn't open in any tab in any window.
    func firstUnopenedWorld() -> WorldConfig? {
        WorldStore.shared.worlds.first { locate(worldID: $0.id) == nil }
    }

    /// Every world is already on screen, so there's nothing left to put in the
    /// new window or tab. Offer the obvious next move rather than a dead end.
    ///
    /// `target` is the window to put the new world's tab in — nil for a window
    /// of its own. It's handed in rather than looked up again at the bottom,
    /// because two modal alerts run in between, and by then `activeWindow` can
    /// name a different window than the one ⌘T was pressed in.
    private func offerToCreateWorld(into target: WorldWindow?) {
        let alert = NSAlert()
        alert.messageText = "Every saved world is already open"
        alert.informativeText = "A world can only be open in one tab at a time, so there's nothing left to put here. Create another world?"
        alert.addButton(withTitle: "New World…")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let nameAlert = NSAlert()
        nameAlert.messageText = "New World"
        nameAlert.informativeText = "Name this world. You can set its host and port with ⌘R after it opens."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = "New World"
        nameAlert.accessoryView = field
        nameAlert.addButton(withTitle: "OK")
        nameAlert.addButton(withTitle: "Cancel")
        nameAlert.window.initialFirstResponder = field
        guard nameAlert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        // `insertWorld`, not `addWorld`: opening the tab is what makes a world
        // current here, and letting the store also switch the selection would
        // fight with the tab that's about to do it.
        let world = WorldConfig(name: name)
        WorldStore.shared.insertWorld(world)
        guard let target = target else {
            makeWindow(world: world).show()
            return
        }
        target.addTab(world: world)
        // The alerts ran over whatever happened to be in front — Settings, very
        // likely, since that's where you'd have been deleting worlds. Raise the
        // window the new tab actually went into, or it opens out of sight.
        target.bringToFront()
    }

    // MARK: Window lifecycle

    func windowBecameKey(_ window: WorldWindow) {
        lastKeyWindow = window
    }

    func windowClosed(_ window: WorldWindow) {
        if lastKeyWindow === window { lastKeyWindow = nil }
        // Removed now, deallocated later — and in that order, which is the whole
        // point. This arrives from inside the window's own `windowWillClose`,
        // and `windows` holds the only strong reference there is: everything
        // else that points at a `WorldWindow` — `lastKeyWindow`, `NSWindow`'s
        // delegate, every callback the tab bar and the sessions hold — is weak.
        // So the removal below can be the release that frees the object while
        // AppKit is still unwinding through it.
        //
        // Hence the retain *first*: `withExtendedLifetime` cannot extend a
        // lifetime that has already ended. The block holds the window to the
        // next turn of the run loop, by which time the close has finished
        // unwinding. Deferring the removal instead — the obvious alternative —
        // leaves a closed window sitting in `windows` for that same turn, and
        // `activeWindow`'s `windows.last` fallback then hands a menu command a
        // window that isn't on screen any more.
        DispatchQueue.main.async { withExtendedLifetime(window) {} }
        windows.removeAll { $0 === window }
    }

    // MARK: Broadcast

    /// Quitting mid-session still closes every log properly — footer written,
    /// file handle released — and shuts the sockets rather than leaving the MUDs
    /// to time the connections out on their own.
    func disconnectAll() {
        for window in windows { window.disconnectAll() }
    }

    /// Push store edits — renames, trigger changes, deletions — into every tab.
    ///
    /// Guarded against re-entry. A window that loses a tab to a deleted world
    /// re-points what's left and tells the store which world is current now; the
    /// store posts its change notification synchronously, and that lands right
    /// back here, in the middle of this loop. Dropping the nested pass is safe
    /// rather than merely cheap: the loop it interrupted is already on its way
    /// round every window, and each one reads the store fresh when its turn
    /// comes, so nobody ends up working from the state as it was.
    func syncAll() {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        for window in windows { window.syncFromStore() }
    }
}
#endif

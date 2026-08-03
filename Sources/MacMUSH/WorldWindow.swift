#if canImport(AppKit)
import AppKit
import MudEngine

/// One window, holding one or more `Session`s behind a tab bar.
///
/// This used to be the whole app: window, text views, connection, triggers, the
/// lot. All of that except the window itself now lives in `Session`, and what's
/// left here is the container — a tab bar across the top, and below it whichever
/// session's view is frontmost. Switching tabs swaps that one view. Nothing
/// about a background session is paused, stopped or torn down: its socket is
/// still open, its timers still fire, its log still fills, and its scrollback
/// still grows. It simply isn't on screen.
///
/// Windows are peers. `WindowManager` owns them all and knows which is key;
/// nothing here reaches for another window.
final class WorldWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let tabBar = TabBarView()
    /// Whichever session is frontmost is the only subview this ever has.
    private let container = NSView()

    private(set) var sessions: [Session] = []
    private(set) var activeIndex = 0
    /// Set while a coalesced bar redraw is waiting on the run loop.
    private var tabRefreshScheduled = false
    /// Set while the "+" world picker is on screen.
    private var pickerPending = false

    var activeSession: Session? {
        sessions.indices.contains(activeIndex) ? sessions[activeIndex] : nil
    }

    override init() {
        // `.fullSizeContentView` is what makes the tab bar the title bar. It
        // runs the content view up under the titlebar strip instead of starting
        // it below, so the bar — pinned to the top of that content view a few
        // lines down — lands in the strip itself, with the traffic lights
        // floating over its leading end. Together with the transparent titlebar
        // and hidden title set after `super.init()`, that's one row across the
        // top of the window rather than a title bar with a tab bar under it.
        //
        // 628 rather than 600 because the content rect now *includes* the
        // titlebar strip: at 600 the window would come up 28pt shorter on screen
        // than it used to for the same amount of scrollback.
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 628),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        // Nothing above this line may *read* a property: `window.title = …` is a
        // read of `window` followed by a write to the object it points at, and
        // Swift's two-phase initialisation only lets a subclass *assign* to its
        // own stored properties before `super.init()`.
        super.init()

        window.title = "MacMUSH"
        window.minSize = NSSize(width: 520, height: 320)
        // The manager decides when a window goes away. Without this, closing one
        // would drop the last reference out from under the array holding it.
        window.isReleasedWhenClosed = false
        window.delegate = self

        // The other half of `.fullSizeContentView`: with the titlebar drawn
        // transparent and its text hidden, there's nothing up there but the
        // traffic lights, and the tab bar underneath shows through as the top
        // row of the window. The title itself is still set — it's what the
        // Window menu lists this window as.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // `.automatic` draws a line under the titlebar for some window
        // configurations, and it would land across the middle of the tab strip.
        window.titlebarSeparatorStyle = .none
        // Pinned dark rather than following the system. The scrollback is a
        // terminal with hardcoded ANSI colours on a near-black background, so a
        // world window is dark whatever macOS is doing — and the semantic
        // colours the tab bar and status line use (`labelColor`,
        // `separatorColor`) have to resolve against that, not against a light
        // window that isn't there. The Worlds window is left following the
        // system: it's an ordinary Mac editor, not a terminal.
        window.appearance = NSAppearance(named: .darkAqua)
        // Fills the margins around the split view and the strip the status line
        // sits on, so the top chrome, the bottom chrome and the gaps between
        // them are one colour instead of three.
        window.backgroundColor = Theme.chrome

        let content = NSView()
        for sub in [tabBar, container] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: content.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.barHeight),

            container.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.center()
        // Not before `contentView` is set: the traffic lights live in the theme
        // frame, and asking for one measures it into existence only once the
        // window has a content view to lay out around.
        tabBar.leadingInset = trafficLightInset

        // By world id, not by position: the bar defers clicks by a turn of the
        // run loop, and a tab closing in between would otherwise make a pending
        // click land on whichever world had slid into that slot.
        tabBar.onSelect = { [weak self] id in self?.selectTab(worldID: id) }
        tabBar.onClose = { [weak self] id in self?.closeTab(worldID: id) }
        tabBar.onNew = { [weak self] in self?.promptNewTab() }
    }

    // MARK: Window

    func show() {
        window.makeKeyAndOrderFront(nil)
        // Measured again now that the window has actually been put on screen: at
        // `init` time the theme frame may not have laid the buttons out yet and
        // the inset would have come from the fallback. Free when it agrees —
        // `leadingInset` doesn't touch the constraint unless the number moved.
        tabBar.leadingInset = trafficLightInset
        activeSession?.focusInput()
    }

    /// Nudge a window that's already open — used when a world you asked for
    /// turns out to be open in some other window already.
    func bringToFront() {
        window.makeKeyAndOrderFront(nil)
    }

    var isKeyWindow: Bool { window.isKeyWindow }

    /// Offset each new window from the last so they don't land in a single pile.
    func cascade(from previous: WorldWindow?) {
        guard let previous = previous else { return }
        let origin = previous.window.frame.origin
        window.setFrameTopLeftPoint(
            NSPoint(x: origin.x + 24,
                    y: origin.y + previous.window.frame.height - 24))
    }

    /// How far in from the leading edge the tabs have to start to clear the
    /// traffic lights.
    ///
    /// Measured rather than guessed: the buttons' size and spacing have changed
    /// across macOS releases, and a number baked in here would put the first tab
    /// under the zoom button the next time they change. The fallback is what
    /// they measure today, so if the theme frame hasn't laid itself out yet the
    /// bar still starts in the right place rather than in the corner.
    private var trafficLightInset: CGFloat {
        // Full screen takes the traffic lights away along with the rest of the
        // title bar, so there's nothing left to clear and the gap they needed
        // would just be a hole in the corner. Checked here rather than at the
        // call sites so every caller gets it right, including the delegate
        // callbacks below — the mask is already updated by the time those run.
        guard !window.styleMask.contains(.fullScreen) else { return 6 }
        guard let zoom = window.standardWindowButton(.zoomButton) else { return 72 }
        // `to: nil` converts to *window* coordinates, which is what the bar's
        // leading edge is measured in too — the buttons aren't in the content
        // view's hierarchy at all, so there's no shared superview to go via.
        //
        // Floored rather than trusted outright. A button the theme frame hasn't
        // positioned yet still measures its *intrinsic* size sitting at the
        // origin, so it reports a maxX in the teens — a plausible-looking number
        // rather than an obviously wrong zero, which would put the first tab
        // squarely under the minimise button. The floor is what they measure
        // today, so a bad reading costs a few points of gap and a good one is
        // always larger than it anyway.
        return max(72, zoom.convert(zoom.bounds, to: nil).maxX + 12)
    }

    // MARK: Tabs

    /// Open a world in a new tab and switch to it. The caller has already made
    /// sure this world isn't open somewhere else.
    @discardableResult
    func addTab(world: WorldConfig) -> Session {
        let session = Session(world: world)
        session.onChange = { [weak self] in self?.refreshTabs() }
        sessions.append(session)
        session.start()
        selectTab(at: sessions.count - 1)
        return session
    }

    /// `claimingCurrentWorld` says whether this tab's world should become *the*
    /// current world app-wide. True for anything the user did on purpose — a
    /// click, ⌘T, opening a world from the Worlds menu. False when a window is
    /// merely tidying up after a deletion somewhere else, because there is only
    /// one current world and a background window has no business naming it.
    func selectTab(at index: Int, claimingCurrentWorld: Bool = true) {
        guard sessions.indices.contains(index) else { return }
        activeIndex = index
        showActiveSession()
        // Straight to the redraw rather than through the coalescing path: you
        // just clicked, and the highlight should move under your finger.
        redrawTabs()
        // Keep the store's idea of the current world matched to the frontmost
        // tab, so Rename / Delete / the Worlds window all act on what you're
        // actually looking at.
        if claimingCurrentWorld, let session = activeSession {
            WorldStore.shared.select(id: session.worldID)
        }
    }

    /// Whether moving between tabs would go anywhere. Asked by the Window menu,
    /// which greys its Next / Previous items out when it wouldn't — and asked as
    /// this rather than by counting `sessions` from outside, so the one place
    /// that knows how many tabs there are is still the one that says.
    var hasMultipleTabs: Bool { sessions.count > 1 }

    /// ⌃⇥ — the tab to the right, wrapping round to the first from the last.
    func selectNextTab() {
        selectAdjacentTab(by: 1)
    }

    /// ⌃⇧⇥ — the tab to the left, wrapping round to the last from the first.
    func selectPreviousTab() {
        selectAdjacentTab(by: -1)
    }

    /// The arithmetic lives here, beside the array it indexes, rather than in
    /// the menu action. `sessions` and `activeIndex` are this window's own
    /// business; handing them out so a caller could add one to an index would
    /// make every caller responsible for the wrap.
    private func selectAdjacentTab(by offset: Int) {
        let count = sessions.count
        // With one tab you're already on it, and re-selecting would tear the
        // session view down and build it back for no visible change.
        guard count > 1 else { return }
        // `+ count` before the remainder because Swift's `%` keeps the sign of
        // the left-hand side: -1 % 3 is -1, not 2, and there is no such index.
        selectTab(at: (activeIndex + offset + count) % count)
    }

    /// The index of the tab showing a given world, if this window has one.
    func indexOfTab(worldID: String) -> Int? {
        sessions.firstIndex { $0.worldID == worldID }
    }

    private func selectTab(worldID: String) {
        guard let index = indexOfTab(worldID: worldID) else { return }
        selectTab(at: index)
    }

    private func closeTab(worldID: String) {
        guard let index = indexOfTab(worldID: worldID) else { return }
        closeTab(at: index)
    }

    func closeTab(at index: Int) {
        guard sessions.indices.contains(index) else { return }
        // The last tab isn't closeable — closing it would leave an empty window
        // with no way to put anything back in it. Close the window instead.
        guard sessions.count > 1 else { return }

        let session = sessions[index]
        if session.isConnected {
            let alert = NSAlert()
            alert.messageText = "Close “\(session.title)” while connected?"
            alert.informativeText = "You're still connected. Closing this tab disconnects it and closes its log."
            alert.addButton(withTitle: "Close Tab")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        // Find the tab again, by identity. `runModal` runs an event loop of its
        // own, so anything that reshuffles the tabs — a world deleted in
        // Settings, a window sync — can have happened while the sheet was up,
        // and the number we came in with may now name a different session
        // entirely. Everything below uses `current`, never `index`.
        guard let current = sessions.firstIndex(where: { $0 === session }),
              sessions.count > 1 else { return }

        let wasActive = (current == activeIndex)
        session.disconnect()
        session.isFrontmost = false
        session.onChange = nil
        session.view.removeFromSuperview()
        sessions.remove(at: current)

        if wasActive {
            // Land on the neighbour, the way every other tabbed app does — the
            // tab to the left if you closed the last one, otherwise the one
            // that slid into the gap.
            selectTab(at: min(current, sessions.count - 1))
        } else {
            // A *background* tab went away. Everything to its right just shifted
            // down one, so the active index has to follow — without this you get
            // yanked to a different world for closing a tab you weren't even
            // looking at, and the global world selection follows you there.
            if current < activeIndex { activeIndex -= 1 }
            redrawTabs()
        }
    }

    /// ⌘W: close the frontmost tab, or the whole window if it's the only one.
    func closeActiveTab() {
        if sessions.count > 1 {
            closeTab(at: activeIndex)
        } else {
            window.performClose(nil)
        }
    }

    func closeWindow() {
        window.performClose(nil)
    }

    private func showActiveSession() {
        for sub in container.subviews {
            sub.removeFromSuperview()
        }
        for (index, session) in sessions.enumerated() {
            session.isFrontmost = (index == activeIndex)
        }
        guard let session = activeSession else { return }

        let sessionView = session.view
        sessionView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sessionView)
        // Fresh constraints each swap: `removeFromSuperview()` above tore down
        // the previous set along with the view's place in the hierarchy.
        NSLayoutConstraint.activate([
            sessionView.topAnchor.constraint(equalTo: container.topAnchor),
            sessionView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sessionView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            sessionView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.title = "MacMUSH — \(session.title)"
        session.focusInput()
        // The one choke point for "which world is frontmost in this window":
        // selecting a tab, adding one and closing one all come through here.
        WindowManager.shared.activeSessionChanged()
    }

    /// Ask for the bar to be brought up to date, at most once per turn of the
    /// run loop.
    ///
    /// Every session calls this from `onChange`, which fires on every line it
    /// receives. A couple of busy worlds will ask dozens of times a second, and
    /// each ask re-solves the bar's layout. Collapsing them costs nothing you
    /// can see — a MUD line and the badge that counts it land in the same frame
    /// either way — and takes the layout engine out of the hot path.
    func refreshTabs() {
        guard !tabRefreshScheduled else { return }
        tabRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.tabRefreshScheduled = false
            self.redrawTabs()
        }
    }

    /// Redraw the bar from the sessions, now. Titles, connected dots and unread
    /// counts all come straight off the sessions, so nothing has to work out
    /// which tab it was that changed.
    private func redrawTabs() {
        let items = sessions.map {
            TabBarView.Item(id: $0.worldID,
                            title: $0.title,
                            isConnected: $0.isConnected,
                            unread: $0.unread)
        }
        tabBar.update(items: items, activeIndex: activeIndex)
        if let session = activeSession {
            window.title = "MacMUSH — \(session.title)"
        }
    }

    // MARK: The "+" picker

    /// A menu of every saved world, with the ones already open ticked and
    /// disabled — one world, one tab, app-wide. Also the quickest route to
    /// making a new world when you want a tab for something you haven't set up.
    func promptNewTab() {
        // `popUp` below runs a tracking loop, and a tracking loop runs the main
        // queue — so a second ⌘T, whose work is deferred by a turn of the run
        // loop, lands *inside* the first menu and stacks another on top of it.
        // The flag stays set for as long as the menu is up, because `popUp`
        // doesn't return until it comes down.
        guard !pickerPending else { return }
        pickerPending = true
        defer { pickerPending = false }

        let menu = NSMenu()
        // Off, or AppKit's automatic enabling would helpfully re-enable the
        // already-open worlds right back — this menu's target does implement
        // their action, it just doesn't want them picked.
        menu.autoenablesItems = false
        for world in WorldStore.shared.worlds {
            let item = menu.addItem(withTitle: world.name,
                                    action: #selector(pickWorld(_:)),
                                    keyEquivalent: "")
            item.target = self
            item.representedObject = world.id
            if WindowManager.shared.locate(worldID: world.id) != nil {
                item.state = .on
                item.isEnabled = false
            }
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let newItem = menu.addItem(withTitle: "New World…",
                                   action: #selector(newWorldForTab),
                                   keyEquivalent: "")
        newItem.target = self

        // Anchor under the "+", which is where you were already looking whether
        // you clicked it or pressed ⌘T.
        let anchor = tabBar.newButtonFrame
        _ = menu.popUp(positioning: nil,
                       at: NSPoint(x: anchor.minX, y: anchor.minY - 4),
                       in: tabBar)
    }

    @objc private func pickWorld(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let world = WorldStore.shared.worlds.first(where: { $0.id == id }) else { return }
        addTab(world: world)
    }

    @objc private func newWorldForTab() {
        guard let name = promptText(title: "New World",
                                    info: "Name this world. You can set its host and port with ⌘R after its tab opens.",
                                    defaultValue: "New World"),
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let world = WorldConfig(name: name)
        WorldStore.shared.insertWorld(world)
        addTab(world: world)
    }

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

    // MARK: Store changes

    /// Push edits from the Worlds window into every tab this window holds, and
    /// deal with any tab whose world has been deleted out from under it.
    func syncFromStore() {
        let worlds = WorldStore.shared.worlds
        func isOrphan(_ session: Session) -> Bool {
            !worlds.contains { $0.id == session.worldID }
        }

        for session in sessions {
            if let world = worlds.first(where: { $0.id == session.worldID }) {
                session.syncActiveWorld(world)
            }
        }

        guard sessions.contains(where: isOrphan) else { return }

        // Which tab you were on, held by identity rather than by number — the
        // removals below shuffle the indices out from under it.
        let previouslyActive = activeSession

        // Close the orphaned tabs, but a window has to keep at least one, so
        // stop before emptying it. Backwards, so removing doesn't shift the
        // indices still to come.
        for index in sessions.indices.reversed() where sessions.count > 1 {
            let session = sessions[index]
            guard isOrphan(session) else { continue }
            session.disconnect()
            session.isFrontmost = false
            session.onChange = nil
            session.view.removeFromSuperview()
            sessions.remove(at: index)
        }

        // If the survivor is itself an orphan it can't sit there showing a world
        // that no longer exists. Move it to a world nobody else has open — going
        // to whatever the store happens to have selected, as the single-window
        // version did, would usually land on a world that's already in a tab
        // somewhere, and two tabs on one world means two sockets logging in as
        // the same character and two loggers appending to the same file.
        if sessions.count == 1, let survivor = sessions.first, isOrphan(survivor) {
            if let replacement = WindowManager.shared.firstUnopenedWorld() {
                survivor.activate(world: replacement)
            } else {
                // Every remaining world is open elsewhere, so this window has
                // nothing left to show. `close()` rather than `performClose` —
                // there's no sense asking "close while connected?" about a world
                // that no longer exists.
                survivor.disconnect()
                window.close()
                return
            }
        }

        // Is this the window the menu bar is talking about? The store's
        // selection is one app-wide value, and this method runs in *every*
        // window — so without a test, whichever window the sync loop happens to
        // reach last re-points the current world at its own front tab, and the
        // Rename / Delete Current World you then run in the window you're
        // actually using acts on a world two monitors away. Visit order is no
        // way to decide what ⌘-Delete deletes.
        //
        // `isKeyWindow` is the tempting test and the wrong one. Worlds are
        // deleted from the Settings window, and while Settings is key *no* world
        // window is — so it would gate this off in precisely the case it exists
        // for, leaving the store naming one world while the last-used window
        // shows another. `activeWindow` is the same question the menu commands
        // themselves ask: the key window if there is one, otherwise the window
        // you were last using. At most one window can match, so the answer
        // doesn't depend on visit order either.
        let isCurrent = (WindowManager.shared.activeWindow === self)

        // Stay on the tab you were on if it's still here; otherwise fall back to
        // whatever now occupies the old slot.
        if let previous = previouslyActive,
           let index = sessions.firstIndex(where: { $0 === previous }) {
            activeIndex = index
            redrawTabs()
            // The *session* survived, but the world inside it may not have: an
            // orphaned survivor was re-pointed at a replacement a few lines up,
            // and the store still names the world the tab used to show. Worlds ▸
            // Rename / Delete Current World would then quietly act on that one —
            // editing or destroying a world you aren't looking at.
            if isCurrent { WorldStore.shared.select(id: previous.worldID) }
        } else {
            // The claim has to be passed down, not left to `selectTab`: its
            // default is "the user asked for this", and this is the one caller
            // where that isn't true.
            selectTab(at: min(activeIndex, sessions.count - 1),
                      claimingCurrentWorld: isCurrent)
        }
    }

    /// Shut every session down cleanly — sockets closed, log footers written.
    func disconnectAll() {
        for session in sessions { session.disconnect() }
    }

    var hasConnectedSession: Bool {
        sessions.contains { $0.isConnected }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        WindowManager.shared.windowBecameKey(self)
        // Coming back to a window re-asserts its frontmost tab as the current
        // world, so the Worlds menu tick follows the window you're using.
        if let session = activeSession {
            WorldStore.shared.select(id: session.worldID)
        }
    }

    /// Going full screen takes the traffic lights away and coming back brings
    /// them back, so the tabs have to give up the corner and reclaim it. Both
    /// are the same line: `trafficLightInset` already knows which state it's in.
    func windowDidEnterFullScreen(_ notification: Notification) {
        tabBar.leadingInset = trafficLightInset
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        tabBar.leadingInset = trafficLightInset
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard hasConnectedSession else { return true }
        let live = sessions.filter { $0.isConnected }.map { $0.title }
        let alert = NSAlert()
        alert.messageText = live.count == 1
            ? "Close this window while connected to “\(live[0])”?"
            : "Close this window while connected to \(live.count) worlds?"
        alert.informativeText = live.count == 1
            ? "Closing disconnects and closes the session log."
            : "Closing disconnects \(live.joined(separator: ", ")) and closes their session logs."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        disconnectAll()
        for session in sessions {
            session.isFrontmost = false
            session.onChange = nil
        }
        WindowManager.shared.windowClosed(self)
    }
}
#endif

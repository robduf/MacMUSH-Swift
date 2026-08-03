// The row of world tabs across the top of a window.
//
// AppKit has native window tabs (NSWindow.tabbingMode), but they tab whole
// windows together and give you no say over what a tab looks like. A MUD client
// wants a connected light and an unread count on each tab, so this draws its
// own — a plain NSStackView of small custom views, which is far less machinery
// than it sounds like and behaves predictably.
//
// The bar is deliberately dumb: it knows titles, connected flags and unread
// counts, and reports clicks back by world id. `WorldWindow` owns the sessions
// and decides what any of it means.

#if canImport(AppKit)
import AppKit

/// One tab. Draws its own background, connected dot and unread badge; the title
/// and close box are real subviews so they can truncate and be clicked.
final class TabItemView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()

    private var isActive = false
    private var isConnected = false
    private var unread = 0
    private var canClose = true
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    /// Everything `draw(_:)` actually looks at, gathered up so a refresh can ask
    /// "would this paint differently?" before saying yes to a repaint.
    private struct Appearance: Equatable {
        var isActive = false
        var isConnected = false
        var unread = 0
        var isHovered = false
    }
    /// What the last repaint was asked for. The impossible unread count makes
    /// the first refresh always paint.
    private var drawn = Appearance(unread: -1)

    // Space reserved at the left for the connected dot. Reserved whether or not
    // the dot is showing, so titles don't jump sideways when you connect.
    private static let dotInset: CGFloat = 10
    private static let dotSize: CGFloat = 7

    init() {
        super.init(frame: .zero)

        titleLabel.font = NSFont.systemFont(ofSize: 12)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        closeButton.title = ""
        closeButton.isBordered = false
        closeButton.setButtonType(.momentaryChange)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.attributedTitle = NSAttributedString(
            string: "✕",
            attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        // Note the asymmetry with the tab body, which does accept a first mouse:
        // clicking a background window's tab switches to it, but clicking its
        // close box only brings the window forward. That's on purpose. Switching
        // tabs is free to get wrong; destroying a live session on a window you
        // weren't looking at is not.
        closeButton.toolTip = "Close tab"

        for sub in [titleLabel, closeButton] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: TabItemView.dotInset + TabItemView.dotSize + 5),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -3),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
            closeButton.heightAnchor.constraint(equalToConstant: 14),
        ])

        // The active tab is filled with `controlAccentColor`, and that colour is
        // not part of the appearance cache below — so change the accent in
        // System Settings and every tab would otherwise keep the old one, now
        // permanently, because the cache says nothing has changed. Not scoped to
        // the window, unlike the key-state observers: the setting is app-wide.
        //
        // Dark/light mode needs no equivalent. AppKit invalidates custom views
        // itself when the effective appearance changes.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accentColorChanged),
            name: NSColor.systemColorsDidChangeNotification,
            object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("TabItemView is code-only; it is never unarchived from a nib.")
    }

    @objc private func accentColorChanged() {
        // Clearing the cache matters as much as the redraw: nothing the cache
        // tracks has changed, so a `refresh()` arriving first would decide this
        // tab already looks right and cancel the repaint before it happened.
        drawn = Appearance(unread: -1)
        needsDisplay = true
    }

    func configure(title: String, isConnected: Bool, unread: Int, isActive: Bool, canClose: Bool) {
        // Guarded, because the bar is reconfigured on every line a world sends
        // and `stringValue` on an unchanged string still invalidates layout.
        if titleLabel.stringValue != title {
            titleLabel.stringValue = title
            toolTip = title
        }
        let titleColor: NSColor = isActive ? .labelColor : .secondaryLabelColor
        if titleLabel.textColor != titleColor { titleLabel.textColor = titleColor }
        self.isConnected = isConnected
        self.unread = unread
        self.isActive = isActive
        self.canClose = canClose
        refresh()
    }

    private func refresh() {
        // The close box replaces the unread badge on the tab you're pointing at,
        // which is the only time you can actually click it.
        let hideClose = !canClose || !(isActive || isHovered)
        if closeButton.isHidden != hideClose { closeButton.isHidden = hideClose }

        // Guarded, and it matters: this runs for every line every world sends.
        // Two busy tabs will ask dozens of times a second, and each yes means
        // re-filling a rounded rect, stroking it, and drawing a dot and a badge
        // — real battery, spent on a picture identical to the one already there.
        // The unread *count* is in here, so a genuinely new line still paints.
        let wanted = Appearance(isActive: isActive,
                                isConnected: isConnected,
                                unread: unread,
                                isHovered: isHovered)
        guard wanted != drawn else { return }
        drawn = wanted
        needsDisplay = true
    }

    // MARK: Hover

    /// The tracking area below is `.activeInKeyWindow`, which simply stops
    /// reporting when the window stops being key — it does not send a closing
    /// `mouseExited` on the way out. So the tab you happened to be pointing at
    /// when you clicked away stays lit, and keeps showing its close box *in
    /// place of its unread badge* — which is to say, the one tab whose traffic
    /// you'd most want counted is the one that won't count it. Recomputing on
    /// both edges of key-ness fixes that, and covers a modal alert for free,
    /// since the alert's own window takes key while it's up. Menu tracking is
    /// *not* covered — a menu leaves the key window alone — but it doesn't need
    /// to be: the tracking area keeps reporting either side of it, and
    /// `updateTrackingAreas` works the answer out from scratch regardless.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        guard let window = window else { return }
        center.addObserver(self, selector: #selector(keyStateChanged),
                           name: NSWindow.didResignKeyNotification, object: window)
        center.addObserver(self, selector: #selector(keyStateChanged),
                           name: NSWindow.didBecomeKeyNotification, object: window)
    }

    @objc private func keyStateChanged() {
        syncHover()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        syncHover()
    }

    /// Work out from scratch whether the pointer is over this tab.
    ///
    /// Tabs move under a stationary pointer — a tab to the left closes, the bar
    /// re-lays out — and AppKit sends no enter/exit event for that, because the
    /// *mouse* didn't go anywhere. Without this, the tab now under the pointer
    /// stays unhighlighted with no close box until you jiggle the mouse.
    private func syncHover() {
        let hovering: Bool
        if let window = window, window.isKeyWindow {
            let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            hovering = bounds.contains(local)
        } else {
            hovering = false
        }
        // Only touch anything on a real change: this runs during layout, and
        // hiding or showing the close box schedules another layout pass.
        guard hovering != isHovered else { return }
        isHovered = hovering
        refresh()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        refresh()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        refresh()
    }

    /// Click a tab in a window that isn't in front and it switches *and*
    /// selects, rather than eating the first click just to raise the window.
    /// That's what every other tab bar on the system does.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Both of these hand straight over to the bar rather than deferring the
    /// work here. Deferral and the one-at-a-time guard belong up there, where
    /// there is exactly one of them — see `TabBarView.runExclusively`.
    override func mouseDown(with event: NSEvent) {
        // The close button is a subview and swallows its own clicks before this
        // ever runs, so anywhere else on the tab means "switch to me".
        onSelect?()
    }

    @objc private func closeClicked() {
        onClose?()
    }

    // MARK: Drawing

    /// The dot is anchored to the middle and the badge to the right edge, so a
    /// resize moves both. Nothing else would have redrawn us for that.
    override func setFrameSize(_ newSize: NSSize) {
        // Guarded on an actual change, because AppKit hands the same size back
        // on every layout pass — and the bar re-lays out for every line every
        // world sends. Unguarded, this would repaint each tab dozens of times a
        // second and quietly undo the whole point of the check in `refresh()`.
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Clamped: the minimum width is a *preference*, not a requirement, so a
        // narrow window with a lot of tabs really can hand this a few points to
        // work with, and a negative-width rounded rect is not a shape.
        let body = NSRect(x: 1, y: 3,
                          width: max(0, bounds.width - 2),
                          height: max(0, bounds.height - 4))
        let path = NSBezierPath(roundedRect: body, xRadius: 6, yRadius: 6)

        if isActive {
            NSColor.controlAccentColor.withAlphaComponent(0.20).setFill()
            path.fill()
            path.lineWidth = 1
            NSColor.controlAccentColor.withAlphaComponent(0.45).setStroke()
            path.stroke()
        } else if isHovered {
            NSColor.separatorColor.withAlphaComponent(0.55).setFill()
            path.fill()
        }

        if isConnected {
            let dot = NSRect(x: TabItemView.dotInset,
                             y: bounds.midY - TabItemView.dotSize / 2,
                             width: TabItemView.dotSize,
                             height: TabItemView.dotSize)
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }

        // Unread only shows where the close box isn't: on a tab that is neither
        // frontmost nor under the pointer. Those are exactly the tabs whose
        // traffic you haven't seen.
        if unread > 0 && !isActive && !isHovered {
            drawUnreadBadge()
        }
    }

    private func drawUnreadBadge() {
        let text = unread > 99 ? "99+" : "\(unread)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let width = max(size.width + 9, 16)
        let pill = NSRect(x: max(0, bounds.width - width - 7),
                          y: bounds.midY - 7,
                          width: width,
                          height: 14)
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 7, yRadius: 7).fill()
        (text as NSString).draw(
            at: NSPoint(x: pill.midX - size.width / 2, y: pill.midY - size.height / 2),
            withAttributes: attributes)
    }
}

/// The whole bar: tabs, then a "+" that opens another world.
final class TabBarView: NSView {
    struct Item {
        /// The world's id. Clicks report this rather than a position, so a tab
        /// closing elsewhere can't make a pending click land on the wrong world.
        var id: String
        var title: String
        var isConnected: Bool
        var unread: Int

        init(id: String, title: String, isConnected: Bool = false, unread: Int = 0) {
            self.id = id
            self.title = title
            self.isConnected = isConnected
            self.unread = unread
        }
    }

    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    var onNew: (() -> Void)?

    static let barHeight: CGFloat = 32

    private let stack = NSStackView()
    private let addButton = NSButton()
    // Soaks up the space to the right of the "+" so the tabs stay left-aligned
    // instead of spreading across the whole window.
    private let spacer = NSView()
    /// The live tab views, in bar order. Kept and reconfigured rather than
    /// rebuilt — see `update(items:activeIndex:)`.
    private var tabViews: [TabItemView] = []
    /// Set between a click landing anywhere on the bar and its handler
    /// returning. One flag for the whole bar — see `runExclusively`.
    private var actionPending = false
    /// The stack's leading constraint, held so `leadingInset` can move it.
    private var stackLeading: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        addButton.title = ""
        addButton.isBordered = false
        addButton.setButtonType(.momentaryChange)
        addButton.target = self
        addButton.action = #selector(newClicked)
        addButton.attributedTitle = NSAttributedString(
            string: "+",
            attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        addButton.toolTip = "Open another world in a new tab"

        // NSStackView turns this off for its arranged subviews anyway; setting
        // it here as well costs nothing and doesn't depend on that.
        addButton.translatesAutoresizingMaskIntoConstraints = false
        spacer.translatesAutoresizingMaskIntoConstraints = false

        // A `.fill` stack stretches whichever arranged view is least reluctant
        // to grow. Pinning the spacer's hugging to the floor says: take the
        // slack out of me, not out of a tab.
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(1), for: .horizontal)

        // Added once, and every tab is inserted *before* them, so the "+" always
        // sits immediately after the last tab with the slack to its right.
        stack.addArrangedSubview(addButton)
        stack.addArrangedSubview(spacer)

        // Held rather than dropped: the window moves it to clear the traffic
        // lights as soon as it has one. See `leadingInset`.
        let leading = stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6)
        stackLeading = leading

        NSLayoutConstraint.activate([
            leading,
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 26),
            addButton.heightAnchor.constraint(equalToConstant: 24),
            // The spacer has no content of its own, so without these its size is
            // ambiguous. The width floor matters more than it looks: without it
            // the solver is free to give the spacer a *negative* width, which it
            // will happily do rather than break the tabs' preferred widths — and
            // then the "+" is pushed off the right-hand end of the bar, where it
            // can be neither seen nor clicked.
            //
            // 44 rather than 0 because the bar is the title bar now, and the
            // spacer is the only part of it that isn't a tab or the "+". Tabs
            // take their own clicks without dragging — that's deliberate, since
            // dragging a tab on a Mac reorders it — so if the spacer ever
            // collapses to nothing there is no longer anywhere to grab the
            // window by its top edge, and it can't be moved at all. Safe to
            // require: a tab's minimum width is priority 700, so the solver
            // squeezes tabs to keep this rather than giving up.
            spacer.heightAnchor.constraint(equalToConstant: 1),
            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("TabBarView is code-only; it is never unarchived from a nib.")
    }

    /// How far in from the leading edge the first tab starts.
    ///
    /// The bar sits *in* the title bar, so the traffic lights float over its
    /// left-hand end and the tabs have to begin clear of them. The window is
    /// what sets this, because the buttons belong to it and not to the bar —
    /// and it sets it back to an ordinary margin in full screen, where there
    /// are no buttons to clear and the gap would just be a hole in the corner.
    var leadingInset: CGFloat {
        get { stackLeading?.constant ?? 0 }
        set {
            guard let constraint = stackLeading, constraint.constant != newValue else { return }
            constraint.constant = newValue
        }
    }

    /// Bring the bar in line with `items`. Items and the active index arrive
    /// together so the bar is never drawn from a half-updated pair.
    ///
    /// Tab views are reused, not rebuilt. This gets called every time a world
    /// sends a line — tens of times a second across a few busy tabs — and
    /// tearing the views down each time would drop the hover highlight out from
    /// under the pointer, and could destroy the close button *mid-click*, which
    /// silently swallows it: `NSControl.target` is a zeroing weak reference, so
    /// a button whose owner has gone away simply does nothing on mouse-up.
    func update(items: [Item], activeIndex: Int) {
        while tabViews.count > items.count {
            let extra = tabViews.removeLast()
            stack.removeArrangedSubview(extra)
            extra.removeFromSuperview()
        }
        while tabViews.count < items.count {
            let tab = TabItemView()
            tab.translatesAutoresizingMaskIntoConstraints = false
            // Read before the append below, so the very first tab sees nil here
            // rather than finding itself and being told to match its own width.
            // Tabs only ever leave from the end, so tab zero is the one view in
            // the bar guaranteed to outlive the rest — which is what makes it
            // safe to use as everyone's yardstick.
            let yardstick = tabViews.first
            // Before the "+" and the spacer, which are always the last two.
            stack.insertArrangedSubview(tab, at: tabViews.count)
            tabViews.append(tab)

            // Preferred width yields before the minimum does, so a windowful of
            // tabs gives up its slack before any tab is crushed. The minimum is
            // deliberately *not* required: past a dozen tabs in a 900pt window
            // there is no width that satisfies it, and a required constraint in
            // that spot means a page of layout complaints in the console and a
            // bar the engine has given up on.
            let preferred = tab.widthAnchor.constraint(equalToConstant: 165)
            preferred.priority = NSLayoutConstraint.Priority(500)
            let minimum = tab.widthAnchor.constraint(greaterThanOrEqualToConstant: 74)
            minimum.priority = NSLayoutConstraint.Priority(700)
            NSLayoutConstraint.activate([
                preferred,
                minimum,
                tab.heightAnchor.constraint(equalToConstant: TabBarView.barHeight - 2),
            ])

            // Every tab the same width as the first. Not decoration: without it
            // the bar is genuinely ambiguous once the tabs have to share. The
            // engine minimises a weighted sum of *absolute* errors, so every way
            // of splitting the available width between N tabs that each want 165
            // scores exactly the same total, and it returns whichever of those
            // equally-good answers it reaches first — visibly lopsided past
            // about five tabs, and re-shuffling the survivors when an unrelated
            // tab closes. Priority 600 puts this above the 165 preference and
            // below the 74 floor, and the engine settles each priority level in
            // turn, so this is what breaks the tie at every level rather than
            // fighting the levels either side of it.
            if let yardstick = yardstick {
                let even = tab.widthAnchor.constraint(equalTo: yardstick.widthAnchor)
                even.priority = NSLayoutConstraint.Priority(600)
                even.isActive = true
            }
        }

        for (index, item) in items.enumerated() {
            let tab = tabViews[index]
            tab.configure(title: item.title,
                          isConnected: item.isConnected,
                          unread: item.unread,
                          isActive: index == activeIndex,
                          canClose: items.count > 1)
            // The id is captured, never the position. By the time a deferred
            // click runs, the tab it belongs to may have moved.
            let id = item.id
            tab.onSelect = { [weak self] in self?.requestSelect(id: id) }
            tab.onClose = { [weak self] in self?.requestClose(id: id) }
        }
    }

    // MARK: Clicks

    private func requestSelect(id: String) {
        runExclusively { [weak self] in self?.onSelect?(id) }
    }

    private func requestClose(id: String) {
        runExclusively { [weak self] in self?.onClose?(id) }
    }

    /// Run a click handler one turn of the run loop later, and only one at a
    /// time across the whole bar.
    ///
    /// Deferred because the handlers reach back into the window and can remove
    /// the very tab that was clicked, and doing that while `mouseDown` or a
    /// button's own action is still on the stack is how you get a crash that
    /// only shows up sometimes.
    ///
    /// One at a time because these handlers put up modal alerts and menus, and
    /// both of those run the main queue while they wait. Without the guard, a
    /// second click's block fires *inside* the first one's alert and stacks a
    /// second alert on top of it. The flag lives on the bar rather than on a
    /// tab quite deliberately: per-tab it would catch a double-click on one ✕
    /// and miss ✕-on-one-tab-then-✕-on-another, or ✕-then-"+", which are the
    /// same bug arriving by a different route. There is one bar, so there is
    /// one flag. It stays set until the handler returns — clearing it any
    /// earlier would let exactly what it guards against straight through.
    private func runExclusively(_ handler: @escaping () -> Void) {
        guard !actionPending else { return }
        actionPending = true
        DispatchQueue.main.async { [weak self] in
            handler()
            self?.actionPending = false
        }
    }

    /// Where the "+" sits, in this bar's own coordinates, so the window can pop
    /// its world picker up underneath it.
    var newButtonFrame: NSRect {
        addButton.convert(addButton.bounds, to: self)
    }

    @objc private func newClicked() {
        // Through the same gate as the tabs, and for one reason of its own on
        // top: this pops up a menu, `popUp` doesn't return until the menu comes
        // down, and running a tracking loop from inside a button's own action
        // is asking for trouble.
        runExclusively { [weak self] in self?.onNew?() }
    }

    /// A click that lands on an inactive window normally does nothing but bring
    /// it forward, and the drag that follows is thrown away — which for a real
    /// title bar would be wrong, and this is a real title bar. Without this you
    /// can't move a background world window by its top edge until you've
    /// clicked it once, let go, and grabbed it again. `TabItemView` says the
    /// same thing for the same reason.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Anything that reaches the bar itself landed on the empty strip beside
    /// the tabs — and that strip is title bar now, so it has to behave like
    /// one.
    ///
    /// This isn't belt-and-braces. A full-size content view runs the content up
    /// *under* the title bar rather than starting below it, and the empty space
    /// up there stops being a drag handle the moment you do that: without this
    /// the window could no longer be moved by its top edge at all. Tabs and the
    /// "+" are subviews and take their own clicks long before this runs.
    override func mouseDown(with event: NSEvent) {
        guard let window = window else { return }
        if event.clickCount == 2 {
            // Whatever System Settings' "double-click a window's title bar to"
            // is set to. The key is absent until it's changed away from the
            // default, which is why the fallback zooms.
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize" {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.performZoom(nil)
            }
            return
        }
        window.performDrag(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        // The bar paints its own background rather than letting the window's
        // show through, because it *is* the title bar: with a transparent
        // titlebar over a full-size content view, anything this doesn't cover
        // is whatever the window happens to be filled with, and the strip would
        // drift out of step with the rest of the chrome the moment either
        // changed. `dirtyRect` rather than `bounds` — repainting one tab's worth
        // of strip has no business repainting the whole width of it.
        Theme.chrome.setFill()
        dirtyRect.fill()

        // A hairline under the bar, to separate it from the scrollback. Filled
        // rather than stroked, and one *device* pixel tall: a 1pt stroke covers
        // two rows of pixels on a Retina display, which reads as a soft grey
        // smudge rather than a line.
        let thickness = 1.0 / (window?.backingScaleFactor ?? 1.0)
        NSColor.separatorColor.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: bounds.width, height: thickness)).fill()
    }
}
#endif

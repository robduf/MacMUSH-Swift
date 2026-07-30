#if canImport(AppKit)
import AppKit
import MudEngine

/// The Worlds window: a sidebar listing every saved world, plus — for whichever
/// one you select — its connection details and editable trigger / alias / timer
/// tables. Code-only AppKit, no storyboards.
///
/// Two rules keep this honest:
///
/// 1. Edits are written straight through to `WorldStore` (there is no Save
///    button), matched **by world id**, so editing "Beta" here can never
///    scribble over whichever world happens to be live.
/// 2. The sidebar selection is only an editing cursor. It does *not* change the
///    active world — clicking around in here must never drop your connection.
///    "Make Active" is the explicit way to switch, and it goes through
///    `onActivateWorld`.
final class SettingsWindow: NSObject, NSWindowDelegate, NSTableViewDataSource,
                            NSTableViewDelegate, NSTextFieldDelegate, NSTextViewDelegate {

    /// Invoked when the user asks to make the world they're editing the live one.
    var onActivateWorld: ((WorldConfig) -> Void)?

    private let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 780, height: 500),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false)

    // Sidebar
    private let worldsTable = NSTableView()
    private let worldButtons = NSSegmentedControl(labels: ["+", "−"], trackingMode: .momentary,
                                                  target: nil, action: nil)

    // Connection pane
    private let nameField = NSTextField()
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let connectScroll = NSScrollView()
    private let connectTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 96))
    private let makeActiveButton = NSButton(title: "Make Active", target: nil, action: nil)
    private let activeLabel = NSTextField(labelWithString: "")

    // Rule panes
    private let triggersTable = NSTableView()
    private let aliasesTable = NSTableView()
    private let timersTable = NSTableView()

    // Working copy of the store, plus which world the right-hand panes show.
    private var worlds: [WorldConfig] = []
    private var editingID: String?

    /// Set while we are the ones writing to the store, so our own change
    /// notification doesn't reload the tables out from under a live edit.
    private var isCommitting = false

    /// Which of the three rule tables a control belongs to. The raw values are
    /// used as the first half of every cell identifier ("trg.pattern").
    private enum Kind: String {
        case trigger = "trg"
        case alias = "als"
        case timer = "tmr"

        var hint: String {
            switch self {
            case .trigger:
                return "Patterns match incoming lines. * is a wildcard; %1…%9 insert the wildcards into Send."
            case .alias:
                return "Patterns match what you type. * is a wildcard; %1…%9 insert the wildcards into Send."
            case .timer:
                return "Fires every N seconds while connected. Tick Once to fire a single time."
            }
        }
    }

    override init() {
        super.init()
        configure()
        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged),
            name: .worldStoreDidChange, object: nil)
    }

    // MARK: Presentation

    func show() {
        reloadFromStore()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(worldsTable)
    }

    func windowWillClose(_ notification: Notification) {
        // Force any in-progress field edit to commit before we go away.
        window.makeFirstResponder(nil)
        commitConnectText()
    }

    // MARK: Build

    private func configure() {
        window.title = "Worlds"
        window.minSize = NSSize(width: 700, height: 420)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        configureSidebar()
        configureConnectionPane()
        configureRuleTable(triggersTable, kind: .trigger)
        configureRuleTable(aliasesTable, kind: .alias)
        configureRuleTable(timersTable, kind: .timer)
        layout()
    }

    private func configureSidebar() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.title = "World"
        column.width = 170
        column.minWidth = 100
        worldsTable.addTableColumn(column)
        worldsTable.headerView = nil
        worldsTable.rowHeight = 22
        worldsTable.allowsMultipleSelection = false
        worldsTable.allowsColumnSelection = false
        worldsTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        worldsTable.dataSource = self
        worldsTable.delegate = self

        worldButtons.segmentStyle = .smallSquare
        worldButtons.target = self
        worldButtons.action = #selector(worldSegment(_:))
    }

    private func configureConnectionPane() {
        for (field, placeholder) in [(nameField, "My World"),
                                     (hostField, "mud.example.org"),
                                     (portField, "4000")] {
            field.placeholderString = placeholder
            field.delegate = self
            field.target = self
            field.action = #selector(cellEdited(_:))
            field.usesSingleLineMode = true
        }
        nameField.identifier = NSUserInterfaceItemIdentifier("conn.name")
        hostField.identifier = NSUserInterfaceItemIdentifier("conn.host")
        portField.identifier = NSUserInterfaceItemIdentifier("conn.port")

        connectScroll.hasVerticalScroller = true
        connectScroll.borderType = .bezelBorder
        connectScroll.drawsBackground = true

        connectTextView.minSize = NSSize(width: 0, height: 0)
        connectTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                         height: CGFloat.greatestFiniteMagnitude)
        connectTextView.isVerticallyResizable = true
        connectTextView.isHorizontallyResizable = false
        connectTextView.autoresizingMask = [.width]
        connectTextView.isRichText = false
        connectTextView.isAutomaticQuoteSubstitutionEnabled = false
        connectTextView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        connectTextView.textContainer?.containerSize = NSSize(width: 420,
                                                              height: CGFloat.greatestFiniteMagnitude)
        connectTextView.textContainer?.widthTracksTextView = true
        connectTextView.delegate = self
        connectScroll.documentView = connectTextView

        makeActiveButton.bezelStyle = .rounded
        makeActiveButton.target = self
        makeActiveButton.action = #selector(makeActive)

        activeLabel.font = NSFont.systemFont(ofSize: 11)
        activeLabel.textColor = .secondaryLabelColor
    }

    private func configureRuleTable(_ table: NSTableView, kind: Kind) {
        switch kind {
        case .trigger:
            addColumn(table, "enabled", "On", width: 30, minWidth: 30)
            addColumn(table, "pattern", "Pattern", width: 190)
            addColumn(table, "gag", "Gag", width: 36, minWidth: 36)
            addColumn(table, "regex", "Regex", width: 46, minWidth: 46)
            addColumn(table, "send", "Send", width: 200)
        case .alias:
            addColumn(table, "enabled", "On", width: 30, minWidth: 30)
            addColumn(table, "pattern", "Pattern", width: 190)
            addColumn(table, "regex", "Regex", width: 46, minWidth: 46)
            addColumn(table, "send", "Send", width: 236)
        case .timer:
            addColumn(table, "enabled", "On", width: 30, minWidth: 30)
            addColumn(table, "seconds", "Seconds", width: 66, minWidth: 56)
            addColumn(table, "once", "Once", width: 42, minWidth: 42)
            addColumn(table, "send", "Send", width: 354)
        }
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.allowsColumnSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
    }

    private func addColumn(_ table: NSTableView, _ id: String, _ title: String,
                           width: CGFloat, minWidth: CGFloat = 60) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.width = width
        column.minWidth = minWidth
        table.addTableColumn(column)
    }

    // MARK: Layout

    private func layout() {
        let content = NSView()

        let sidebarScroll = NSScrollView()
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.borderType = .bezelBorder
        sidebarScroll.documentView = worldsTable

        let tabView = NSTabView()
        tabView.addTabViewItem(makeTab("Connection", connectionPane()))
        tabView.addTabViewItem(makeTab("Triggers", rulePane(triggersTable, kind: .trigger)))
        tabView.addTabViewItem(makeTab("Aliases", rulePane(aliasesTable, kind: .alias)))
        tabView.addTabViewItem(makeTab("Timers", rulePane(timersTable, kind: .timer)))

        for view in [sidebarScroll, worldButtons, tabView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            sidebarScroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            sidebarScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            sidebarScroll.widthAnchor.constraint(equalToConstant: 180),

            worldButtons.topAnchor.constraint(equalTo: sidebarScroll.bottomAnchor, constant: 6),
            worldButtons.leadingAnchor.constraint(equalTo: sidebarScroll.leadingAnchor),
            worldButtons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),

            tabView.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            tabView.leadingAnchor.constraint(equalTo: sidebarScroll.trailingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])

        window.contentView = content
    }

    private func makeTab(_ label: String, _ view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: label)
        item.label = label
        item.view = view
        return item
    }

    private func connectionPane() -> NSView {
        let pane = NSView()

        let nameLabel = formLabel("Name:")
        let hostLabel = formLabel("Host:")
        let portLabel = formLabel("Port:")
        let sendLabel = formLabel("On connect, send:")
        sendLabel.alignment = .left

        for view in [nameLabel, hostLabel, portLabel, sendLabel,
                     nameField, hostField, portField, connectScroll,
                     makeActiveButton, activeLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            pane.addSubview(view)
        }

        let labelWidth: CGFloat = 46

        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: pane.topAnchor, constant: 18),
            nameLabel.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 14),
            nameLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            nameField.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            nameField.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            nameField.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -14),

            hostLabel.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 12),
            hostLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            hostLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            hostField.centerYAnchor.constraint(equalTo: hostLabel.centerYAnchor),
            hostField.leadingAnchor.constraint(equalTo: hostLabel.trailingAnchor, constant: 8),

            portLabel.centerYAnchor.constraint(equalTo: hostLabel.centerYAnchor),
            portLabel.leadingAnchor.constraint(equalTo: hostField.trailingAnchor, constant: 12),
            portLabel.widthAnchor.constraint(equalToConstant: 34),
            portField.centerYAnchor.constraint(equalTo: hostLabel.centerYAnchor),
            portField.leadingAnchor.constraint(equalTo: portLabel.trailingAnchor, constant: 6),
            portField.widthAnchor.constraint(equalToConstant: 72),
            portField.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -14),

            sendLabel.topAnchor.constraint(equalTo: hostField.bottomAnchor, constant: 16),
            sendLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),

            connectScroll.topAnchor.constraint(equalTo: sendLabel.bottomAnchor, constant: 6),
            connectScroll.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            connectScroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -14),
            connectScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 90),

            makeActiveButton.topAnchor.constraint(equalTo: connectScroll.bottomAnchor, constant: 12),
            makeActiveButton.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            makeActiveButton.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -14),

            activeLabel.centerYAnchor.constraint(equalTo: makeActiveButton.centerYAnchor),
            activeLabel.leadingAnchor.constraint(equalTo: makeActiveButton.trailingAnchor, constant: 10),
            activeLabel.trailingAnchor.constraint(lessThanOrEqualTo: pane.trailingAnchor, constant: -14),
        ])

        return pane
    }

    private func rulePane(_ table: NSTableView, kind: Kind) -> NSView {
        let pane = NSView()

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .bezelBorder
        scroll.documentView = table

        let buttons = NSSegmentedControl(labels: ["+", "−"], trackingMode: .momentary,
                                         target: self, action: #selector(ruleSegment(_:)))
        buttons.segmentStyle = .smallSquare
        buttons.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)

        let hint = NSTextField(labelWithString: kind.hint)
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail

        for view in [scroll, buttons, hint] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            pane.addSubview(view)
        }

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: pane.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -12),

            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            buttons.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 12),
            buttons.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -12),

            hint.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            hint.leadingAnchor.constraint(equalTo: buttons.trailingAnchor, constant: 10),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: pane.trailingAnchor, constant: -12),
        ])

        return pane
    }

    private func formLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        label.font = NSFont.systemFont(ofSize: 12)
        return label
    }

    // MARK: Working copy

    private var editingIndex: Int? {
        guard let id = editingID else { return worlds.isEmpty ? nil : 0 }
        return worlds.firstIndex(where: { $0.id == id })
    }

    private var editingWorld: WorldConfig? {
        guard let i = editingIndex else { return nil }
        return worlds[i]
    }

    @objc private func storeChanged() {
        guard !isCommitting else { return }
        reloadFromStore()
    }

    private func reloadFromStore() {
        worlds = WorldStore.shared.worlds
        if editingID == nil || !worlds.contains(where: { $0.id == editingID }) {
            editingID = WorldStore.shared.selectedWorldID ?? worlds.first?.id
        }
        worldsTable.reloadData()
        if let i = editingIndex {
            worldsTable.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        }
        loadEditingWorld()
    }

    private func loadEditingWorld() {
        guard let world = editingWorld else { return }
        nameField.stringValue = world.name
        hostField.stringValue = world.host
        portField.stringValue = "\(world.port)"
        connectTextView.string = world.connectText
        updateActiveLabel()
        triggersTable.reloadData()
        aliasesTable.reloadData()
        timersTable.reloadData()
    }

    private func updateActiveLabel() {
        guard let world = editingWorld else { return }
        let isLive = world.id == WorldStore.shared.selectedWorldID
        activeLabel.stringValue = isLive
            ? "This is the active world."
            : "The main window is showing a different world."
        makeActiveButton.isEnabled = !isLive
    }

    /// Write the working copy of one world through to the store, without letting
    /// the resulting notification reload the pane we're editing.
    private func commitWorld(at index: Int) {
        guard index >= 0, index < worlds.count else { return }
        isCommitting = true
        WorldStore.shared.update(worlds[index])
        isCommitting = false
    }

    // MARK: Table data

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === worldsTable { return worlds.count }
        guard let kind = kind(for: tableView), let world = editingWorld else { return 0 }
        switch kind {
        case .trigger: return world.triggers.count
        case .alias: return world.aliases.count
        case .timer: return world.timers.count
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let columnID = tableColumn?.identifier.rawValue else { return nil }

        if tableView === worldsTable {
            guard row < worlds.count else { return nil }
            return textCell(tableView, identifier: "world.name", value: worlds[row].name)
        }

        guard let kind = kind(for: tableView), let world = editingWorld else { return nil }
        let identifier = "\(kind.rawValue).\(columnID)"

        switch kind {
        case .trigger, .alias:
            let rules = kind == .trigger ? world.triggers : world.aliases
            guard row < rules.count else { return nil }
            let rule = rules[row]
            switch columnID {
            case "enabled": return checkCell(tableView, identifier: identifier, on: rule.enabled)
            case "pattern": return textCell(tableView, identifier: identifier, value: rule.pattern)
            case "send": return textCell(tableView, identifier: identifier, value: rule.sendText)
            case "gag": return checkCell(tableView, identifier: identifier, on: rule.gag)
            case "regex": return checkCell(tableView, identifier: identifier, on: rule.isRegex)
            default: return nil
            }
        case .timer:
            guard row < world.timers.count else { return nil }
            let timer = world.timers[row]
            switch columnID {
            case "enabled": return checkCell(tableView, identifier: identifier, on: timer.enabled)
            case "seconds": return textCell(tableView, identifier: identifier, value: secondsText(timer.seconds))
            case "send": return textCell(tableView, identifier: identifier, value: timer.sendText)
            case "once": return checkCell(tableView, identifier: identifier, on: timer.oneShot)
            default: return nil
            }
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView, table === worldsTable else { return }
        let row = worldsTable.selectedRow
        guard row >= 0, row < worlds.count else { return }
        guard worlds[row].id != editingID else { return }
        editingID = worlds[row].id
        loadEditingWorld()
    }

    // MARK: Cell factories

    private func textCell(_ table: NSTableView, identifier: String, value: String) -> NSTextField {
        let id = NSUserInterfaceItemIdentifier(identifier)
        let field: NSTextField
        if let reused = table.makeView(withIdentifier: id, owner: self) as? NSTextField {
            field = reused
        } else {
            field = NSTextField()
            field.identifier = id
            field.isBordered = false
            field.drawsBackground = false
            field.usesSingleLineMode = true
            field.lineBreakMode = .byTruncatingTail
            field.font = NSFont.systemFont(ofSize: 12)
            field.delegate = self
            field.target = self
            field.action = #selector(cellEdited(_:))
        }
        field.isEditable = true
        field.isSelectable = true
        field.stringValue = value
        return field
    }

    private func checkCell(_ table: NSTableView, identifier: String, on: Bool) -> NSButton {
        let id = NSUserInterfaceItemIdentifier(identifier)
        let box: NSButton
        if let reused = table.makeView(withIdentifier: id, owner: self) as? NSButton {
            box = reused
        } else {
            box = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkToggled(_:)))
            box.identifier = id
        }
        box.state = on ? .on : .off
        return box
    }

    private func kind(for table: NSTableView) -> Kind? {
        if table === triggersTable { return .trigger }
        if table === aliasesTable { return .alias }
        if table === timersTable { return .timer }
        return nil
    }

    private func ruleTable(for kind: Kind) -> NSTableView {
        switch kind {
        case .trigger: return triggersTable
        case .alias: return aliasesTable
        case .timer: return timersTable
        }
    }

    /// "60" rather than "60.0", but keep a real fraction if there is one.
    private func secondsText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds.magnitude < 1_000_000_000 else { return String(seconds) }
        return seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
    }

    // MARK: Editing

    @objc private func cellEdited(_ sender: NSTextField) {
        applyEdit(from: sender)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        applyEdit(from: field)
    }

    private func applyEdit(from field: NSTextField) {
        guard let raw = field.identifier?.rawValue else { return }
        let parts = raw.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let scope = parts[0]
        let key = parts[1]

        if scope == "conn" {
            applyConnectionEdit(key: key, field: field)
            return
        }

        if scope == "world" {
            let row = worldsTable.row(for: field)
            guard row >= 0, row < worlds.count else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { field.stringValue = worlds[row].name; return }
            guard worlds[row].name != name else { return }
            worlds[row].name = name
            commitWorld(at: row)
            if worlds[row].id == editingID { nameField.stringValue = name }
            return
        }

        guard let kind = Kind(rawValue: scope), let index = editingIndex else { return }
        let row = ruleTable(for: kind).row(for: field)
        guard row >= 0 else { return }
        applyRuleEdit(kind: kind, row: row, key: key, worldIndex: index, field: field)
    }

    private func applyConnectionEdit(key: String, field: NSTextField) {
        guard let i = editingIndex else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespaces)

        switch key {
        case "name":
            guard !value.isEmpty else { field.stringValue = worlds[i].name; return }
            guard worlds[i].name != value else { return }
            worlds[i].name = value
            commitWorld(at: i)
            worldsTable.reloadData()
            worldsTable.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        case "host":
            guard !value.isEmpty else { field.stringValue = worlds[i].host; return }
            guard worlds[i].host != value else { return }
            worlds[i].host = value
            commitWorld(at: i)
        case "port":
            guard let port = UInt16(value), port > 0 else {
                field.stringValue = "\(worlds[i].port)"
                return
            }
            guard worlds[i].port != port else { return }
            worlds[i].port = port
            commitWorld(at: i)
        default:
            break
        }
        updateActiveLabel()
    }

    private func applyRuleEdit(kind: Kind, row: Int, key: String, worldIndex i: Int, field: NSTextField) {
        let value = field.stringValue

        switch kind {
        case .trigger, .alias:
            var rules = kind == .trigger ? worlds[i].triggers : worlds[i].aliases
            guard row < rules.count else { return }
            switch key {
            case "pattern":
                guard rules[row].pattern != value else { return }
                rules[row].pattern = value
            case "send":
                guard rules[row].sendText != value else { return }
                rules[row].sendText = value
            default:
                return
            }
            if kind == .trigger { worlds[i].triggers = rules } else { worlds[i].aliases = rules }

        case .timer:
            guard row < worlds[i].timers.count else { return }
            switch key {
            case "seconds":
                let typed = Double(value.trimmingCharacters(in: .whitespaces))
                guard let seconds = typed, seconds.isFinite, seconds > 0, seconds <= 31_536_000 else {
                    field.stringValue = secondsText(worlds[i].timers[row].seconds)
                    return
                }
                guard worlds[i].timers[row].seconds != seconds else { return }
                worlds[i].timers[row].seconds = seconds
                field.stringValue = secondsText(seconds)
            case "send":
                guard worlds[i].timers[row].sendText != value else { return }
                worlds[i].timers[row].sendText = value
            default:
                return
            }
        }

        commitWorld(at: i)
    }

    @objc private func checkToggled(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue else { return }
        let parts = raw.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, let kind = Kind(rawValue: parts[0]), let i = editingIndex else { return }
        let key = parts[1]
        let row = ruleTable(for: kind).row(for: sender)
        guard row >= 0 else { return }
        let on = sender.state == .on

        switch kind {
        case .trigger, .alias:
            var rules = kind == .trigger ? worlds[i].triggers : worlds[i].aliases
            guard row < rules.count else { return }
            switch key {
            case "enabled": rules[row].enabled = on
            case "gag": rules[row].gag = on
            case "regex": rules[row].isRegex = on
            default: return
            }
            if kind == .trigger { worlds[i].triggers = rules } else { worlds[i].aliases = rules }

        case .timer:
            guard row < worlds[i].timers.count else { return }
            switch key {
            case "enabled": worlds[i].timers[row].enabled = on
            case "once": worlds[i].timers[row].oneShot = on
            default: return
            }
        }

        commitWorld(at: i)
    }

    func textDidEndEditing(_ notification: Notification) {
        commitConnectText()
    }

    private func commitConnectText() {
        guard let i = editingIndex else { return }
        let text = connectTextView.string
        guard worlds[i].connectText != text else { return }
        worlds[i].connectText = text
        commitWorld(at: i)
    }

    // MARK: Add / remove

    @objc private func ruleSegment(_ sender: NSSegmentedControl) {
        guard let raw = sender.identifier?.rawValue,
              let kind = Kind(rawValue: raw),
              let i = editingIndex else { return }
        let table = ruleTable(for: kind)

        if sender.selectedSegment == 0 {
            switch kind {
            case .trigger:
                worlds[i].triggers.append(MatchRule(pattern: "* tells you *", sendText: ""))
            case .alias:
                worlds[i].aliases.append(MatchRule(pattern: "gt * *", sendText: "give %2 to %1"))
            case .timer:
                worlds[i].timers.append(MudTimer(seconds: 60, sendText: ""))
            }
            commitWorld(at: i)
            table.reloadData()
            let last = table.numberOfRows - 1
            if last >= 0 {
                table.selectRowIndexes(IndexSet(integer: last), byExtendingSelection: false)
                table.scrollRowToVisible(last)
            }
        } else {
            let row = table.selectedRow
            guard row >= 0 else { return }
            switch kind {
            case .trigger:
                guard row < worlds[i].triggers.count else { return }
                worlds[i].triggers.remove(at: row)
            case .alias:
                guard row < worlds[i].aliases.count else { return }
                worlds[i].aliases.remove(at: row)
            case .timer:
                guard row < worlds[i].timers.count else { return }
                worlds[i].timers.remove(at: row)
            }
            commitWorld(at: i)
            table.reloadData()
        }
    }

    @objc private func worldSegment(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 { addWorld() } else { removeEditingWorld() }
    }

    private func addWorld() {
        let world = WorldConfig(name: uniqueName("New World"))
        isCommitting = true
        WorldStore.shared.insertWorld(world)
        isCommitting = false

        worlds = WorldStore.shared.worlds
        editingID = world.id
        worldsTable.reloadData()
        if let i = editingIndex {
            worldsTable.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
            worldsTable.scrollRowToVisible(i)
        }
        loadEditingWorld()
    }

    private func removeEditingWorld() {
        guard let i = editingIndex else { return }
        guard worlds.count > 1 else {
            let alert = NSAlert()
            alert.messageText = "Can’t delete your only world"
            alert.informativeText = "Add another world first, then delete this one."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let doomed = worlds[i]
        let alert = NSAlert()
        alert.messageText = "Delete “\(doomed.name)”?"
        alert.informativeText = "This removes the world and its triggers, aliases, and timers. This can’t be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Not suppressed: if this was the live world, the app delegate needs the
        // notification so the main window can move to the survivor.
        WorldStore.shared.removeWorld(id: doomed.id)

        worlds = WorldStore.shared.worlds
        editingID = worlds.isEmpty ? nil : worlds[min(i, worlds.count - 1)].id
        worldsTable.reloadData()
        if let next = editingIndex {
            worldsTable.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        }
        loadEditingWorld()
    }

    /// "New World", "New World 2", "New World 3"…
    private func uniqueName(_ base: String) -> String {
        let taken = Set(worlds.map { $0.name })
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    @objc private func makeActive() {
        guard let world = editingWorld else { return }
        onActivateWorld?(world)
        updateActiveLabel()
    }
}
#endif

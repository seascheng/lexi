import AppKit


/// Launcher panel — double-Shift spotlight surface. Empty query: the
/// folder grid (favorites / recents / Finder tags). Typed query: one
/// unified result list over folders + every installed app
/// (`LauncherAppIndex`), led by a calculator answer row when the query
/// parses as math (`CalcEngine`).
///
/// Top-level isolated from the toolbar/result-card/notes flows: it owns its
/// panel, data and actions. Shared bottom layers only: `KeyablePanel`,
/// `makePanelBackground`, `CardTheme`, `panelIcon`, `tagColor`, `FileLog`
/// (SelectionToolbarHelper.swift) and the TCP dispatch in
/// `SelectionToolbarApp.handleRequestData`. Search/filter logic lives in
/// `LauncherSearch.swift`, tagged-folder/recents persistence in
/// `LauncherFolders.swift`, cell/row view classes in `LauncherViews.swift`.
final class LauncherPanelController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {

    /// Fired whenever the panel hides itself (Esc / focus loss); the app
    /// controller wires this to its action channel ("launcher-hidden").
    var onHidden: (() -> Void)?
    /// Gear button in the chrome: opens the native settings window.
    var onOpenSettings: (() -> Void)?

    static let panelWidth: CGFloat = 640
    static let rowHeight: CGFloat = 44
    private static let headerHeight: CGFloat = 28
    private static let chipLineHeight: CGFloat = 40
    /// 12 result rows fit the 600pt panel cap exactly (48 chrome + 528 +
    /// 12 rim + slack) — keeps whole-row rendering at the fold.
    private static let maxListHeight: CGFloat = 528
    /// Panel frame padding: the same 12pt rim the other panels use, on
    /// every side (bottom included — the list never touches the edge).
    private static let bottomPad: CGFloat = 12
    /// Chrome is one line now — the search strip + gear, 8pt above the
    /// list (the Folders/Apps tabs folded into unified search).
    private static let chromeHeight: CGFloat = 12 + 28 + 8
    static let recentsKey = "launcher.recents"

    let panel: KeyablePanel
    private let root: FlippedView
    /// The makePanelBackground content view — scrimmed on theme changes so
    /// the glass keeps text contrast on dark wallpapers.
    private let glassContent: NSView
    let searchField = PanelSearchField()
    private let settingsButton = NSButton()
    private let scrollView = NSScrollView()
    let tableView = NSTableView()
    let emptyLabel = makePanelEmptyLabel()
    var cardTheme: CardTheme = .dark
    /// Installed-app search index (one background scan per process).
    let appIndex = LauncherAppIndex.shared
    /// The query's calculator answer when it parses as math — the
    /// leading result row.
    var calcValue: Double?

    enum Row {
        /// Header title + its Finder tag color (rendered as a leading
        /// dot; nil = fixed section, no dot).
        case header(String, NSColor?)
        case chipLine([FolderChip])
        /// Search-mode result: a folder or an installed app.
        case result(ResultItem)
        /// Leading calculator answer row (Enter copies it).
        case calc(Double)
    }

    /// One unified search result; `subtitle` is the parent folder path.
    struct ResultItem {
        enum Kind {
            case folder(path: String)
            case file(URL)
            case app(IndexedApp)
            var isFolder: Bool { if case .folder = self { return true }; return false }
        }
        let kind: Kind
        let title: String
        let subtitle: String
    }

    /// `tagIndex` is the Finder color slot (1-7) from the folder's raw
    /// tag xattr — Spotlight strips it, so it is read back per folder.
    struct FolderItem { let path: String; let name: String; let tag: String; var tagIndex: Int = 0 }
    struct RecentItem: Codable, Equatable { var path: String; var count: Int; var lastAt: Double }

    /// One folder chip inside a grid line. `x`/`width` are assigned by the
    /// fixed-column pass (`gridChipLines`).
    struct FolderChip {
        enum Kind { case favorite, recent, tagged }
        let item: FolderItem
        let kind: Kind
        var x: CGFloat = 0
        var width: CGFloat = 0
    }

    var rows: [Row] = []
    /// Grid selection (empty query): (chipLine table row, chip index).
    /// Chips self-highlight from this state — no table selection involved.
    var selectedChip: (row: Int, chip: Int)?

    // folders data
    var taggedFolders: [FolderItem] = []
    var recents: [RecentItem] = LauncherPanelController.loadRecents()
    var openFailures: [String: Int] = [:]
    var metadataQuery: NSMetadataQuery?
    var lastQueryAt: Date?

    var filterText: String {
        // The live editor text while editing — IME composition included,
        // so pinyin searches as it's typed (Spotlight-style) — and the
        // committed value otherwise.
        let raw = searchField.field.currentEditor()?.string ?? searchField.stringValue
        return raw.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Result-list mode: any typed query replaces the folder grid.
    var isSearching: Bool { !filterText.isEmpty }
    /// The app to hand focus back to on Esc (nil when Lexi already front).
    private var appToRestore: NSRunningApplication?
    /// Spotlight hits for the CURRENT query (async, debounced) — only
    /// rows whose `fileHitsQuery` equals the live filter render.
    var fileHits: [FileSearchService.Hit] = []
    var fileHitsQuery = ""
    var fileSearchWork: DispatchWorkItem?
    var didRequestProtectedAccess = false

    override init() {
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        // Launcher-panel hardening (tinycast PalettePanel parity): without
        // canJoinAllSpaces/fullScreenAuxiliary the panel still RENDERS over
        // another app's fullscreen space, but the window server routes its
        // clicks to the fullscreen app below — visible rows, dead mouse.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.acceptsMouseMovedEvents = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let (background, content, _) = makePanelBackground(
            frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 240),
            surface: .launcher,
            dark: cardTheme.isDark
        )
        panel.contentView = background
        glassContent = content
        glassContent.wantsLayer = true
        root = FlippedView(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 240))
        content.addSubview(root)
        super.init()
        panel.delegate = self
        buildChrome()
        applyTheme(dark: true)
    }

    // MARK: show / hide

    func show() {
        requestProtectedFolderAccessIfNeeded()
        appIndex.ensureScanned { [weak self] in
            // First open during a session: refresh results once the app
            // index lands (folder results show meanwhile).
            guard let self, self.panel.isVisible, self.isSearching else { return }
            self.reload()
        }
        searchField.stringValue = ""
        reload()  // ends in placePanel()
        // Key FIRST: a nonactivating panel takes key without app
        // activation, and this always worked. Activating before the panel
        // is even visible gets the request refused on macOS 14+, and the
        // aborted handshake then swallows the key request too — the
        // "panel opens, typing lands in the previous app" failure.
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField.field)
        // THEN activate (Spotlight/Raycast rule): a key panel of an
        // inactive app renders fine but the WindowServer routes its
        // clicks to the active app's window.
        let front = NSWorkspace.shared.frontmostApplication
        appToRestore = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front
        NSApp.activate(ignoringOtherApps: true)
        // The activation handshake can drop the first key request —
        // re-assert both next turn (tinycast PaletteWindowController
        // parity: "a never-activated login item can drop the first key
        // request").
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            if !self.panel.isKeyWindow {
                self.panel.makeKeyAndOrderFront(nil)
                FileLog.write("LAUNCH key re-asserted")
            }
            if !(self.panel.firstResponder is NSTextView) {
                self.panel.makeFirstResponder(self.searchField.field)
                FileLog.write("LAUNCH responder re-asserted")
            }
        }
        FileLog.write("LAUNCH show key=\(panel.isKeyWindow) active=\(NSApp.isActive)")
    }

    func hide(notify: Bool) {
        panel.orderOut(nil)
        if notify { onHidden?() }
    }

    /// Esc path: give the summoning app its focus back (tinycast
    /// PaletteWindowController parity). Click-through and launch paths
    /// skip this — whatever the user clicked is already front.
    private func hideAndRestorePreviousApp() {
        hide(notify: true)
        let app = appToRestore
        appToRestore = nil
        if let app {
            if #available(macOS 14.0, *) {
                _ = app.activate()
            } else {
                _ = app.activate(options: [])
            }
        }
    }

    /// Headless snapshot for the /debug-launcher-shot route.
    func snapshotPNG() -> Data? {
        panel.contentView?.snapshotPNG()
    }

    /// Headless query repro for the debug probe: types into the search
    /// field and reloads — the same path keystrokes take. `compose`
    /// simulates IME composition: text in the field editor only, the
    /// committed stringValue still empty (the pinyin-not-yet-chosen
    /// state), with the editor's didChange posted as the IME posts it.
    func debugSetQuery(_ text: String, compose: Bool = false) {
        panel.makeFirstResponder(searchField.field)
        if compose, let editor = searchField.field.currentEditor() {
            editor.string = text
            NotificationCenter.default.post(name: NSText.didChangeNotification, object: editor)
        } else {
            searchField.stringValue = text
            // The field is mid-edit: setting stringValue alone leaves the
            // editor holding the old text, and the commit on end-editing
            // would revert it. Keep both in sync — real keystrokes do.
            searchField.field.currentEditor()?.string = text
        }
        reload()
    }

    func logRowGeometry() {
        let parts = rows.enumerated().map { index, row -> String in
            let rect = tableView.rect(ofRow: index)
            let kind: String
            switch row {
            case .header(let title, _): kind = "H(\(title))"
            case .chipLine(let chips): kind = "C(\(chips.count))"
            case .result: kind = "R"
            case .calc: kind = "X"
            }
            return "\(kind)@y\(Int(rect.minY))+\(Int(rect.height))"
        }
        FileLog.write("LAUNCH rows: " + parts.joined(separator: " "))
    }

    /// Keyboard-selection repro for the debug probe: same path the arrow
    /// keys take.
    func debugSelectChip(row: Int, chip: Int) {
        selectChip(row: row, chip: chip)
    }

    func windowDidResignKey(_ notification: Notification) {
        hide(notify: true)
    }

    func applyTheme(dark: Bool) {
        cardTheme = dark ? .dark : .light
        panel.appearance = dark
            ? NSAppearance(named: .vibrantDark)
            : NSAppearance(named: .vibrantLight)
        styleChrome()
        tableView.reloadData()
    }

    // MARK: chrome

    private func buildChrome() {
        let side: CGFloat = 12

        // The search strip leaves room for the gear on its right — one
        // chrome line (the Folders/Apps tabs folded into unified search).
        searchField.frame = NSRect(
            x: side, y: 12, width: Self.panelWidth - side * 2 - 36, height: 28)
        searchField.placeholder = "Search folders and apps"
        searchField.field.delegate = self
        root.addSubview(searchField)

        settingsButton.bezelStyle = .recessed
        settingsButton.isBordered = false
        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        settingsButton.imagePosition = .imageOnly
        settingsButton.toolTip = "Settings"
        settingsButton.target = self
        settingsButton.action = #selector(settingsClicked)
        root.addSubview(settingsButton)
        // Fixed top-right slot on the search line (layoutChrome only
        // owns the list geometry now).
        settingsButton.frame = NSRect(x: Self.panelWidth - side - 28, y: 12, width: 28, height: 28)

        tableView.headerView = nil
        tableView.backgroundColor = .clear
        // Plain style + zero intercell: we own the geometry exactly
        // (clipboard-panel lesson — the .inset style pads rows ~17pt).
        tableView.style = .plain
        tableView.intercellSpacing = .zero
        tableView.usesAutomaticRowHeights = false
        tableView.rowHeight = Self.rowHeight
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.backgroundColor = .clear
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("LauncherColumn"))
        tableView.addTableColumn(column)
        scrollView.documentView = tableView
        // Without these the table renders zero rows — the dataSource/
        // delegate methods on self are the entire list pipeline.
        tableView.dataSource = self
        tableView.delegate = self
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        root.addSubview(scrollView)

        root.addSubview(emptyLabel)
    }

    @objc private func settingsClicked() {
        onOpenSettings?()
    }

    private func styleChrome() {
        // Content-layer veil: 26+ materials self-manage contrast (no
        // hand-painted scrim); legacy systems keep the TinyCast veil.
        PanelStyle.applyContentScrim(to: glassContent, dark: cardTheme.isDark)
        emptyLabel.textColor = cardTheme.tertiaryText
        searchField.applyTheme(cardTheme)
        settingsButton.contentTintColor = cardTheme.foreground
    }

    private func layoutChrome(height: CGFloat) {
        let side: CGFloat = PanelDesign.sideInset
        scrollView.frame = NSRect(
            x: 0, y: Self.chromeHeight,
            width: Self.panelWidth, height: height - Self.chromeHeight - Self.bottomPad)
        emptyLabel.frame = NSRect(x: side, y: Self.chromeHeight, width: Self.panelWidth - side * 2, height: 40)
    }

    /// Top-anchored adaptive height: list area is capped, panel never
    /// exceeds ~600pt total, minimum ~200pt. The cap lands on WHOLE rows
    /// and never leaves an orphan section header at the fold.
    private var panelHeight: CGFloat {
        var listHeight: CGFloat = 0
        var lastRowKind: Row? = nil
        for row in rows {
            let height = rowHeight(for: row)
            if listHeight + height > Self.maxListHeight { break }
            listHeight += height
            lastRowKind = row
        }
        // An orphan header (its chips fell past the fold) reads as a bug —
        // give its height back.
        if case .header = lastRowKind, listHeight > Self.headerHeight {
            listHeight -= Self.headerHeight
        }
        return min(max(Self.chromeHeight + Self.bottomPad + max(listHeight, Self.rowHeight * 3), 200), 600)
    }

    func rowHeight(for row: Row) -> CGFloat {
        switch row {
        case .header: return Self.headerHeight
        case .chipLine: return Self.chipLineHeight
        case .result, .calc: return Self.rowHeight
        }
    }

    func placePanel() {
        let size = NSSize(width: Self.panelWidth, height: panelHeight)
        root.frame = NSRect(origin: .zero, size: size)
        layoutChrome(height: size.height)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = visible.midX - size.width / 2
        let y = max(visible.maxY - visible.height * 0.25 - size.height, visible.minY)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    // MARK: open actions

    private func openPath(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            FileLog.write("LAUNCH open fail (missing) path=\(path)")
            recordOpen(path: path, ok: false)
            if panel.isVisible { reload() }
            return
        }
        FileLog.write("LAUNCH open path=\(path)")
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        recordOpen(path: path, ok: true)
        hide(notify: false)
    }

    private func activateRow(_ index: Int) {
        guard index >= 0, index < rows.count else { return }
        switch rows[index] {
        case .chipLine(let chips):
            let chip = selectedChip?.row == index ? (selectedChip?.chip ?? 0) : 0
            if chips.indices.contains(chip) {
                openPath(chips[chip].item.path)
            }
        case .result(let item):
            openResultItem(item)
        case .calc(let value):
            copyCalcResult(value)
        case .header:
            break
        }
    }

    // MARK: keyboard

    /// Folders grid: selection is (chipLine row, chip index) — chips
    /// highlight from `selectedChip` state, no table selection involved.
    private func selectChip(row: Int, chip: Int) {
        selectedChip = (row: row, chip: chip)
        tableView.reloadData()
        tableView.scrollRowToVisible(row)
    }

    private func currentChip() -> (row: Int, chip: Int, chips: [FolderChip])? {
        guard let sel = selectedChip, rows.indices.contains(sel.row),
              case .chipLine(let chips) = rows[sel.row], chips.indices.contains(sel.chip)
        else { return nil }
        return (sel.row, sel.chip, chips)
    }

    private func moveVertical(_ delta: Int) {
        if isSearching {
            let selectable = selectableRowIndexes()
            guard !selectable.isEmpty else { return }
            let next: Int
            if let current = selectable.firstIndex(of: tableView.selectedRow) {
                let target = current + delta
                next = selectable[min(max(target, 0), selectable.count - 1)]
            } else {
                next = delta > 0 ? selectable[0] : selectable[selectable.count - 1]
            }
            tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
            tableView.scrollRowToVisible(next)
            return
        }
        let lines = chipLineRows()
        guard !lines.isEmpty else { return }
        let target: Int
        var refChip: FolderChip?
        if let cur = currentChip(), let pos = lines.firstIndex(of: cur.row) {
            let next = pos + delta
            guard lines.indices.contains(next) else { return }
            target = lines[next]
            refChip = cur.chips[cur.chip]
        } else {
            target = delta > 0 ? lines[0] : lines[lines.count - 1]
        }
        // Land on the chip whose x-range overlaps the current one most
        // (text-editor line navigation).
        var chipIndex = 0
        if let refChip, case .chipLine(let chips) = rows[target] {
            var bestOverlap = CGFloat(-1)
            for (i, chip) in chips.enumerated() {
                let lo = max(refChip.x, chip.x)
                let hi = min(refChip.x + refChip.width, chip.x + chip.width)
                if hi - lo > bestOverlap {
                    bestOverlap = hi - lo
                    chipIndex = i
                }
            }
        }
        selectChip(row: target, chip: chipIndex)
    }

    private func moveHorizontal(_ delta: Int) {
        guard !isSearching, let cur = currentChip() else { return }
        var row = cur.row
        var chip = cur.chip + delta
        while rows.indices.contains(row) {
            if case .chipLine(let chips) = rows[row] {
                if chips.indices.contains(chip) {
                    selectChip(row: row, chip: chip)
                    return
                }
                chip = delta > 0 ? 0 : chips.count - 1
            }
            row += delta
        }
    }

    private func activateSelected() {
        if isSearching {
            let row = tableView.selectedRow
            if row >= 0, row < rows.count {
                activateRow(row)
            } else if let first = selectableRowIndexes().first {
                activateRow(first)
            }
            return
        }
        if let cur = currentChip() {
            openPath(cur.chips[cur.chip].item.path)
        }
    }

    /// Enter on a result row: folders open in Finder (recents recorded
    /// by `openPath`), apps launch via LaunchServices — the `open -a`
    /// path fronts an already-running app reliably;
    /// NSRunningApplication.activate() alone is silently ignored on
    /// macOS 14+ for background callers (WeChat was the repro).
    private func openResultItem(_ item: ResultItem) {
        switch item.kind {
        case .folder(let path):
            openPath(path)
        case .file(let url):
            NSWorkspace.shared.open(url)
            hide(notify: false)
        case .app(let app):
            NSApp.activate(ignoringOtherApps: true)
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            if let id = app.bundleID { AppUsage.shared.record(id) }
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: app.path), configuration: config) { _, _ in }
            hide(notify: false)
        }
    }

    /// Enter on the calculator row: the plain answer (no grouping) goes
    /// to the pasteboard and the panel folds.
    private func copyCalcResult(_ value: Double) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(CalcEngine.copyText(value), forType: .string)
        hide(notify: false)
    }

    // NSTextFieldDelegate — arrows/table/Enter/Tab/Esc while the search
    // field holds first responder.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case NSSelectorFromString("moveUp:"):
            moveVertical(-1)
            return true
        case NSSelectorFromString("moveDown:"):
            moveVertical(1)
            return true
        case NSSelectorFromString("moveLeft:"):
            if !isSearching {
                moveHorizontal(-1)
                return true
            }
            return false
        case NSSelectorFromString("moveRight:"):
            if !isSearching {
                moveHorizontal(1)
                return true
            }
            return false
        case NSSelectorFromString("insertNewline:"):
            activateSelected()
            return true
        case NSSelectorFromString("insertTab:"):
            // Nothing to tab between anymore — swallow it so focus stays
            // in the search field.
            return true
        case NSSelectorFromString("cancelOperation:"):
            if !searchField.stringValue.isEmpty {
                searchField.stringValue = ""
                reload()
            } else {
                hideAndRestorePreviousApp()
            }
            return true
        default:
            return false
        }
    }

    /// Search-field delegate — live filter. The notification object is
    /// the FIELD for committed typing and its EDITOR for IME composition
    /// — compare identity, no casts (NSTextField is not an NSText, so an
    /// `as? NSText` guard silently dropped every normal keystroke).
    func controlTextDidChange(_ obj: Notification) {
        guard let subject = obj.object as AnyObject?,
            (subject as AnyObject) === searchField.field
                || (subject as AnyObject) === searchField.field.currentEditor()
        else { return }
        reload()
    }

    /// Chip lines self-highlight from `selectedChip`; a full-row table
    /// selection on click is visual noise (and headers aren't
    /// selectable). Result/calc rows take the table selection in search
    /// mode.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard row < rows.count else { return false }
        switch rows[row] {
        case .chipLine, .header: return false
        case .result, .calc: return isSearching
        }
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return Self.rowHeight }
        return rowHeight(for: rows[row])
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        switch rows[row] {
        case .header(let title, let tagColor):
            let cell = reuse(LauncherHeaderCell.self, row: row)
            // One header style: secondary label for every section; tag
            // groups carry their Finder color as a leading dot.
            cell.configure(title: title, dotColor: tagColor, secondary: cardTheme.secondaryText)
            return cell
        case .chipLine(let chips):
            let cell = reuse(LauncherChipLineCell.self, row: row)
            cell.configure(
                chips: chips,
                theme: cardTheme,
                selectedIndex: selectedChip?.row == row ? selectedChip?.chip : nil,
                onOpen: { [weak self] path in
                    self?.openPath(path)
                }
            )
            return cell
        case .result(let item):
            let cell = reuse(LauncherResultCell.self, row: row)
            cell.configure(item: item, theme: cardTheme) { [weak self] in
                self?.openResultItem(item)
            }
            return cell
        case .calc(let value):
            let cell = reuse(LauncherCalcCell.self, row: row)
            cell.configure(
                expression: searchField.stringValue.trimmingCharacters(in: .whitespaces),
                value: value,
                theme: cardTheme
            ) { [weak self] in
                self?.copyCalcResult(value)
            }
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(
            withIdentifier: NSUserInterfaceItemIdentifier("LauncherRowView"),
            owner: self
        ) as? LauncherRowView ?? LauncherRowView()
        view.identifier = NSUserInterfaceItemIdentifier("LauncherRowView")
        view.fillColor = .selectedContentBackgroundColor
        return view
    }

    private func reuse<T: NSView>(_ type: T.Type, row: Int) -> T {
        let identifier = NSUserInterfaceItemIdentifier(String(describing: type))
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? T {
            return reused
        }
        let view = T(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: rowHeight(for: rows[row])))
        view.identifier = identifier
        return view
    }
}

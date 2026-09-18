import AppKit

/// Launcher panel — double-Shift surface for jumping to tagged folders,
/// recent folders and running apps.
///
/// Top-level isolated from the toolbar/result-card/notes flows: it owns its
/// panel, data and actions. Shared bottom layers only: `KeyablePanel`,
/// `makePanelBackground`, `CardTheme`, `lucideImage`, `tagColor`, `FileLog`
/// (SelectionToolbarHelper.swift) and the TCP dispatch in
/// `SelectionToolbarApp.handleRequestData`.
final class LauncherPanelController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    /// Fired whenever the panel hides itself (Esc / focus loss); the app
    /// controller wires this to its action channel ("launcher-hidden").
    var onHidden: (() -> Void)?
    /// Gear button in the chrome: opens the native settings window.
    var onOpenSettings: (() -> Void)?

    private static let panelWidth: CGFloat = 520
    private static let rowHeight: CGFloat = 40
    private static let headerHeight: CGFloat = 28
    private static let chipLineHeight: CGFloat = 30
    private static let maxListHeight: CGFloat = 10 * LauncherPanelController.rowHeight
    private static let chromeHeight: CGFloat = 92 // search 12+30+8 + tabs 28+8 + bottom pad 6
    private static let recentsKey = "launcher.recents"

    private let panel: KeyablePanel
    private let root: FlippedView
    /// The makePanelBackground content view — scrimmed on theme changes so
    /// the glass keeps text contrast on dark wallpapers.
    private let glassContent: NSView
    private let searchField = NSSearchField()
    private let settingsButton = NSButton()
    private let foldersTabButton = NSButton()
    private let appsTabButton = NSButton()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var cardTheme: CardTheme = .dark

    enum Tab { case folders, apps }
    var tab: Tab = .folders {
        didSet { guard tab != oldValue else { return }; syncTabButtons(); reload() }
    }

    enum Row {
        case header(String)
        case chipLine([FolderChip])
        case app(RunningAppItem)
    }

    struct FolderItem { let path: String; let name: String; let tag: String }
    struct RecentItem: Codable, Equatable { var path: String; var count: Int; var lastAt: Double }
    struct RunningAppItem { let app: NSRunningApplication; let name: String }

    /// One folder chip inside a wrapping grid line. `x`/`width` are assigned
    /// by the flow-layout pass (`flowChipLines`).
    struct FolderChip {
        enum Kind { case favorite, recent, tagged }
        let item: FolderItem
        let kind: Kind
        var x: CGFloat = 0
        var width: CGFloat = 0
    }

    var rows: [Row] = []
    /// Grid selection for the Folders tab: (chipLine table row, chip index).
    /// Chips self-highlight from this state — no table selection involved.
    var selectedChip: (row: Int, chip: Int)?

    // folders data
    private var taggedFolders: [FolderItem] = []
    private var recents: [RecentItem] = LauncherPanelController.loadRecents()
    private var openFailures: [String: Int] = [:]
    private var metadataQuery: NSMetadataQuery?
    private var lastQueryAt: Date?
    private var editorAppURL: URL?

    enum OpenTarget { case finder, editor, terminal }

    /// First installed editor wins (spec §4.4).
    private static let editorBundleIds = ["com.microsoft.VSCode", "dev.zed.Zed", "com.sublimetext.4"]

    private var filterText: String {
        searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
    }

    override init() {
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let (background, content, _) = makePanelBackground(
            frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 240),
            surface: .launcher
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
        reload()
        placePanel()
        searchField.stringValue = ""
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    func hide(notify: Bool) {
        panel.orderOut(nil)
        if notify { onHidden?() }
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

        searchField.frame = NSRect(x: side, y: 12, width: Self.panelWidth - side * 2, height: 26)
        searchField.placeholderString = "Search"
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 16)
        (searchField.cell as? NSSearchFieldCell)?.sendsActionOnEndEditing = false
        searchField.wantsLayer = true
        searchField.delegate = self
        root.addSubview(searchField)

        for (button, title) in [(foldersTabButton, "Folders"), (appsTabButton, "Apps")] {
            button.title = title
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.bezelStyle = .recessed
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = PanelDesign.pillCornerRadius
            button.target = self
            root.addSubview(button)
        }
        foldersTabButton.action = #selector(tabClicked(_:))
        appsTabButton.action = #selector(tabClicked(_:))

        settingsButton.bezelStyle = .recessed
        settingsButton.isBordered = false
        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        settingsButton.imagePosition = .imageOnly
        settingsButton.toolTip = "Settings"
        settingsButton.target = self
        settingsButton.action = #selector(settingsClicked)
        root.addSubview(settingsButton)
        foldersTabButton.tag = 0
        appsTabButton.tag = 1

        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.usesAutomaticRowHeights = false
        tableView.rowHeight = Self.rowHeight
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.backgroundColor = .clear
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("LauncherColumn"))
        tableView.addTableColumn(column)
        scrollView.documentView = tableView
        // Without these the table renders zero rows on both tabs — the
        // dataSource/delegate methods on self are the entire list pipeline.
        tableView.dataSource = self
        tableView.delegate = self
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        root.addSubview(scrollView)

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        root.addSubview(emptyLabel)

        syncTabButtons()
    }

    @objc private func tabClicked(_ sender: NSButton) {
        tab = sender.tag == 0 ? .folders : .apps
    }

    @objc private func settingsClicked() {
        onOpenSettings?()
    }

    private func syncTabButtons() {
        foldersTabButton.layer?.backgroundColor = (tab == .folders
            ? cardTheme.selectedFill
            : cardTheme.hoverFill).cgColor
        appsTabButton.layer?.backgroundColor = (tab == .apps
            ? cardTheme.selectedFill
            : cardTheme.hoverFill).cgColor
        foldersTabButton.contentTintColor = cardTheme.foreground
        appsTabButton.contentTintColor = cardTheme.foreground
        settingsButton.contentTintColor = cardTheme.foreground
    }

    private func styleChrome() {
        // Contrast scrim (TinyCast values): dark 40% black / light 55%
        // white, painted between the vibrancy material and the content.
        glassContent.layer?.backgroundColor = PanelStyle.scrim(dark: cardTheme.isDark).cgColor
        emptyLabel.textColor = cardTheme.tertiaryText
        syncTabButtons()
    }

    private func layoutChrome(height: CGFloat) {
        let side: CGFloat = 12
        var x = side
        for button in [foldersTabButton, appsTabButton] {
            button.sizeToFit()
            button.frame = NSRect(x: x, y: 46, width: max(button.fittingSize.width + 20, 64), height: 24)
            x = button.frame.maxX + 6
        }

        settingsButton.frame = NSRect(x: Self.panelWidth - side - 24, y: 46, width: 24, height: 24)
        scrollView.frame = NSRect(x: 0, y: 78, width: Self.panelWidth, height: height - Self.chromeHeight)
        emptyLabel.frame = NSRect(x: side, y: 78, width: Self.panelWidth - side * 2, height: 40)
    }

    /// Top-anchored adaptive height: list area is capped, panel never exceeds
    /// ~480pt total, minimum ~200pt.
    private var panelHeight: CGFloat {
        let listHeight = min(rows.reduce(0.0) { $0 + rowHeight(for: $1) }, Self.maxListHeight)
        return min(max(Self.chromeHeight + max(listHeight, Self.rowHeight * 3), 200), 480)
    }

    private func rowHeight(for row: Row) -> CGFloat {
        switch row {
        case .header: return Self.headerHeight
        case .chipLine: return Self.chipLineHeight
        case .app: return Self.rowHeight
        }
    }

    private func placePanel() {
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

    // MARK: data

    func reload() {
        refreshFoldersData()
        switch tab {
        case .folders: rows = buildFolderRows()
        case .apps: rows = buildAppRows()
        }
        editorAppURL = Self.editorBundleIds.lazy.compactMap {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }.first
        tableView.reloadData()
        switch tab {
        case .folders:
            // Grid selection lives in `selectedChip`; default to the first
            // chip so Enter works immediately.
            if let first = chipLineRows().first {
                selectedChip = (row: first, chip: 0)
            } else {
                selectedChip = nil
            }
        case .apps:
            let selectable = selectableRowIndexes()
            if let first = selectable.first {
                tableView.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
            }
        }
        let empty = rows.isEmpty
        emptyLabel.isHidden = !empty
        emptyLabel.stringValue = tab == .folders
            ? "No tagged folders — tag folders in Finder to list them here"
            : "No matching apps"
        placePanel()
    }

    private func selectableRowIndexes() -> [Int] {
        rows.indices.filter { row in
            switch rows[row] {
            case .header: return false
            case .chipLine: return tab == .folders
            case .app: return tab == .apps
            }
        }
    }

    private func chipLineRows() -> [Int] {
        rows.indices.filter { row in
            if case .chipLine = rows[row] { return true }
            return false
        }
    }


    /// Canonical home subfolders pinned to the top of the Folders tab
    /// (Favorites → Recent → tag groups). Displayed with the system-
    /// localized name (桌面/下载/…); only folders that exist are listed.
    private static let favoriteFolderNames = ["Desktop", "Documents", "Downloads", "Movies", "Pictures"]

    private func buildFolderRows() -> [Row] {
        let filter = filterText
        var out: [Row] = []

        func matches(_ name: String, path: String) -> Bool {
            filter.isEmpty
                || name.lowercased().contains(filter)
                || path.lowercased().contains(filter)
        }

        var favorites: [FolderChip] = []
        for name in Self.favoriteFolderNames {
            let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let localizedName = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName ?? name
            guard matches(localizedName, path: url.path) else { continue }
            favorites.append(FolderChip(
                item: FolderItem(path: url.path, name: localizedName, tag: ""),
                kind: .favorite
            ))
        }
        if !favorites.isEmpty {
            out.append(.header("Favorites"))
            out += flowChipLines(favorites).map { .chipLine($0) }
        }

        var recentChips: [FolderChip] = []
        for item in recents where matches(item.path, path: item.path) {
            let url = URL(fileURLWithPath: item.path)
            recentChips.append(FolderChip(
                item: FolderItem(path: item.path, name: url.lastPathComponent, tag: ""),
                kind: .recent
            ))
        }
        if !recentChips.isEmpty {
            out.append(.header("Recent"))
            out += flowChipLines(recentChips).map { .chipLine($0) }
        }

        let matching = taggedFolders.filter { matches($0.name, path: $0.path) }
        let grouped = Dictionary(grouping: matching) { $0.tag.isEmpty ? "Untagged" : $0.tag }
        for tag in grouped.keys.sorted() {
            out.append(.header(tag))
            let chips = grouped[tag]!
                .sorted { $0.name.lowercased() < $1.name.lowercased() }
                .map { FolderChip(item: $0, kind: .tagged) }
            out += flowChipLines(chips).map { .chipLine($0) }
        }
        return out
    }

    /// Wraps chips into grid lines of at most `maxWidth` points (8pt gaps).
    /// Chips are UNIFORM width — an even grid reads far cleaner than a
    /// ragged word-cloud of variable-width capsules.
    private func flowChipLines(_ chips: [FolderChip], maxWidth: CGFloat = 496) -> [[FolderChip]] {
        var lines: [[FolderChip]] = [[]]
        var x: CGFloat = 0
        for chip in chips {
            let width = Self.chipWidth(for: chip)
            if x > 0, x + width > maxWidth {
                lines.append([])
                x = 0
            }
            var placed = chip
            placed.x = x
            placed.width = width
            lines[lines.count - 1].append(placed)
            x += width + 8
        }
        return lines.filter { !$0.isEmpty }
    }

    /// Uniform chip cell: 4 per row in a 520pt panel (116 + 8 gap).
    static func chipWidth(for chip: FolderChip) -> CGFloat { 116 }

    // MARK: tagged folders (Spotlight metadata)
    private var didRequestProtectedAccess = false

    /// TCC silently filters Desktop/Documents/Downloads items out of
    /// NSMetadataQuery results for processes without folder permission (why
    /// the first run showed 3 of 17 tagged folders). One listing attempt per
    /// protected folder triggers the system prompt (Info.plist usage
    /// descriptions required); a grant persists for the app, and the query
    /// re-runs on the next show (5s throttle).
    private func requestProtectedFolderAccessIfNeeded() {
        guard !didRequestProtectedAccess else { return }
        didRequestProtectedAccess = true
        // Off the main thread: the TCC prompt BLOCKS the listing call until
        // answered, and show() must never freeze behind a dialog the user
        // may not notice. One prompt set total; grants persist per app.
        DispatchQueue.global(qos: .utility).async {
            let home = URL(fileURLWithPath: NSHomeDirectory())
            for folder in ["Desktop", "Documents", "Downloads"] {
                _ = try? FileManager.default.contentsOfDirectory(
                    atPath: home.appendingPathComponent(folder).path
                )
            }
        }
    }

    private func refreshFoldersData() {
        if let last = lastQueryAt, Date().timeIntervalSince(last) < 5 { return }
        stopMetadataQuery()
        let query = NSMetadataQuery()
        // `== '*'` compiles to a LITERAL match (always empty) — LIKE keeps
        // the wildcard semantics and matches any tagged item (verified:
        // == gives 0 results, LIKE gives 17 on this machine).
        query.predicate = NSPredicate(format: "%K LIKE '*'", "kMDItemUserTags")
        query.searchScopes = [URL(fileURLWithPath: NSHomeDirectory())]
        NotificationCenter.default.addObserver(
            self, selector: #selector(metadataQueryDidFinish(_:)),
            name: .NSMetadataQueryDidFinishGathering, object: query
        )
        query.start()
        metadataQuery = query
        lastQueryAt = Date()
    }

    private func stopMetadataQuery() {
        if let query = metadataQuery {
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: query)
            query.stop()
        }
        metadataQuery = nil
    }

    @objc private func metadataQueryDidFinish(_ notification: Notification) {
        guard let query = notification.object as? NSMetadataQuery else { return }
        query.disableUpdates()
        var items: [FolderItem] = []
        for result in query.results {
            guard let item = result as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else { continue }
            let url = URL(fileURLWithPath: path)
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let rawTags = (item.value(forAttribute: "kMDItemUserTags") as? [String]) ?? []
            let tag = rawTags.map(Self.normalizedTag).first ?? ""
            items.append(FolderItem(path: path, name: url.lastPathComponent, tag: tag))
        }
        query.enableUpdates()
        FileLog.write("launcher folders query: raw=\(query.results.count) folders=\(items.count) sample=\(items.prefix(3).map(\.path).joined(separator: " | "))")
        stopMetadataQuery()
        taggedFolders = items.sorted {
            ($0.tag, $0.name.lowercased()) < ($1.tag, $1.name.lowercased())
        }
        if panel.isVisible && tab == .folders { reload() }
    }

    /// Finder writes the 7 default color tags with a leading symbol scalar
    /// (e.g. "🔴红色") — strip leading symbol/emoji scalars, keep the name.
    static func normalizedTag(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.drop { scalar in
            scalar.value >= 0x1F000 || (scalar.value >= 0x2190 && scalar.value <= 0x2BFF)
        }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: recents (helper-local persistence)

    private static func loadRecents() -> [RecentItem] {
        guard let data = UserDefaults.standard.data(forKey: recentsKey),
              let items = try? JSONDecoder().decode([RecentItem].self, from: data)
        else { return [] }
        return items.sorted { $0.lastAt > $1.lastAt }
    }

    private func persistRecents() {
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: Self.recentsKey)
        }
    }

    /// Record an open attempt. A failing path is not re-inserted; after 3
    /// failures the entry is dropped entirely (spec §7).
    private func recordOpen(path: String, ok: Bool) {
        let previous = recents.first { $0.path == path }
        recents.removeAll { $0.path == path }
        if ok {
            recents.insert(
                RecentItem(path: path, count: (previous?.count ?? 0) + 1, lastAt: Date().timeIntervalSince1970),
                at: 0
            )
            openFailures[path] = nil
        } else {
            let failures = (openFailures[path] ?? 0) + 1
            if failures >= 3 {
                openFailures[path] = nil
            } else {
                openFailures[path] = failures
            }
        }
        if recents.count > 10 { recents = Array(recents.prefix(10)) }
        persistRecents()
    }

    // MARK: open actions

    private func openPath(_ path: String, target: OpenTarget) {
        guard FileManager.default.fileExists(atPath: path) else {
            recordOpen(path: path, ok: false)
            if panel.isVisible && tab == .folders { reload() }
            return
        }
        let url = URL(fileURLWithPath: path)
        switch target {
        case .finder:
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        case .editor:
            if let editor = editorAppURL {
                let config = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: config)
            } else {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
            }
        case .terminal:
            if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                let config = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: config)
            }
        }
        recordOpen(path: path, ok: true)
        hide(notify: false)
    }
    private func activateRow(_ index: Int) {
        guard index >= 0, index < rows.count else { return }
        switch rows[index] {
        case .chipLine(let chips):
            let chip = selectedChip?.row == index ? (selectedChip?.chip ?? 0) : 0
            if chips.indices.contains(chip) {
                openPath(chips[chip].item.path, target: .finder)
            }
        case .app(let item): activateApp(item)
        case .header: break
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
        if tab == .apps {
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
        guard tab == .folders, let cur = currentChip() else { return }
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
        switch tab {
        case .folders:
            if let cur = currentChip() {
                openPath(cur.chips[cur.chip].item.path, target: .finder)
            }
        case .apps:
            let row = tableView.selectedRow
            if row >= 0, row < rows.count {
                activateRow(row)
            } else if let first = selectableRowIndexes().first {
                activateRow(first)
            }
        }
    }
    private func buildAppRows() -> [Row] {
        let filter = filterText
        let own = ProcessInfo.processInfo.processIdentifier
        let helperBundleId = Bundle.main.bundleIdentifier
        // .regular = Dock apps, .accessory = menu-bar apps the user runs
        // (剪贴板/翻译工具等). .prohibited (system agents) stay excluded.
        var apps = NSWorkspace.shared.runningApplications.filter { app in
            (app.activationPolicy == .regular || app.activationPolicy == .accessory)
                && app.bundleIdentifier != nil
                && app.bundleIdentifier != helperBundleId
                && app.processIdentifier != own
                && (filter.isEmpty
                    || (app.localizedName ?? "").lowercased().contains(filter))
        }
        let front = apps.first { $0.isActive }
        apps.removeAll { $0 == front }
        // Frontmost first, then Dock apps, then menu-bar accessories; each
        // group alphabetical.
        apps.sort {
            if $0.activationPolicy != $1.activationPolicy {
                return $0.activationPolicy == .regular
            }
            return ($0.localizedName ?? "").lowercased() < ($1.localizedName ?? "").lowercased()
        }
        if let front { apps.insert(front, at: 0) }
        return apps.map { RunningAppItem(app: $0, name: $0.localizedName ?? $0.bundleIdentifier ?? "?") }
            .map { Row.app($0) }
    }

    private func activateApp(_ item: RunningAppItem) {
        // LaunchServices activation (the `open -a` path) fronts an already-
        // running app reliably; NSRunningApplication.activate() alone is
        // silently ignored on macOS 14+ for background callers — WeChat was
        // the repro. bundleURL fallback covers odd app bundles.
        NSApp.activate(ignoringOtherApps: true)
        if let url = item.app.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        } else if #available(macOS 14.0, *) {
            _ = item.app.activate()
        } else {
            _ = item.app.activate(options: [.activateIgnoringOtherApps])
        }
        hide(notify: false)
    }


    // NSSearchFieldDelegate — arrows/table/Enter/Tab/Esc while the search
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
            if tab == .folders {
                moveHorizontal(-1)
                return true
            }
            return false
        case NSSelectorFromString("moveRight:"):
            if tab == .folders {
                moveHorizontal(1)
                return true
            }
            return false
        case NSSelectorFromString("insertNewline:"):
            activateSelected()
            return true
        case NSSelectorFromString("insertTab:"):
            tab = tab == .folders ? .apps : .folders
            return true
        case NSSelectorFromString("cancelOperation:"):
            if !searchField.stringValue.isEmpty {
                searchField.stringValue = ""
                reload()
            } else {
                hide(notify: true)
            }
            return true
        default:
            return false
        }
    }

    // NSSearchFieldDelegate — live filter.
    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSSearchField === searchField else { return }
        reload()
    }
    /// Chip lines self-highlight from `selectedChip`; a full-row table
    /// selection on click is visual noise (and headers aren't selectable).
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard row < rows.count else { return false }
        switch rows[row] {
        case .chipLine, .header: return false
        case .app: return true
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
        case .header(let title):
            let cell = reuse(LauncherHeaderCell.self, row: row)
            // Tag groups wear their tag color (matches the row dots); the
            // two fixed sections (Favorites/Recent) stay a quiet secondary.
            let color = ["Favorites", "Recent"].contains(title)
                ? cardTheme.secondaryText
                : tagColor(for: title, dark: cardTheme.isDark)
            cell.configure(title: title, color: color)
            return cell
        case .chipLine(let chips):
            let cell = reuse(LauncherChipLineCell.self, row: row)
            cell.configure(
                chips: chips,
                theme: cardTheme,
                selectedIndex: selectedChip?.row == row ? selectedChip?.chip : nil,
                onActivate: { [weak self] chipIndex in
                    guard let self, chips.indices.contains(chipIndex) else { return }
                    self.openPath(chips[chipIndex].item.path, target: .finder)
                },
                onSecondary: { [weak self] chipIndex, action in
                    guard let self, chips.indices.contains(chipIndex) else { return }
                    switch action {
                    case .editor: self.openPath(chips[chipIndex].item.path, target: .editor)
                    case .terminal: self.openPath(chips[chipIndex].item.path, target: .terminal)
                    }
                }
            )
            return cell
        case .app(let item):
            let cell = reuse(LauncherAppCell.self, row: row)
            cell.configure(item: item, theme: cardTheme) { [weak self] in
                self?.activateApp(item)
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
        view.fillColor = cardTheme.selectedFill
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

/// Top-down layout container (row 0 = the top edge).
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Section header row (tag name / "Recent").
final class LauncherHeaderCell: NSView {
    private let label = NSTextField(labelWithString: "")
    private var didLayout = false

    func configure(title: String, color: NSColor) {
        label.stringValue = title.uppercased()
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = color
        if !didLayout {
            didLayout = true
            label.frame = NSRect(x: 16, y: 8, width: 480, height: 14)
            addSubview(label)
        }
    }
}

enum FolderChipAction { case editor, terminal }

/// One wrapping grid line of folder chips (single-line Folders layout).
final class LauncherChipLineCell: NSView {
    private var chipViews: [FolderChipView] = []

    func configure(
        chips: [LauncherPanelController.FolderChip],
        theme: CardTheme,
        selectedIndex: Int?,
        onActivate: @escaping (Int) -> Void,
        onSecondary: @escaping (Int, FolderChipAction) -> Void
    ) {
        chipViews.forEach { $0.removeFromSuperview() }
        chipViews.removeAll()
        for (index, chip) in chips.enumerated() {
            let view = FolderChipView(frame: NSRect(x: chip.x, y: 2, width: chip.width, height: 26))
            view.configure(chip: chip, theme: theme, selected: index == selectedIndex) {
                onActivate(index)
            } onSecondary: { action in
                onSecondary(index, action)
            }
            addSubview(view)
            chipViews.append(view)
        }
    }
}

/// A single folder chip: leading glyph + folder name. The leading glyph is
/// replaced by editor/terminal mini-buttons while hovered.
final class FolderChipView: NSView {
    private let dot = NSView()
    private let glyphView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let editorButton = NSButton()
    private let terminalButton = NSButton()
    private var hoverArea: NSTrackingArea?
    private var onActivate: (() -> Void)?
    private var onSecondary: ((FolderChipAction) -> Void)?
    private var theme: CardTheme = .dark
    private var isTaggedChip = false
    private var isSelectedChip = false
    private var didLayout = false

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        applyBackground(hovering: true)
        glyphView.isHidden = true
        dot.isHidden = true
        editorButton.isHidden = false
        terminalButton.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        applyBackground(hovering: false)
        editorButton.isHidden = true
        terminalButton.isHidden = true
        glyphView.isHidden = isTaggedChip
        dot.isHidden = !isTaggedChip
    }

    override func mouseDown(with event: NSEvent) { onActivate?() }

    func configure(
        chip: LauncherPanelController.FolderChip,
        theme: CardTheme,
        selected: Bool,
        onActivate: @escaping () -> Void,
        onSecondary: @escaping (FolderChipAction) -> Void
    ) {
        self.theme = theme
        self.isTaggedChip = chip.kind == .tagged
        self.isSelectedChip = selected
        self.onActivate = onActivate
        self.onSecondary = onSecondary
        if !didLayout {
            didLayout = true
            wantsLayer = true
            layer?.cornerRadius = PanelDesign.chipCornerRadius

            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.frame = NSRect(x: 11, y: 10, width: 6, height: 6)
            addSubview(dot)

            glyphView.frame = NSRect(x: 7, y: 6, width: 14, height: 14)
            addSubview(glyphView)

            nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
            nameLabel.lineBreakMode = .byTruncatingTail
            nameLabel.cell?.usesSingleLineMode = true
            addSubview(nameLabel)


            // Hover key-caps: two rounded-square buttons parked over the
            // leading glyph zone. Caps get their own inset background so
            // they read as buttons, not floating glyphs.
            for (button, icon, action) in [
                (editorButton, "code", FolderChipAction.editor),
                (terminalButton, "terminal", FolderChipAction.terminal),
            ] {
                button.isBordered = false
                button.title = ""
                button.setButtonType(.momentaryChange)
                button.wantsLayer = true
                button.layer?.cornerRadius = 5
                button.layer?.backgroundColor = theme.inputFill.cgColor
                if let image = lucideImage(for: icon, title: "", color: theme.iconTint) {
                    image.size = NSSize(width: 9, height: 9)
                    button.image = image
                }
                button.target = self
                button.action = #selector(secondaryClicked(_:))
                button.identifier = NSUserInterfaceItemIdentifier(
                    action == .editor ? "editor" : "terminal"
                )
                button.frame = NSRect(
                    x: action == .editor ? 2 : 15, y: 3, width: 11, height: 20
                )
                addSubview(button)
            }
        }
        editorButton.isHidden = true
        terminalButton.isHidden = true

        // Name truncates toward the chip's right edge.
        nameLabel.stringValue = chip.item.name
        nameLabel.textColor = theme.foreground
        nameLabel.frame = NSRect(
            x: 32, y: 6, width: max(chip.width - 32 - 8, 36), height: 14
        )

        switch chip.kind {
        case .favorite:
            glyphView.image = lucideImage(for: "folder", title: chip.item.name, color: theme.secondaryText)
            glyphView.isHidden = false
            dot.isHidden = true
        case .recent:
            glyphView.image = lucideImage(for: "clock", title: chip.item.name, color: theme.secondaryText)
            glyphView.isHidden = false
            dot.isHidden = true
        case .tagged:
            glyphView.isHidden = true
            dot.isHidden = false
            dot.layer?.backgroundColor = tagColor(for: chip.item.tag, dark: theme.isDark).cgColor
        }
        applyBackground(hovering: false)
    }

    private func applyBackground(hovering: Bool) {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = isSelectedChip
            ? theme.selectedFill.cgColor
            : (hovering ? theme.hoverFill.cgColor : NSColor.clear.cgColor)
        // Quiet hairline so chips read as contained cells on the glass
        // instead of loose text.
        layer?.borderColor = PanelStyle.controlBorder(dark: theme.isDark).cgColor
    }

    @objc private func secondaryClicked(_ sender: NSButton) {
        onSecondary?(sender.identifier?.rawValue == "editor" ? .editor : .terminal)
    }
}

/// Selection capsule row view (selectedFill on activation). Panels tune
/// `insetDx`/`insetDy` to their row rhythm — launcher uses the 8/2 default;
/// the clipboard panel tightens dx so the capsule padding around its row
/// content stays symmetric. `hoverFillColor` + `hovering` drive an opt-in
/// row hover wash (selection always wins over hover); the clipboard panel
/// sets `hovering` from its mouse-move monitor — tracking areas on table
/// row views proved unreliable.
final class LauncherRowView: NSTableRowView {
    var fillColor: NSColor = .clear
    var hoverFillColor: NSColor?
    var hovering = false
    var insetDx: CGFloat = PanelDesign.rowCapsuleInsetX
    var insetDy: CGFloat = PanelDesign.rowCapsuleInsetY

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        fillColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: insetDx, dy: insetDy), xRadius: 10, yRadius: 10).fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Hover wash drawn here, not in drawSelection: AppKit skips that
        // hook for unselected rows.
        guard hovering, !isSelected, let fill = hoverFillColor else { return }
        fill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: insetDx, dy: insetDy), xRadius: 10, yRadius: 10).fill()
    }
}

/// Running-app row: app icon + localized name.
final class LauncherAppCell: NSView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private var onActivate: (() -> Void)?
    private var didLayout = false

    override func mouseDown(with event: NSEvent) { onActivate?() }

    func configure(
        item: LauncherPanelController.RunningAppItem,
        theme: CardTheme,
        _ handler: @escaping () -> Void
    ) {
        onActivate = handler
        if !didLayout {
            iconView.frame = NSRect(x: 16, y: 8, width: 24, height: 24)
            addSubview(iconView)
            nameLabel.font = .systemFont(ofSize: 15)
            nameLabel.frame = NSRect(x: 50, y: 11, width: 440, height: 18)
            addSubview(nameLabel)
        }
        iconView.image = item.app.icon
        nameLabel.stringValue = item.name
        nameLabel.textColor = theme.foreground
    }
}

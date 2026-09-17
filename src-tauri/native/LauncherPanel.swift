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

    private static let panelWidth: CGFloat = 520
    private static let rowHeight: CGFloat = 42
    private static let headerHeight: CGFloat = 28
    private static let maxListHeight: CGFloat = 11 * LauncherPanelController.rowHeight
    private static let chromeHeight: CGFloat = 88 // search 12+26+8 + tabs 24+8 + bottom pad 10
    private static let recentsKey = "launcher.recents"

    private let panel: KeyablePanel
    private let root: FlippedView
    private let searchField = NSSearchField()
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
        case favorite(FolderItem)
        case folder(FolderItem)
        case recent(RecentItem)
        case app(RunningAppItem)
    }

    struct FolderItem { let path: String; let name: String; let tag: String }
    struct RecentItem: Codable, Equatable { var path: String; var count: Int; var lastAt: Double }
    struct RunningAppItem { let app: NSRunningApplication; let name: String }

    var rows: [Row] = []

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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let (background, content, _) = makePanelBackground(
            frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 240),
            cornerRadius: 14
        )
        panel.contentView = background
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
        searchField.font = .systemFont(ofSize: 13)
        (searchField.cell as? NSSearchFieldCell)?.sendsActionOnEndEditing = false
        searchField.wantsLayer = true
        searchField.delegate = self
        root.addSubview(searchField)

        for (button, title) in [(foldersTabButton, "Folders"), (appsTabButton, "Apps")] {
            button.title = title
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.bezelStyle = .recessed
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 7
            button.target = self
            root.addSubview(button)
        }
        foldersTabButton.action = #selector(tabClicked(_:))
        appsTabButton.action = #selector(tabClicked(_:))
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

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        root.addSubview(emptyLabel)

        syncTabButtons()
    }

    @objc private func tabClicked(_ sender: NSButton) {
        tab = sender.tag == 0 ? .folders : .apps
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
    }

    private func styleChrome() {
        // NSSearchField draws its own themed rounded chrome; painting the
        // backing layer (previous attempt) showed a SQUARE gray box behind
        // it. Its colors now come from the panel's vibrant appearance.
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
        if case .header = row { return Self.headerHeight }
        return Self.rowHeight
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
        let selectable = selectableRowIndexes()
        if let first = selectable.first {
            tableView.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
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
            if case .header = rows[row] { return false }
            return true
        }
    }

    /// Canonical home subfolders pinned to the top of the Folders tab
    /// (user-requested ordering: Favorites → Recent → tag groups). Displayed
    /// with the system-localized name (桌面/下载/…); only folders that
    /// actually exist are listed.
    private static let favoriteFolderNames = ["Desktop", "Documents", "Downloads", "Movies", "Pictures"]

    private func buildFolderRows() -> [Row] {
        let filter = filterText
        var out: [Row] = []

        let favorites = Self.favoriteFolderNames.compactMap { name -> FolderItem? in
            let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            let localizedName = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName ?? name
            guard filter.isEmpty
                || localizedName.lowercased().contains(filter)
                || name.lowercased().contains(filter)
                || url.path.lowercased().contains(filter)
            else { return nil }
            return FolderItem(path: url.path, name: localizedName, tag: "")
        }
        if !favorites.isEmpty {
            out.append(.header("Favorites"))
            out += favorites.map { .favorite($0) }
        }

        let recentMatches = recents.filter { item in
            filter.isEmpty
                || item.path.lowercased().contains(filter)
                || URL(fileURLWithPath: item.path).lastPathComponent.lowercased().contains(filter)
        }
        if !recentMatches.isEmpty {
            out.append(.header("Recent"))
            out += recentMatches.map { .recent($0) }
        }

        let matching = taggedFolders.filter { item in
            filter.isEmpty
                || item.name.lowercased().contains(filter)
                || item.path.lowercased().contains(filter)
        }
        let grouped = Dictionary(grouping: matching) { $0.tag.isEmpty ? "Untagged" : $0.tag }
        for tag in grouped.keys.sorted() {
            out.append(.header(tag))
            out += grouped[tag]!
                .sorted { $0.name.lowercased() < $1.name.lowercased() }
                .map { .folder($0) }
        }
        return out
    }

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

    // MARK: running apps

    private func buildAppRows() -> [Row] {
        let filter = filterText
        let own = ProcessInfo.processInfo.processIdentifier
        var apps = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular
                && app.bundleIdentifier != nil
                && app.processIdentifier != own
                && (filter.isEmpty
                    || (app.localizedName ?? "").lowercased().contains(filter))
        }
        let front = apps.first { $0.isActive }
        apps.removeAll { $0 == front }
        apps.sort { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        if let front { apps.insert(front, at: 0) }
        return apps.map { RunningAppItem(app: $0, name: $0.localizedName ?? $0.bundleIdentifier ?? "?") }
            .map { Row.app($0) }
    }

    private func activateApp(_ item: RunningAppItem) {
        if #available(macOS 14.0, *) {
            _ = item.app.activate()
        } else {
            _ = item.app.activate(options: [.activateIgnoringOtherApps])
        }
        hide(notify: false)
    }

    private func activateRow(_ index: Int) {
        guard index >= 0, index < rows.count else { return }
        switch rows[index] {
        case .favorite(let item): openPath(item.path, target: .finder)
        case .folder(let item): openPath(item.path, target: .finder)
        case .recent(let item): openPath(item.path, target: .finder)
        case .app(let item): activateApp(item)
        case .header: break
        }
    }

    // MARK: keyboard

    private func moveSelection(_ delta: Int) {
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
    }

    private func activateSelected() {
        let row = tableView.selectedRow
        if row >= 0, row < rows.count {
            activateRow(row)
        } else if let first = selectableRowIndexes().first {
            activateRow(first)
        }
    }

    // NSSearchFieldDelegate — arrows/table/Enter/Tab/Esc while the search
    // field holds first responder.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case NSSelectorFromString("moveUp:"):
            moveSelection(-1)
            return true
        case NSSelectorFromString("moveDown:"):
            moveSelection(1)
            return true
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
        case .favorite(let item):
            let cell = reuse(LauncherFolderCell.self, row: row)
            cell.configure(
                item: item,
                theme: cardTheme,
                showsEditor: editorAppURL != nil,
                missing: false,
                iconInsteadOfDot: true
            ) { [weak self] action in
                guard let self else { return }
                switch action {
                case .row: self.openPath(item.path, target: .finder)
                case .editor: self.openPath(item.path, target: .editor)
                case .terminal: self.openPath(item.path, target: .terminal)
                }
            }
            return cell
        case .folder(let item):
            let cell = reuse(LauncherFolderCell.self, row: row)
            cell.configure(
                item: item,
                theme: cardTheme,
                showsEditor: editorAppURL != nil,
                missing: !FileManager.default.fileExists(atPath: item.path)
            ) { [weak self] action in
                guard let self else { return }
                switch action {
                case .row: self.openPath(item.path, target: .finder)
                case .editor: self.openPath(item.path, target: .editor)
                case .terminal: self.openPath(item.path, target: .terminal)
                }
            }
            return cell
        case .recent(let item):
            let cell = reuse(LauncherFolderCell.self, row: row)
            cell.configure(
                item: FolderItem(path: item.path, name: URL(fileURLWithPath: item.path).lastPathComponent, tag: ""),
                theme: cardTheme,
                showsEditor: editorAppURL != nil,
                missing: !FileManager.default.fileExists(atPath: item.path)
            ) { [weak self] action in
                guard let self else { return }
                switch action {
                case .row: self.openPath(item.path, target: .finder)
                case .editor: self.openPath(item.path, target: .editor)
                case .terminal: self.openPath(item.path, target: .terminal)
                }
            }
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
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = color
        if !didLayout {
            didLayout = true
            label.frame = NSRect(x: 16, y: 8, width: 480, height: 14)
            addSubview(label)
        }
    }
}

/// Folder / recent row: tag dot, name, parent path, editor + terminal buttons.
final class LauncherFolderCell: NSView {
    enum Action { case row, editor, terminal }

    private let dot = NSView()
    private let folderIcon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let editorButton = HoverIconButton(frame: .zero)
    private let terminalButton = HoverIconButton(frame: .zero)
    private var onAction: ((Action) -> Void)?
    private var hoverArea: NSTrackingArea?
    private var didLayout = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseDown(with event: NSEvent) { onAction?(.row) }

    func configure(
        item: LauncherPanelController.FolderItem,
        theme: CardTheme,
        showsEditor: Bool,
        missing: Bool,
        iconInsteadOfDot: Bool = false,
        _ handler: @escaping (Action) -> Void
    ) {
        onAction = handler
        alphaValue = missing ? 0.45 : 1.0
        if !didLayout {
            didLayout = true
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.frame = NSRect(x: 16, y: 18, width: 6, height: 6)
            addSubview(dot)
            folderIcon.frame = NSRect(x: 13, y: 13, width: 15, height: 15)
            addSubview(folderIcon)

            nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
            // Two stacked lines in a NON-flipped cell: y measured from the
            // BOTTOM. Name on top, path below — the old frames (y 8 and 3)
            // overlapped by 7pt.
            nameLabel.frame = NSRect(x: 30, y: 23, width: 340, height: 15)
            addSubview(nameLabel)

            pathLabel.font = .systemFont(ofSize: 11)
            pathLabel.frame = NSRect(x: 30, y: 5, width: 340, height: 13)
            addSubview(pathLabel)

            terminalButton.frame = NSRect(x: 448, y: 10, width: 22, height: 22)
            terminalButton.toolTip = "Open in Terminal"
            addSubview(terminalButton)

            editorButton.frame = NSRect(x: 474, y: 10, width: 22, height: 22)
            editorButton.toolTip = "Open in Editor"
            addSubview(editorButton)
        }
        nameLabel.stringValue = item.name
        let parent = (item.path as NSString).deletingLastPathComponent
        pathLabel.stringValue = parent.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        if iconInsteadOfDot {
            dot.isHidden = true
            folderIcon.isHidden = false
            folderIcon.image = lucideImage(for: "folder", title: item.name, color: theme.secondaryText)
        } else {
            dot.layer?.backgroundColor = item.tag.isEmpty
                ? NSColor.clear.cgColor
                : tagColor(for: item.tag, dark: theme.isDark).cgColor
            dot.isHidden = item.tag.isEmpty
            folderIcon.isHidden = true
        }
        nameLabel.textColor = theme.foreground
        pathLabel.textColor = theme.secondaryText

        editorButton.isHidden = !showsEditor
        if let editorImage = lucideImage(for: "code", title: "Editor", color: theme.iconTint) {
            editorButton.image = editorImage
        }
        if let terminalImage = lucideImage(for: "terminal", title: "Terminal", color: theme.iconTint) {
            terminalButton.image = terminalImage
        }
        editorButton.target = self
        editorButton.action = #selector(editorClicked)
        terminalButton.target = self
        terminalButton.action = #selector(terminalClicked)
    }

    @objc private func editorClicked() { onAction?(.editor) }
    @objc private func terminalClicked() { onAction?(.terminal) }
}

/// Selection capsule row view (selectedFill on activation).
final class LauncherRowView: NSTableRowView {
    var fillColor: NSColor = .clear

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        fillColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 2), xRadius: 7, yRadius: 7).fill()
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
            didLayout = true
            iconView.frame = NSRect(x: 16, y: 11, width: 20, height: 20)
            addSubview(iconView)
            nameLabel.font = .systemFont(ofSize: 13)
            nameLabel.frame = NSRect(x: 46, y: 13, width: 440, height: 16)
            addSubview(nameLabel)
        }
        iconView.image = item.app.icon
        nameLabel.stringValue = item.name
        nameLabel.textColor = theme.foreground
    }
}

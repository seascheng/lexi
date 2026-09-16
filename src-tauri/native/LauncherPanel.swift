import AppKit

/// Launcher panel — double-Shift surface for jumping to tagged folders,
/// recent folders and running apps.
///
/// Top-level isolated from the toolbar/result-card/notes flows: it owns its
/// panel, data and actions. Shared bottom layers only: `KeyablePanel`,
/// `makePanelBackground`, `CardTheme`, `lucideImage`, `tagColor`, `FileLog`
/// (SelectionToolbarHelper.swift) and the TCP dispatch in
/// `SelectionToolbarApp.handleRequestData`.
final class LauncherPanelController: NSObject, NSWindowDelegate {
    /// Fired whenever the panel hides itself (Esc / focus loss); the app
    /// controller wires this to its action channel ("launcher-hidden").
    var onHidden: (() -> Void)?

    private static let panelWidth: CGFloat = 520
    private static let rowHeight: CGFloat = 34
    private static let headerHeight: CGFloat = 26
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
        case folder(FolderItem)
        case recent(RecentItem)
        case app(RunningAppItem)
    }

    struct FolderItem { let path: String; let name: String; let tag: String }
    struct RecentItem: Codable, Equatable { var path: String; var count: Int; var lastAt: Double }
    struct RunningAppItem { let app: NSRunningApplication; let name: String }

    var rows: [Row] = []

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
        searchField.layer?.backgroundColor = cardTheme.inputFill.cgColor
        searchField.layer?.borderColor = cardTheme.hairline.cgColor
        searchField.layer?.borderWidth = 0.5
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

    // MARK: data (empty shell — Task 4/5 fill in)

    func reload() {
        rows = []
        tableView.reloadData()
        emptyLabel.isHidden = false
        emptyLabel.stringValue = "No tagged folders — tag folders in Finder to list them here"
        placePanel()
    }
}

/// Top-down layout container (row 0 = the top edge).
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

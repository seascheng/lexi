import AppKit

/// Clipboard panel — Alt+V surface for browsing captured clipboard history
/// and pasting an entry back into the app that was frontmost when the panel
/// opened.
///
/// Top-level isolated from the toolbar/result-card/notes/launcher flows: it
/// owns its panel, data (ClipboardStore/ClipboardMonitor) and actions.
/// Shared bottom layers only: `KeyablePanel`, `makePanelBackground`,
/// `CardTheme`, `FlippedView`, `LauncherRowView` (SelectionToolbarHelper.swift
/// / LauncherPanel.swift) and the TCP dispatch in
/// `SelectionToolbarApp.handleRequestData`.
///
/// Layout follows hapigo's clipboard: search field, colored-dot filter chips,
/// variable-height preview rows with source-app icons, and a footer status
/// strip — drawn entirely in the helper's existing goty visual language
/// (CardTheme fills, selectedFill capsule, hairlines).
final class ClipboardPanelController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    /// Fired whenever the panel hides itself (Esc / focus loss / toggle).
    var onHidden: (() -> Void)?

    private static let panelWidth: CGFloat = 520
    static let singleLineHeight: CGFloat = 32
    static let twoLineHeight: CGFloat = 50
    private static let headerHeight: CGFloat = 28
    private static let maxListHeight: CGFloat = 11 * ClipboardPanelController.twoLineHeight
    private static let chromeHeight: CGFloat = 146 // search 12+26+8 + chips 24+8 + footer 24 + hairline/pads
    private static let side: CGFloat = 12

    /// Colored filter chips (hapigo's category row). Fixed five in v1;
    /// semantics are tinycast's exclusive ClipboardFilter.
    private static let chips: [(title: String, color: NSColor, filter: ClipboardFilter)] = [
        ("全部", NSColor.systemGray, .all),
        ("置顶", NSColor.systemPink, .pinned),
        ("文本", NSColor.systemBlue, .text),
        ("链接", NSColor.systemGreen, .link),
        ("文件", NSColor.systemOrange, .file),
    ]

    private let panel: KeyablePanel
    private let root: FlippedView
    private let glassContent: NSView
    private let searchField = NSSearchField()
    private var chipViews: [ChipPillView] = []
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let footerLeft = NSTextField(labelWithString: "")
    private let footerRight = NSTextField(labelWithString: "")
    private var cardTheme: CardTheme = .dark

    /// Set once at helper startup; the monitor keeps filling it.
    private var store: ClipboardStore?
    private var filter: ClipboardFilter = .all
    private var rows: [Row] = []
    /// Flat selectable items in display order — footer counts and paste
    /// target resolution read from here.
    private var visibleItems: [ClipboardItem] = []
    /// Small live cache of decoded thumbnails so scrolling doesn't re-read
    /// PNGs. Image rows only.
    private var thumbnailCache: [UUID: NSImage] = [:]

    /// The app that was frontmost when the panel opened — the paste target.
    private var previousApp: NSRunningApplication?

    /// Temporary footer message (e.g. vanished file) that self-clears on the
    /// next selection change or reload.
    private var footerNoticeUntil: Date?

    enum Row {
        case header(String)
        case clip(ClipboardItem)
    }

    private var selectedRow: Int {
        get { tableView.selectedRow }
        set {
            guard newValue >= 0, rows.indices.contains(newValue) else { return }
            tableView.selectRowIndexes(IndexSet(integer: newValue), byExtendingSelection: false)
            tableView.scrollRowToVisible(newValue)
        }
    }

    private var selectedItem: ClipboardItem? {
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count, case .clip(let item) = rows[row] else { return nil }
        return item
    }

    override init() {
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 300),
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
            frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 300),
            cornerRadius: 14
        )
        panel.contentView = background
        glassContent = content
        glassContent.wantsLayer = true
        root = FlippedView(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 300))
        content.addSubview(root)
        super.init()
        panel.delegate = self
        // ⌘P (pin toggle) arrives as a key equivalent — the search field's
        // command path never sees modifier combos.
        panel.keyEquivalentHandler = { [weak self] event in
            guard event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers == "p" else { return false }
            self?.togglePinSelected()
            return true
        }
        buildChrome()
        applyTheme(dark: true)
    }

    /// Wired once at helper launch (after the TCP server is up).
    func attach(store: ClipboardStore) {
        self.store = store
    }

    // MARK: show / hide

    func show() {
        // Toggle: a repeat press of the hotkey closes instead of re-flashing.
        if panel.isVisible {
            hide(notify: true)
            return
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        searchField.stringValue = ""
        filter = .all
        syncChips()
        reload()
        placePanel()
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
        for chip in chipViews { chip.applyTheme(cardTheme) }
        tableView.reloadData()
    }

    // MARK: chrome

    private func buildChrome() {
        searchField.frame = NSRect(x: Self.side, y: 12, width: Self.panelWidth - Self.side * 2, height: 26)
        searchField.placeholderString = "输入关键词搜索"
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 13)
        (searchField.cell as? NSSearchFieldCell)?.sendsActionOnEndEditing = false
        searchField.wantsLayer = true
        searchField.delegate = self
        root.addSubview(searchField)

        for chip in Self.chips {
            let view = ChipPillView(frame: NSRect(x: 0, y: 46, width: 64, height: 24))
            view.configure(title: chip.title, color: chip.color) { [weak self] in
                guard let self, self.filter != chip.filter else { return }
                self.filter = chip.filter
                self.syncChips()
                self.reload()
            }
            chipViews.append(view)
            root.addSubview(view)
        }

        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.usesAutomaticRowHeights = false
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ClipboardColumn"))
        tableView.addTableColumn(column)
        scrollView.documentView = tableView
        // Without these the table renders zero rows — the dataSource/delegate
        // methods on self are the entire list pipeline (launcher lesson).
        tableView.dataSource = self
        tableView.delegate = self
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        root.addSubview(scrollView)

        // Double-click pastes, same as Enter.
        tableView.target = self
        tableView.action = #selector(rowDoubleClicked)


        footerLeft.font = .systemFont(ofSize: 11)
        footerRight.font = .systemFont(ofSize: 11)
        footerRight.alignment = .right
        root.addSubview(footerLeft)
        root.addSubview(footerRight)

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.alignment = .center
        emptyLabel.stringValue = "暂无粘贴板历史 — 复制任意内容开始"
        emptyLabel.isHidden = true
        root.addSubview(emptyLabel)
    }

    private func syncChips() {
        for (index, chip) in chipViews.enumerated() {
            chip.setSelected(Self.chips[index].filter == filter)
        }
    }

    private func styleChrome() {
        // Contrast scrim: raw NSGlassEffectView washes out on dark
        // wallpapers (same veil the launcher and card use).
        glassContent.layer?.backgroundColor = (cardTheme.isDark
            ? NSColor.black.withAlphaComponent(0.30)
            : NSColor.white.withAlphaComponent(0.42)).cgColor
        emptyLabel.textColor = cardTheme.tertiaryText
        footerLeft.textColor = cardTheme.secondaryText
        footerRight.textColor = cardTheme.tertiaryText
    }

    private func layoutChrome(height: CGFloat) {
        var x = Self.side
        for chip in chipViews {
            let width = max(chip.fittingSize.width + 26, 56)
            chip.frame = NSRect(x: x, y: 46, width: width, height: 24)
            x = chip.frame.maxX + 6
        }
        scrollView.frame = NSRect(x: 0, y: 78, width: Self.panelWidth, height: height - Self.chromeHeight)
        emptyLabel.frame = NSRect(x: Self.side, y: 78, width: Self.panelWidth - Self.side * 2, height: 40)
        let footerY = height - 24
        footerLeft.frame = NSRect(x: 16, y: footerY + 5, width: 240, height: 14)
        footerRight.frame = NSRect(x: Self.panelWidth - 266, y: footerY + 5, width: 250, height: 14)
    }

    /// Top-anchored adaptive height: capped list, 200–560pt total (a taller
    /// ceiling than the launcher — multi-line previews need the room).
    private var panelHeight: CGFloat {
        let listHeight = min(rows.reduce(0.0) { $0 + rowHeight(for: $1) }, Self.maxListHeight)
        return min(max(Self.chromeHeight + max(listHeight, Self.singleLineHeight * 3), 200), 560)
    }

    private func rowHeight(for row: Row) -> CGFloat {
        switch row {
        case .header: return Self.headerHeight
        case .clip(let item):
            if item.kind == .file { return Self.twoLineHeight }
            guard let text = item.previewText else { return Self.twoLineHeight }
            // User rule: wrap automatically, show at most TWO lines, then …
            switch Self.previewLineCount(for: text) {
            case 1: return Self.singleLineHeight
            default: return Self.twoLineHeight
            }
        }
    }

    /// Measured wrapped-line count for a 452pt column: lay the text out in a
    /// throwaway wrapping label and count line heights. The char-width
    /// heuristic (latin 6.5pt / CJK 13pt) misjudged percent-encoded URLs and
    /// dense CJK, which is how rows came out one-line-tall with two-line
    /// content. User rule: at most TWO preview lines.
    static func previewLineCount(for text: String) -> Int {
        let measuring = NSTextField(wrappingLabelWithString: text)
        measuring.font = .systemFont(ofSize: 13)
        let bounds = NSRect(x: 0, y: 0, width: 452, height: 10_000)
        let needed = measuring.cell!.cellSize(forBounds: bounds).height
        return max(1, min(2, Int(ceil(needed / 16))))
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
        guard let store else {
            rows = []
            visibleItems = []
            updateFooter()
            emptyLabel.isHidden = false
            placePanel()
            return
        }
        let found = store.search(searchField.stringValue, filter: filter)
        // The store returns pinned rows leading (pin order) — split them into
        // their section header block; recency rows follow unwrapped.
        let pinned = found.prefix { $0.pinnedAt != nil }
        let rest = found.dropFirst(pinned.count)
        rows = []
        if !pinned.isEmpty {
            rows.append(.header("置顶"))
            rows += pinned.map { Row.clip($0) }
        }
        rows += rest.map { Row.clip($0) }
        visibleItems = Array(found)

        thumbnailCache = thumbnailCache.filter { id, _ in found.contains { $0.id == id } }
        tableView.reloadData()

        emptyLabel.isHidden = !rows.isEmpty
        emptyLabel.stringValue = rows.isEmpty && filter != .all
            ? "该分类暂无匹配内容"
            : "暂无粘贴板历史 — 复制任意内容开始"
        if let firstSelectable = rows.indices.first(where: {
            if case .clip = rows[$0] { return true }
            return false
        }) {
            tableView.selectRowIndexes(IndexSet(integer: firstSelectable), byExtendingSelection: false)
        }
        updateFooter()
        placePanel()
    }

    private func updateFooter() {
        if let until = footerNoticeUntil, Date() < until {
            return // a notice is showing; it clears on the next interaction
        }
        footerNoticeUntil = nil
        let row = tableView.selectedRow
        let ordinal = row >= 0 ? row + 1 : 0
        footerRight.stringValue = "⌘P 置顶 · ⌫ 删除 · ↩ 粘贴"
    }

    private func showFooterNotice(_ text: String) {
        footerNoticeUntil = Date().addingTimeInterval(2)
        footerLeft.stringValue = text
    }

    // MARK: actions

    /// ⌘P lands here via KeyablePanel.keyEquivalentHandler.
    func togglePinSelected() {
        guard let store, let item = selectedItem else { return }
        let wasPinned = item.pinnedAt != nil
        store.setPinned(item, pinned: !wasPinned)
        reload()
        // Follow the row to its new position (unpin re-recencies it). The
        // pinned section contributes one header row above the flat list.
        let hasPinnedSection = visibleItems.first?.pinnedAt != nil
        if let newIndex = visibleItems.firstIndex(where: { $0.id == item.id }) {
            selectedRow = newIndex + (hasPinnedSection ? 1 : 0)
        }
        updateFooter()
    }

    private func deleteSelected() {
        guard let store, let item = selectedItem else { return }
        store.delete(item)
        reload()
    }

    private func pasteSelected() {
        guard let store, let item = selectedItem else { return }
        if ClipboardPaster.paste(item, store: store, previousApp: previousApp) {
            hide(notify: true)
        } else if item.kind == .file {
            // A vanished file is reported, never silently swallowed and never
            // auto-deleted — history is a record of what happened.
            showFooterNotice("文件已不存在 — \(item.text ?? "")")
        }
    }

    @objc private func rowDoubleClicked() {
        pasteSelected()
    }

    // MARK: keyboard

    private func moveVertical(_ delta: Int) {
        let selectable = rows.indices.filter {
            if case .clip = rows[$0] { return true }
            return false
        }
        guard !selectable.isEmpty else { return }
        let current = tableView.selectedRow
        let next: Int
        if current >= 0, let position = selectable.firstIndex(of: current) {
            next = selectable[min(max(position + delta, 0), selectable.count - 1)]
        } else {
            next = delta > 0 ? selectable[0] : selectable[selectable.count - 1]
        }
        selectedRow = next
        updateFooter()
    }

    private func cycleFilter(_ delta: Int) {
        let all = Self.chips.map(\.filter)
        guard let index = all.firstIndex(of: filter) else { return }
        filter = all[(index + delta + all.count) % all.count]
        syncChips()
        reload()
    }

    // NSSearchFieldDelegate — arrows/Enter/Tab/Esc/⌫ while the search field
    // holds first responder.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case NSSelectorFromString("moveUp:"):
            moveVertical(-1)
            return true
        case NSSelectorFromString("moveDown:"):
            moveVertical(1)
            return true
        case NSSelectorFromString("insertNewline:"):
            pasteSelected()
            return true
        case NSSelectorFromString("insertTab:"):
            cycleFilter(1)
            return true
        case NSSelectorFromString("deleteBackward:"):
            if searchField.stringValue.isEmpty {
                deleteSelected()
                return true
            }
            return false // editing the query — let the field handle it
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
        guard row < rows.count else { return Self.singleLineHeight }
        return rowHeight(for: rows[row])
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard row < rows.count else { return false }
        if case .header = rows[row] { return false }
        return true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateFooter()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        switch rows[row] {
        case .header(let title):
            let cell = reuse(ClipboardHeaderCell.self, row: row)
            cell.configure(title: title, color: cardTheme.secondaryText)
            return cell
        case .clip(let item):
            let cell = reuse(ClipCell.self, row: row)
            cell.configure(
                item: item, theme: cardTheme, height: rowHeight(for: rows[row]),
                thumbnail: thumbnail(for: item),
                sourceIcon: ClipboardMonitor.shared.cachedIcon(forBundleID: item.sourceBundleID))
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
        // Capsule 6..514 on the 520pt row — visible floating margin from the
        // panel edge, and it pads the row content (icon at 12, text ends at
        // 508) by 6pt on each side.
        view.insetDx = 6
        view.insetDy = 2
        return view
    }

    private func thumbnail(for item: ClipboardItem) -> NSImage? {
        guard item.kind == .image else { return nil }
        guard let store, let url = store.imageURL(for: item) else {
            return nil
        }
        let image = NSImage(contentsOf: url)
        image?.size = NSSize(width: 40, height: 40)
        if let image {
            thumbnailCache[item.id] = image
        }
        return image
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

/// Paste-back (tinycast Paster contract): write the item's flavors plus the
/// internal marker so the poller skips our own write, activate the app that
/// was frontmost before the panel, then synthesize the full ⌘V sequence from
/// a combinedSessionState source. The pasted item BECOMES the clipboard —
/// standard clipboard-manager semantics, no restore lease here.
enum ClipboardPaster {
    /// Covers the gap between `activate()` returning and the target app
    /// accepting a keystroke (tinycast activationDelay).
    private static let activationDelay: TimeInterval = 0.08

    @discardableResult
    static func paste(
        _ item: ClipboardItem, store: ClipboardStore, previousApp: NSRunningApplication?
    ) -> Bool {
        guard write(item, store: store) else { return false }
        previousApp?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay) {
            postCommandV()
        }
        return true
    }

    /// Flavor sets by kind — a file carries BOTH `public.file-url` (file
    /// takers receive the file) and `.string` with the PATH (text fields and
    /// terminals want the path; a name is recoverable from a path, a path is
    /// not recoverable from a name). Every write appends the empty internal
    /// marker; the poller then skips it, so `promote` here is the only
    /// history reordering a paste causes. Pinned rows skip promote inside
    /// the store — pasting a pin holds its place.
    private static func write(_ item: ClipboardItem, store: ClipboardStore) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text:
            guard let text = item.text else { return false }
            pb.declareTypes([.string, ClipboardMonitor.internalType], owner: nil)
            pb.setString(text, forType: .string)
        case .image:
            guard let url = store.imageURL(for: item), let data = try? Data(contentsOf: url) else {
                return false
            }
            pb.declareTypes([.png, ClipboardMonitor.internalType], owner: nil)
            pb.setData(data, forType: .png)
        case .file:
            guard let path = item.filePath,
                  FileManager.default.fileExists(atPath: path)
            else { return false }
            let url = URL(fileURLWithPath: path)
            pb.declareTypes([.fileURL, .string, ClipboardMonitor.internalType], owner: nil)
            pb.setData(url.dataRepresentation, forType: .fileURL)
            pb.setString(url.path, forType: .string)
        }
        store.promote(item)
        return true
    }

    /// Combined-session source + command flag on the down event: Chromium
    /// hosts ignore pid-posted synthetic keys, session-tap events ride the
    /// normal dispatch path and are honored like real ones.
    private static func postCommandV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let vKey: CGKeyCode = 9 // kVK_ANSI_V
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return }
        down.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        usleep(20_000)
        up.flags = .maskCommand
        up.post(tap: .cghidEventTap)
    }
}

/// Filter chip: colored dot + label, selectedFill capsule when active —
/// the launcher tab-pill grammar with hapigo's dots.
final class ChipPillView: NSView {
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")
    private var chipColor: NSColor = .systemGray
    private var onActivate: (() -> Void)?
    private var selected = false
    private var theme: CardTheme = .dark
    private var hoverArea: NSTrackingArea?
    private var hovering = false
    private var didLayout = false

    override var isFlipped: Bool { true }

    func configure(title: String, color: NSColor, onActivate: @escaping () -> Void) {
        self.onActivate = onActivate
        chipColor = color
        if !didLayout {
            didLayout = true
            wantsLayer = true
            layer?.cornerRadius = 12

            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.5
            dot.frame = NSRect(x: 11, y: 8, width: 7, height: 7)
            addSubview(dot)

            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x: 24, y: 4, width: 80, height: 16)
            addSubview(label)
        }
        label.stringValue = title
        applyTheme(theme)
    }

    func applyTheme(_ theme: CardTheme) {
        self.theme = theme
        label.textColor = theme.foreground
        applyBackground()
    }

    func setSelected(_ selected: Bool) {
        self.selected = selected
        applyBackground()
    }

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
        hovering = true
        applyBackground()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        applyBackground()
    }

    override func mouseDown(with event: NSEvent) { onActivate?() }

    private func applyBackground() {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = selected
            ? theme.selectedFill.cgColor
            : (hovering ? theme.hoverFill.cgColor : NSColor.clear.cgColor)
        layer?.borderWidth = selected ? 0 : 0.5
        layer?.borderColor = theme.isDark
            ? NSColor.white.withAlphaComponent(0.10).cgColor
            : NSColor.black.withAlphaComponent(0.08).cgColor
        dot.layer?.backgroundColor = chipColor.cgColor
    }
}

/// Section header row (「固定」).
final class ClipboardHeaderCell: NSView {
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

/// Clipboard row, laid out with Auto Layout constraints (declared once, the
/// system solves positions — no hand-computed frames to drift). Geometry:
///
///   icon: leading 16, 24×24, vertically centered
///   text: leading icon+10, trailing ≤ superview-16
///   selection capsule (insetDx 6 → 6..514): pads the content 10pt per side
///
/// Rows show exactly one of: single-line text (name label, centered),
/// wrapping text (up to 2 lines, fills the row), file (name over dim path),
/// image (40pt thumbnail; quiet placeholder while it decodes).
final class ClipCell: NSView {
    private let iconView = NSImageView()
    private let thumbnailView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")  // single-line text / file name
    private let pathLabel = NSTextField(labelWithString: "")  // file path (dim)
    private let previewLabel = NSTextField(wrappingLabelWithString: "")
    private var installed = false
    private var nameCenterY: NSLayoutConstraint!
    private var nameTop: NSLayoutConstraint!

    func configure(
        item: ClipboardItem, theme: CardTheme, height: CGFloat,
        thumbnail: NSImage?, sourceIcon: NSImage?
    ) {
        installConstraints()

        nameLabel.isHidden = true
        pathLabel.isHidden = true
        previewLabel.isHidden = true
        thumbnailView.isHidden = true

        switch item.kind {
        case .text:
            // Single-line rows center the name label; taller rows use the
            // wrapping preview that fills the row.
            nameTop.isActive = false
            nameCenterY.isActive = height <= ClipboardPanelController.singleLineHeight + 1
            if nameCenterY.isActive {
                nameLabel.font = .systemFont(ofSize: 13)
                nameLabel.textColor = theme.foreground
                nameLabel.stringValue = item.previewText ?? ""
                nameLabel.lineBreakMode = .byTruncatingTail
                nameLabel.cell?.usesSingleLineMode = true
                nameLabel.isHidden = false
            } else {
                previewLabel.font = .systemFont(ofSize: 13)
                previewLabel.textColor = theme.foreground
                previewLabel.stringValue = item.previewText ?? ""
                previewLabel.isHidden = false
            }
        case .file:
            let url = URL(fileURLWithPath: item.text ?? "")
            nameCenterY.isActive = false
            nameTop.isActive = true
            nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
            nameLabel.textColor = theme.foreground
            nameLabel.stringValue = url.lastPathComponent
            nameLabel.lineBreakMode = .byTruncatingTail
            nameLabel.cell?.usesSingleLineMode = true
            nameLabel.isHidden = false
            pathLabel.font = .systemFont(ofSize: 11)
            pathLabel.textColor = theme.tertiaryText
            pathLabel.stringValue = url.deletingLastPathComponent().path
            pathLabel.lineBreakMode = .byTruncatingMiddle
            pathLabel.cell?.usesSingleLineMode = true
            pathLabel.isHidden = false
        case .image:
            if let thumbnail {
                thumbnailView.image = thumbnail
                thumbnailView.isHidden = false
            }
            // Without a decoded thumbnail yet, a quiet placeholder keeps the
            // row from looking broken.
            previewLabel.font = .systemFont(ofSize: 12)
            previewLabel.textColor = theme.tertiaryText
            previewLabel.stringValue = "图片"
            previewLabel.alignment = .center
            previewLabel.isHidden = thumbnail != nil
        }
        iconView.image = sourceIcon
    }

    private func installConstraints() {
        guard !installed else { return }
        installed = true
        for view in [iconView, thumbnailView, nameLabel, pathLabel, previewLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // ORDER MATTERS: on NSTextField, setting lineBreakMode to a truncating
        // mode (.byTruncatingTail) resets cell.wraps to false — ONE line only.
        // Word wrap + maximumNumberOfLines(2) gives the two-line preview with
        // an automatic trailing … from TextKit.
        previewLabel.lineBreakMode = .byWordWrapping
        previewLabel.cell?.wraps = true
        previewLabel.maximumNumberOfLines = 2

        let iconSize = ClipboardMonitor.iconDisplaySize
        iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16).isActive = true
        iconView.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        iconView.widthAnchor.constraint(equalToConstant: iconSize).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: iconSize).isActive = true

        thumbnailView.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10).isActive = true
        thumbnailView.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        thumbnailView.widthAnchor.constraint(equalToConstant: 40).isActive = true
        thumbnailView.heightAnchor.constraint(equalToConstant: 40).isActive = true

        for label in [nameLabel, pathLabel, previewLabel] {
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10).isActive = true
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16).isActive = true
        }
        previewLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7).isActive = true
        previewLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7).isActive = true
        pathLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8).isActive = true

        nameCenterY = nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        nameTop = nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8)
    }
}

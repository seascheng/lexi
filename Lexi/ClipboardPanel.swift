import AppKit

/// Clipboard panel — Alt+V surface with two content layers behind one chip
/// row (hapigo's design): the first chip is the **Clipboard** history; every
/// note tag becomes a chip showing that category's notes; the trailing ⊕
/// chip creates a new category. Enter pastes into the app that was frontmost
/// when the panel opened — for clips AND for notes (a note is a permanent
/// clipboard entry; its content is what gets pasted).
///
/// Top-level isolated from the toolbar/result-card/notes/launcher flows: it
/// owns its panel, data (ClipboardStore/ClipboardMonitor + a notes snapshot
/// pushed over the same /card-notes feed the ActionPanel uses) and actions.
/// Shared bottom layers only: `KeyablePanel`, `makePanelBackground`,
/// `CardTheme`, `FlippedView`, `LauncherRowView`, `lucideImage`, `tagColor`,
/// `PanelDesign` (SelectionToolbarHelper.swift / LauncherPanel.swift) and the
/// TCP dispatch in `SelectionToolbarApp.handleRequestData`.
///
/// Layout follows hapigo's clipboard: chip tab row, search field, variable
/// preview rows with source-app icons, and a footer status strip — drawn in
/// the helper's goty visual language via the shared `PanelDesign` tokens.
final class ClipboardPanelController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    /// Fired whenever the panel hides itself (Esc / focus loss / toggle).
    var onHidden: (() -> Void)?

    /// Action channel back to lexi (the app delegate wires this to its TCP
    /// postAction): currently the ⊕ create-category request.
    var onAction: ((String, String) -> Void)?

    /// Fixed card size: width trimmed below the shared 520 token, height
    /// constant so switching tabs never resizes or moves the window — the
    /// top-left corner stays pinned where the cursor put it.
    static let panelWidth: CGFloat = 460
    static let panelHeight: CGFloat = 560
    private static let side: CGFloat = PanelDesign.sideInset

    /// The category that absorbs uncategorized notes in the chip tabs.
    private static let defaultTag = "Tmp"

    private let panel: KeyablePanel

    /// Whether THIS panel owns the keyboard (the app-level Tab router needs
    /// it: panels are independent, Tab goes to whoever is key).
    var isKeyWindow: Bool { panel.isKeyWindow }

    /// Tab from the app-level router: cycle this panel's chip tabs.
    func cycleChipTabs() { cycleTabs(1) }

    private let root: FlippedView
    private let glassContent: NSView
    private let searchField = NSSearchField()
    private var chipViews: [(kind: ChipKind, view: ChipPillView)] = []
    private let scrollView = NSScrollView()
    private let tableView = ClipTable()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let footerLeft = NSTextField(labelWithString: "")
    private let footerRight = NSTextField(labelWithString: "")
    private var cardTheme: CardTheme = .dark

    /// Set once at helper startup; the monitor keeps filling it.
    private var store: ClipboardStore?
    private var rows: [Row] = []
    /// Flat selectable clips in display order (clipboard tab only).
    private var visibleItems: [ClipboardItem] = []
    /// Small live cache of decoded thumbnails so scrolling doesn't re-read
    /// PNGs. Image rows only.
    private var thumbnailCache: [UUID: NSImage] = [:]

    /// Notes snapshot (fed by the /card-notes push) + the tags table names.
    private var notes: [ClipboardNote] = []
    private var allTags: [String] = []

    /// Which chip is active. `.clipboard` shows the history; `.tag(name)`
    /// shows that category's notes.
    private var tab: Tab = .clipboard
    /// Inline "new category" input at the end of the chip row — hidden until
    /// the ＋ button is clicked.
    private let tagInputView = ChipInputView()
    private let addChip = ChipPillView(frame: NSRect(x: 0, y: 4, width: 32, height: PanelDesign.pillHeight))
    private let chipsScrollView = NSScrollView()
    private var chipsContent = FlippedView(frame: .zero)
    /// The app that was frontmost when the panel opened — the paste target.
    private var previousApp: NSRunningApplication?

    /// Temporary footer message (e.g. vanished file) that self-clears on the
    /// next selection change or reload.
    private var footerNoticeUntil: Date?

    enum Tab: Equatable {
        case clipboard
        case tag(String)
    }

    enum ChipKind: Equatable {
        case clipboard
        case tag(String)
        case add
    }

    enum Row {
        case header(String)
        case clip(ClipboardItem)
        case note(ClipboardNote)
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

    private var selectedNote: ClipboardNote? {
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count, case .note(let note) = rows[row] else { return nil }
        return note
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
        // Non-key windows drop mouse-moved events by default — without this
        // the row hover tracking areas never fire.
        panel.acceptsMouseMovedEvents = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let (background, content, _) = makePanelBackground(
            frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 300),
            surface: .list
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
        // Row hover follows the cursor: a local monitor fires only while a
        // window of this app is key, which is exactly the panel-visible
        // case (tracking areas on table row views proved unreliable).
        NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard event.window === self?.panel else { return event }
            self?.updateHover(at: event.locationInWindow)
            return event
        }
    }

    private var hoveredRowView: LauncherRowView?

    private func updateHover(at windowPoint: NSPoint) {
        guard panel.isVisible else { return }
        let loc = tableView.convert(windowPoint, from: nil)
        let row = tableView.row(at: loc)
        let view = row >= 0
            ? tableView.rowView(atRow: row, makeIfNecessary: false) as? LauncherRowView
            : nil
        guard view !== hoveredRowView else { return }
        hoveredRowView?.hovering = false
        hoveredRowView?.needsDisplay = true
        hoveredRowView = view
        view?.hovering = true
        view?.needsDisplay = true
    }

    /// Wired once at helper launch (after the TCP server is up).
    func attach(store: ClipboardStore) {
        self.store = store
    }

    /// Notes snapshot from the /card-notes feed — same data the ActionPanel's
    /// notes list renders. Rebuilds the chip tab row and reloads.
    func updateNotes(notes: [ClipboardNote], categories: [String]) {
        self.notes = notes
        var categories = categories
        if !categories.contains(Self.defaultTag) {
            categories.append(Self.defaultTag) // uncategorized notes always have a home
        }
        allTags = categories
        rebuildChips()
        reload()
    }

    // MARK: show / hide

    func show() {
        // Toggle: a repeat press of the hotkey closes instead of re-flashing.
        if panel.isVisible {
            hide(notify: true)
            return
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        addChip.isHidden = false
        tagInputView.isHidden = true
        tagInputView.stringValue = ""
        tab = .clipboard
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
        for chip in chipViews { chip.view.applyTheme(cardTheme) }
        addChip.applyTheme(cardTheme) // outside chipViews — never themed otherwise
        tagInputView.applyTheme(cardTheme)
        tableView.reloadData()
    }

    // MARK: chrome

    private func buildChrome() {
        searchField.frame = NSRect(x: Self.side, y: 12, width: Self.panelWidth - Self.side * 2, height: PanelDesign.searchHeight)
        searchField.placeholderString = "输入关键词搜索"
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 16)
        searchField.drawsBackground = false
        searchField.backgroundColor = .clear
        (searchField.cell as? NSSearchFieldCell)?.sendsActionOnEndEditing = false
        searchField.wantsLayer = true
        searchField.delegate = self
        root.addSubview(searchField)

        // Chip row: horizontal scroller, one line, always the input at the end.
        chipsScrollView.frame = NSRect(x: Self.side, y: 58, width: Self.panelWidth - Self.side * 2, height: PanelDesign.pillHeight + 4)
        chipsScrollView.drawsBackground = false
        chipsScrollView.hasVerticalScroller = false
        chipsScrollView.hasHorizontalScroller = false // gestures still scroll; no bar
        chipsScrollView.translatesAutoresizingMaskIntoConstraints = true
        chipsContent = FlippedView(frame: NSRect(x: 0, y: 0, width: chipsScrollView.contentSize.width, height: PanelDesign.pillHeight + 4))
        chipsScrollView.documentView = chipsContent
        root.addSubview(chipsScrollView)

        addChip.configureAdd { [weak self] in
            self?.beginTagCreation()
        }
        chipsContent.addSubview(addChip)
        tagInputView.setup(theme: cardTheme, delegate: self)
        tagInputView.isHidden = true
        chipsContent.addSubview(tagInputView)

        rebuildChips()

        tableView.headerView = nil
        tableView.backgroundColor = .clear
        // The default .inset style pads rows ~17pt horizontally (macOS 26) —
        // it pushed every cell's content right of the capsule's left line.
        // .plain: we own the geometry (capsule insetDx, leading 14).
        tableView.style = .plain
        // Default intercellSpacing.height is 2pt — an invisible per-row tax
        // that breaks the exact-fit height math (few-row tabs scrolled by
        // 2×n points). Row gaps come from the capsule insets, not here.
        tableView.intercellSpacing = .zero
        tableView.usesAutomaticRowHeights = true
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ClipboardColumn"))
        column.width = Self.panelWidth
        tableView.addTableColumn(column)
        scrollView.documentView = tableView
        // Without these the table renders zero rows — the dataSource/delegate
        // methods on self are the entire list pipeline (launcher lesson).
        tableView.dataSource = self
        tableView.delegate = self
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        // Vertical breathing room comes from the FRAME inset in layoutChrome.
        root.addSubview(scrollView)
        // Double-click pastes, same as Enter.
        tableView.target = self
        tableView.action = #selector(rowDoubleClicked)
        // Right-click management menus (delete / move / rename).
        tableView.onMenu = { [weak self] row in
            self?.contextMenu(for: row)
        }

        footerLeft.font = .systemFont(ofSize: 12)
        footerRight.font = .systemFont(ofSize: 12)
        footerRight.alignment = .right
        root.addSubview(footerLeft)
        root.addSubview(footerRight)

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.alignment = .center
        emptyLabel.stringValue = "暂无粘贴板历史 — 复制任意内容开始"
        emptyLabel.isHidden = true
        root.addSubview(emptyLabel)
    }

    /// Chip tab row: [Clipboard] + one chip per tag — the ＋ button and the
    /// inline input live at the row's end (see layoutChipsRow). Rebuilt
    /// whenever the notes snapshot arrives (tags may have changed).
    private func rebuildChips() {
        chipViews.forEach { $0.view.removeFromSuperview() }
        chipViews.removeAll()

        for tag in allTags {
            let view = ChipPillView(frame: NSRect(x: 0, y: 4, width: 64, height: PanelDesign.pillHeight))
            let color = tagColor(for: tag, dark: cardTheme.isDark)
            view.configure(title: tag, color: color) { [weak self] in
                self?.selectTab(.tag(tag))
            }
            // applyTheme AFTER configure: configure re-applies the stored
            // (stale) theme — the /card-notes push rebuilds chips while the
            // panel is light, and the stale dark theme painted unreadable
            // white labels.
            view.applyTheme(cardTheme)
            view.isDraggable = true
            view.onDragBegin = { [weak self] chip, _ in self?.beginChipDrag(chip) }
            view.onDragMove = { [weak self] chip, _ in self?.updateChipDrag(chip) }
            view.onDragEnd = { [weak self] _ in self?.endChipDrag() }
            chipViews.append((.tag(tag), view))
            chipsContent.addSubview(view)
        }

        let clipboard = ChipPillView(frame: NSRect(x: 0, y: 4, width: 64, height: PanelDesign.pillHeight))
        clipboard.configure(title: "剪贴板", color: .systemGray) { [weak self] in
            self?.selectTab(.clipboard)
        }
        clipboard.applyTheme(cardTheme)
        chipViews.insert((.clipboard, clipboard), at: 0)
        chipsContent.addSubview(clipboard)

        layoutChipsRow()
        syncChips()
    }

    private func selectTab(_ tab: Tab) {
        guard self.tab != tab else { return }
        self.tab = tab
        searchField.stringValue = ""
        syncChips()
        reload()
        // A new tab starts reading from its first row — reload() only clamps
        // the offset (to preserve position on same-tab refreshes).
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: chip drag reorder

    private var dragChip: (kind: ChipKind, view: ChipPillView)?
    private var dragGrabOffset: CGFloat = 0

    /// The dragged chip follows the cursor; neighbours flow around its
    /// live slot. The Clipboard tab stays pinned first — dragged chips can
    /// never cross index 0.
    private func beginChipDrag(_ chip: ChipPillView) {
        guard let entry = chipViews.first(where: { $0.view === chip }),
              entry.kind != .clipboard
        else { return }
        dragChip = entry
        dragGrabOffset = chip.convert(NSEvent.mouseLocation, from: nil).x
        // Raise above siblings for the whole drag.
        chipsContent.addSubview(chip, positioned: .above, relativeTo: nil)
    }

    private func updateChipDrag(_ chip: ChipPillView) {
        guard let dragged = dragChip, dragged.view === chip else { return }
        let xInContent = chip.superview.map { $0.convert(NSEvent.mouseLocation, from: nil).x }
            ?? chip.frame.origin.x
        let contentWidth = chipsContent.frame.width
        let rawX = xInContent - dragGrabOffset
        // Clamp within the row: never before the Clipboard chip (index 0).
        let minX = chipViews.first?.view.frame.maxX ?? 0
        chip.frame.origin.x = min(max(rawX, minX), contentWidth - chip.frame.width)

        // Live insertion slot by center; re-flow everyone else around it.
        let center = chip.frame.midX
        var others = chipViews.filter { $0.view !== chip }
        var slot = others.count
        for (index, entry) in others.enumerated() where entry.view.frame.midX > center {
            slot = index
            break
        }
        others.insert(dragged, at: slot)
        // Keep Clipboard first no matter where the cursor sits.
        if let clipboardIndex = others.firstIndex(where: {
            if case .clipboard = $0.kind { return true }
            return false
        }), clipboardIndex != 0 {
            let clipboardEntry = others.remove(at: clipboardIndex)
            others.insert(clipboardEntry, at: 0)
        }
        chipViews = others
        var x: CGFloat = 0
        for entry in chipViews where entry.view !== chip {
            entry.view.frame.origin.x = x
            x = entry.view.frame.maxX + 6
        }
    }

    private func endChipDrag() {
        guard dragChip != nil else { return }
        dragChip = nil
        layoutChipsRow()
        // Persist the new tag order (Clipboard excluded from the payload).
        let names = chipViews.compactMap { kind, _ -> String? in
            if case .tag(let name) = kind { return name }
            return nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: names),
              let json = String(data: data, encoding: .utf8)
        else { return }
        onAction?("note-tag-reorder", json)
    }

    private func syncChips() {
        for (kind, view) in chipViews {
            view.setSelected(kind == activeChipKind)
        }
    }

    private var activeChipKind: ChipKind {
        switch tab {
        case .clipboard: return .clipboard
        case .tag(let name): return .tag(name)
        }
    }

    private func styleChrome() {
        // Contrast scrim: raw NSGlassEffectView washes out on dark
        // wallpapers (same veil the launcher and card use).
        glassContent.layer?.backgroundColor = PanelStyle.scrim(dark: cardTheme.isDark).cgColor
        emptyLabel.textColor = cardTheme.tertiaryText
        footerLeft.textColor = cardTheme.secondaryText
        footerRight.textColor = cardTheme.tertiaryText
    }

    /// One-line chip row inside a horizontal scroller: [tab chips…] [＋] and
    /// — once the ＋ is clicked — the inline input, always at the end.
    private func layoutChipsRow() {
        var x: CGFloat = 0
        for (_, chip) in chipViews {
            chip.frame = NSRect(x: x, y: 4, width: max(chip.fittingSize.width, 40), height: PanelDesign.pillHeight)
            x = chip.frame.maxX + 6
        }
        if tagInputVisible {
            // The input takes the ＋'s slot IN PLACE — one normal chip-width
            // step, same 6pt gap as every other chip.
            tagInputView.frame = NSRect(x: x, y: 4, width: tagInputView.fittingSize.width, height: PanelDesign.pillHeight)
            addChip.frame = tagInputView.frame
            x = tagInputView.frame.maxX + 6
        } else {
            addChip.frame = NSRect(x: x, y: 4, width: 26, height: PanelDesign.pillHeight)
            tagInputView.frame = addChip.frame
            x = addChip.frame.maxX + 6
        }
        chipsContent.frame = NSRect(
            x: 0, y: 0,
            width: max(x, chipsScrollView.contentSize.width),
            height: PanelDesign.pillHeight + 4 // == viewport: no vertical scroll
        )
    }

    /// Scrolls ONLY when the target is outside the visible rect — a normal
    /// scroller never moves for things you can already see. The target is
    /// scene-driven: tab switch → the active chip; ＋ click → the input;
    /// fold-back → nothing (keep the user's position).
    private func scrollChipVisible(_ view: NSView) {
        let frame = view.frame
        let visible = chipsScrollView.contentView.documentVisibleRect
        guard frame.minX < visible.minX || frame.maxX > visible.maxX else { return }
        let target = frame.minX < visible.minX
            ? max(0, frame.minX - 12)
            : max(0, min(frame.maxX - visible.width + 12,
                         chipsContent.frame.width - visible.width))
        chipsScrollView.contentView.scroll(to: NSPoint(x: target, y: 0))
        chipsScrollView.reflectScrolledClipView(chipsScrollView.contentView)
    }

    private func scrollActiveChipVisible() {
        guard let index = chipViews.firstIndex(where: { $0.kind == activeChipKind }) else { return }
        scrollChipVisible(chipViews[index].view)
    }

    private func layoutChrome(height: CGFloat) {
        layoutChipsRow()
        scrollActiveChipVisible()
        // Symmetric breathing room: 6pt from the chips pill's bottom edge to
        // the first row, and 6pt from the last row to the footer label
        // (footerY + 5). The viewport therefore equals the row total exactly
        // — no phantom slack, no clipping at the last capsule.
        let listY = 58 + PanelDesign.pillHeight + 4 + 6
        scrollView.frame = NSRect(x: 0, y: listY, width: Self.panelWidth, height: height - listY - 28)
        let listHeight = height - listY - 28
        // Empty state floats in the MIDDLE of the content area, not pinned
        // under the chips.
        emptyLabel.frame = NSRect(
            x: Self.side,
            y: listY + max(0, (listHeight - 40) / 2),
            width: Self.panelWidth - Self.side * 2,
            height: 40
        )
        let footerY = height - 28
        footerLeft.frame = NSRect(x: 16, y: footerY + 6, width: 240, height: 15)
        footerRight.frame = NSRect(x: Self.panelWidth - 266, y: footerY + 6, width: 250, height: 15)
    }

    func placePanel() {
        let size = NSSize(width: Self.panelWidth, height: Self.panelHeight)
        root.frame = NSRect(origin: .zero, size: size)
        layoutChrome(height: size.height)
        // Hapigo-style placement: the panel's TOP-LEFT corner matches the
        // mouse; only an on-screen overflow nudges it horizontally or
        // vertically back into the visible frame.
        let point = NSEvent.mouseLocation
        var origin = NSPoint(x: point.x, y: point.y - size.height)
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    // MARK: data

    func reload() {
        switch tab {
        case .clipboard:
            reloadClipboard()
        case .tag(let tag):
            reloadNotes(tag: tag)
        }
        tableView.reloadData()
        updateFooter()
        updateEmptyState()
        scrollActiveChipVisible()
        if let firstSelectable = rows.indices.first(where: {
            if case .header = rows[$0] { return false }
            return true
        }) {
            tableView.selectRowIndexes(IndexSet(integer: firstSelectable), byExtendingSelection: false)
        }
        // Fixed window: never re-place on reload — tab switches must not
        // move the panel off its pinned top-left corner.
        // reloadData tiles the table against the PREVIOUS clip bounds;
        // refit the documentView to the final viewport.
        updateHover(at: panel.convertFromScreen(
            NSRect(origin: NSEvent.mouseLocation, size: .zero)).origin)
        let viewport = scrollView.contentSize
        let contentHeight = tableView.numberOfRows > 0
            ? tableView.rect(ofRow: tableView.numberOfRows - 1).maxY
            : 0
        tableView.frame = NSRect(x: 0, y: 0, width: viewport.width, height: max(contentHeight, viewport.height))
        let clip = scrollView.contentView
        let maxOffset = max(0, tableView.frame.height - viewport.height)
        if clip.bounds.origin.y > maxOffset {
            clip.scroll(to: NSPoint(x: 0, y: maxOffset))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    private func reloadClipboard() {
        guard let store else {
            rows = []
            visibleItems = []
            return
        }
        let found = store.search(searchField.stringValue, filter: .all)
        // Pinned items pin to the top as a section: pinned rows live in
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
    }

    private func reloadNotes(tag: String) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = notes.filter { note in
            let inTag = note.category == tag
                || (note.category == nil && tag == Self.defaultTag)
            guard inTag else { return false }
            guard !query.isEmpty else { return true }
            let haystack = "\(note.name)\n\(note.content)".lowercased()
            return haystack.contains(query)
        }
        visibleItems = []
        rows = matching.map { Row.note($0) }
    }

    private func updateEmptyState() {
        emptyLabel.isHidden = !rows.isEmpty
        switch tab {
        case .clipboard:
            emptyLabel.stringValue = searchField.stringValue.isEmpty
                ? "暂无粘贴板历史 — 复制任意内容开始"
                : "没有匹配的粘贴板内容"
        case .tag:
            emptyLabel.stringValue = searchField.stringValue.isEmpty
                ? "该分类暂无笔记"
                : "没有匹配的笔记"
        }
    }

    private func updateFooter() {
        if let until = footerNoticeUntil, Date() < until {
            return // a notice is showing; it clears on the next interaction
        }
        footerNoticeUntil = nil
        let selectable = rows.filter { row in
            if case .header = row { return false }
            return true
        }
        let row = tableView.selectedRow
        let ordinal = row >= 0 ? row : 0
        footerLeft.stringValue = "已选 \(ordinal) 项，总共 \(selectable.count) 项"
        footerRight.stringValue = tab == .clipboard
            ? "⌘P 置顶 · ⌫ 删除 · ↩ 粘贴"
            : "↩ 粘贴"
    }

    private func showFooterNotice(_ text: String) {
        footerNoticeUntil = Date().addingTimeInterval(2)
        footerLeft.stringValue = text
    }

    // MARK: actions

    /// ⌘P lands here via KeyablePanel.keyEquivalentHandler (clipboard tab
    /// only — notes are managed in the ActionPanel / main window).
    func togglePinSelected() {
        guard tab == .clipboard, let store, let item = selectedItem else { return }
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
        guard tab == .clipboard, let store, let item = selectedItem else { return }
        store.delete(item)
        reload()
    }

    private var tagInputVisible = false

    private var tagInputField: NSTextField { tagInputView.field }

    /// ＋ click: reveal the inline input and focus it.
    private func beginTagCreation() {
        tagInputVisible = true
        addChip.isHidden = true
        tagInputView.isHidden = false
        layoutChipsRow()
        scrollChipVisible(tagInputView)
        panel.makeFirstResponder(tagInputField)
    }

    /// Esc in the input: fold it back into the ＋ button.
    private func endTagInput() {
        tagInputVisible = false
        tagInputView.stringValue = ""
        tagInputView.isHidden = true
        addChip.isHidden = false
        layoutChipsRow()
    }

    /// Enter in the inline input: create the category and switch to it.
    private func commitTagInput() {
        let name = tagInputView.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            endTagInput()
            return
        }
        guard name.count <= 24 else {
            showFooterNotice("分类名过长（最多 24 个字符）")
            return // keep the input open for a shorter name
        }
        endTagInput()
        // Rust inserts into tags (INSERT OR IGNORE) and re-pushes the notes
        // snapshot; the new chip appears with that feed. Switch optimistically
        // so the panel is already on the fresh, empty category.
        tab = .tag(name)
        syncChips()
        onAction?("note-tag-create", name)
        reload()
    }

    /// Each panel is independent: paste-through closes THIS panel only.
    /// The card/toolbar/launcher manage their own visibility. macOS's
    /// NSPanel focus handling (nonactivatingPanel + windowDidResignKey)
    /// handles cross-panel dismissal naturally.

    private func pasteSelected() {
        FileLog.write("PASTE enter tab=\(tab)")
        switch tab {
        case .clipboard:
            pasteClipboardSelection()
        case .tag:
            pasteNoteSelection()
        }
    }

    /// Headless repro for the paste-through investigation: same path as
    /// the panel's Enter, minus real key events.
    func debugPasteSelected() {
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        pasteSelected()
    }

    private func pasteClipboardSelection() {
        guard let store, let item = selectedItem else { return }
        // Close this panel; the target app activation + ⌘V handle the rest.
        hide(notify: true)
        if !ClipboardPaster.paste(item, store: store, previousApp: previousApp),
           item.kind == .file {
            // A vanished file is reported, never silently swallowed and never
            // auto-deleted — history is a record of what happened.
            showFooterNotice("文件已不存在 — \(item.text ?? "")")
        }
    }

    private func pasteNoteSelection() {
        guard let note = selectedNote else { return }
        hide(notify: true)
        ClipboardPaster.pasteString(note.content, previousApp: previousApp)
    }

    @objc private func rowDoubleClicked() {
        pasteSelected()
    }

    // MARK: management (right-click)

    /// Right-click menus. Clips: delete / move-to-category (saves the clip
    /// as a note under the chosen tag, then removes the clip). Notes: delete
    /// / rename / move-to-category (re-tag via the existing note-tag action).
    func contextMenu(for row: Int) -> NSMenu? {
        guard row >= 0, row < rows.count else { return nil }
        switch rows[row] {
        case .header:
            return nil
        case .clip(let item):
            let menu = NSMenu()
            let delete = NSMenuItem(title: "删除", action: #selector(deleteClipFromMenu(_:)), keyEquivalent: "")
            delete.target = self
            delete.representedObject = item.id.uuidString
            menu.addItem(delete)
            menu.addItem(withTitle: "移动到分类…", action: nil, keyEquivalent: "").submenu = tagSubmenu(
                selector: #selector(moveClipToTagFromMenu(_:)),
                payloadPrefix: item.id.uuidString + "|"
            )
            return menu
        case .note(let note):
            guard let noteId = note.id as Int64?, noteId != 0 else { return nil }
            let menu = NSMenu()
            let delete = NSMenuItem(title: "删除", action: #selector(deleteNoteFromMenu(_:)), keyEquivalent: "")
            delete.target = self
            delete.representedObject = String(noteId)
            menu.addItem(delete)
            let rename = NSMenuItem(title: "重命名…", action: #selector(renameNoteFromMenu(_:)), keyEquivalent: "")
            rename.target = self
            rename.representedObject = "\(noteId)|\(note.name)"
            menu.addItem(rename)
            let move = NSMenuItem(title: "移动到分类…", action: nil, keyEquivalent: "")
            move.submenu = tagSubmenu(
                selector: #selector(moveNoteToTagFromMenu(_:)),
                payloadPrefix: "\(noteId)|",
                excluding: note.category
            )
            menu.addItem(move)
            return menu
        }
    }

    private func tagSubmenu(
        selector: Selector, payloadPrefix: String, excluding current: String? = nil
    ) -> NSMenu {
        let submenu = NSMenu()
        for tag in allTags where tag != current {
            let item = NSMenuItem(title: tag, action: selector, keyEquivalent: "")
            item.target = self
            item.representedObject = payloadPrefix + tag
            submenu.addItem(item)
        }
        if submenu.items.isEmpty {
            submenu.addItem(withTitle: "暂无其他分类", action: nil, keyEquivalent: "").isEnabled = false
        }
        return submenu
    }

    @objc private func deleteClipFromMenu(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let id = UUID(uuidString: idString),
              let store,
              let item = store.items.first(where: { $0.id == id })
        else { return }
        store.delete(item)
        reload()
    }

    /// Move a clip into a note category: create the note server-side, then
    /// remove the clip row. Image/file clips move their text form only.
    @objc private func moveClipToTagFromMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? String,
              let separator = payload.firstIndex(of: "|"),
              let id = UUID(uuidString: String(payload[..<separator])),
              let tag = payload[payload.index(after: separator)...].isEmpty
                ? nil : String(payload[payload.index(after: separator)...]),
              let store,
              let item = store.items.first(where: { $0.id == id }),
              let content = item.previewText
        else { return }
        let body: [String: String] = ["name": "", "content": content, "tag": tag]
        if let data = try? JSONSerialization.data(withJSONObject: body),
           let json = String(data: data, encoding: .utf8) {
            onAction?("note-create", json)
        }
        store.delete(item)
        reload()
    }

    @objc private func deleteNoteFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onAction?("note-delete", id)
    }

    @objc private func renameNoteFromMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? String,
              let separator = payload.firstIndex(of: "|") else { return }
        let noteId = Int64(String(payload[..<separator])) ?? 0
        let current = String(payload[payload.index(after: separator)...])
        guard noteId != 0,
              let row = rows.indices.first(where: {
                  if case .note(let note) = rows[$0] { return note.id == noteId }
                  return false
              }),
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? ClipCell
        else { return }
        cell.beginRenaming(current: current) { [weak self] newName in
            guard let self else { return }
            let body: [String: Any] = ["id": noteId, "name": newName]
            if let data = try? JSONSerialization.data(withJSONObject: body),
               let json = String(data: data, encoding: .utf8) {
                self.onAction?("note-rename", json)
            }
        }
    }

    @objc private func moveNoteToTagFromMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? String,
              let separator = payload.firstIndex(of: "|") else { return }
        let id = String(payload[..<separator])
        let tag = String(payload[payload.index(after: separator)...])
        onAction?("note-tag", "\(id)|\(tag)")
    }


    // MARK: keyboard

    private func moveVertical(_ delta: Int) {
        let selectable = rows.indices.filter {
            if case .header = rows[$0] { return false }
            return true
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

    /// Tab cycles the chip tabs (skipping the ⊕ chip, which is not a tab).
    private func cycleTabs(_ delta: Int) {
        let kinds = chipViews.map(\.kind).filter { $0 != .add }
        guard let index = kinds.firstIndex(of: activeChipKind) else { return }
        let next = kinds[(index + delta + kinds.count) % kinds.count]
        switch next {
        case .clipboard:
            selectTab(.clipboard)
        case .tag(let name):
            selectTab(.tag(name))
        case .add:
            break
        }
    }

    // NSTextFieldDelegate — the search field and the inline tag input share
    // this delegate; route by sender.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let isTagInput = control === tagInputField
        switch commandSelector {
        case NSSelectorFromString("moveUp:"):
            if !isTagInput {
                moveVertical(-1)
                return true
            }
            return false
        case NSSelectorFromString("moveDown:"):
            if !isTagInput {
                moveVertical(1)
                return true
            }
            return false
        case NSSelectorFromString("insertNewline:"):
            if isTagInput {
                commitTagInput()
                return true
            }
            pasteSelected()
            return true
        case NSSelectorFromString("cancelOperation:"):
            if isTagInput {
                endTagInput() // cancel: fold back to the ＋ chip
                return true
            }
            if !searchField.stringValue.isEmpty {
                searchField.stringValue = ""
                reload()
            } else {
                hide(notify: true)
            }
            return true
        case NSSelectorFromString("deleteBackward:"):
            if !isTagInput, tab == .clipboard, searchField.stringValue.isEmpty {
                deleteSelected()
                return true
            }
            return false
        case NSSelectorFromString("insertTab:"):
            // Tab cycles the chip tabs from EITHER field.
            cycleTabs(1)
            return true
        default:
            // Arrows inside the tag input move the caret; arrows in the
            // search field are handled above.
            return false
        }
    }

    // NSTextFieldDelegate — search drives the list; the tag input is inert
    // until Enter (commitTagInput).
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) !== tagInputField else { return }
        reload()
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

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
                item: item, theme: cardTheme,
                thumbnail: thumbnail(for: item),
                sourceIcon: ClipboardMonitor.shared.cachedIcon(forBundleID: item.sourceBundleID))
            return cell
        case .note(let note):
            let cell = reuse(ClipCell.self, row: row)
            cell.configureNote(
                note: note, theme: cardTheme,
                sourceIcon: tagColoredNoteGlyph())
            return cell
        }
    }

    /// Fallback note glyph (lucide notebook-pen, neutral grey).
    static let noteGlyph: NSImage? = lucideImage(
        for: "notebook-pen", title: "note", color: .systemGray)

    private var noteIconCache: [String: NSImage] = [:]

    /// Note rows wear their category's dot color — the glyph matches the
    /// active tab chip. Cached per (tag, theme); clipboard tab rows never
    /// use this path.
    private func tagColoredNoteGlyph() -> NSImage? {
        guard case .tag(let name) = tab else { return Self.noteGlyph }
        let key = "\(name)-\(cardTheme.isDark)"
        if let cached = noteIconCache[key] { return cached }
        guard let image = lucideImage(
            for: "notebook-pen", title: name,
            color: tagColor(for: name, dark: cardTheme.isDark)
        ) else { return Self.noteGlyph }
        noteIconCache[key] = image
        return image
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(
            withIdentifier: NSUserInterfaceItemIdentifier("LauncherRowView"),
            owner: self
        ) as? LauncherRowView ?? LauncherRowView()
        view.identifier = NSUserInterfaceItemIdentifier("LauncherRowView")
        view.fillColor = cardTheme.selectedFill
        view.hoverFillColor = cardTheme.hoverFill
        view.insetDx = PanelDesign.rowCapsuleInsetX
        view.insetDy = PanelDesign.rowCapsuleInsetY
        return view
    }

    private func thumbnail(for item: ClipboardItem) -> NSImage? {
        guard item.kind == .image else { return nil }
        if let cached = thumbnailCache[item.id] { return cached }
        guard let store, let url = store.imageURL(for: item) else {
            return nil
        }
        let image = NSImage(contentsOf: url)
        image?.size = NSSize(width: 44, height: 44)
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
        let view = T(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 44))
        view.identifier = identifier
        return view
    }
}

/// A note as seen by the clipboard panel: the ActionPanel owns editing; this
/// surface reads name/content/category and pastes content.
struct ClipboardNote {
    let id: Int64
    let name: String
    let content: String
    let category: String?
}

enum ClipboardNotePreview {
    /// Whitespace-collapsed preview for rows and matching; empty when there
    /// is nothing readable.
    static func text(_ note: ClipboardNote) -> String? {
        guard !note.content.isEmpty else { return nil }
        let collapsed = note.content.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.isEmpty ? nil : collapsed
    }
}


/// Filter chip: colored dot + label in a capsule. Rest state carries a
/// hairline border (chips read as pills on the glass, launcher folder-chip
/// grammar); active = selectedFill, hover = hoverFill. Width is measured
/// from the label — `fittingSize` drives the chip-row flow layout.
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

    /// Dot(7) + gap + label + generous slack — an exact-fit width loses the
    /// last character to sub-pixel rounding (the "Clipboar" bug).
    override var fittingSize: NSSize {
        NSSize(width: min(label.intrinsicContentSize.width + 40, 140),
               height: PanelDesign.pillHeight)
    }

    func configure(title: String, color: NSColor, onActivate: @escaping () -> Void) {
        self.onActivate = onActivate
        chipColor = color
        if !didLayout {
            didLayout = true
            wantsLayer = true
            layer?.cornerRadius = PanelDesign.pillCornerRadius

            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.5
            dot.frame = NSRect(x: 11, y: 8, width: 7, height: 7)
            addSubview(dot)

            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.lineBreakMode = .byTruncatingTail
            label.cell?.usesSingleLineMode = true
            addSubview(label)
        }
        dot.isHidden = false
        label.stringValue = title
        applyTheme(theme)
    }

    private var isAddStyle = false

    /// The ＋ button chip: centered plus glyph, no dot.
    func configureAdd(onActivate: @escaping () -> Void) {
        isAddStyle = true
        self.onActivate = onActivate
        chipColor = .clear
        if !didLayout {
            didLayout = true
            wantsLayer = true
            layer?.cornerRadius = PanelDesign.pillCornerRadius

            label.font = .systemFont(ofSize: 15, weight: .medium)
            label.alignment = .center
            label.lineBreakMode = .byClipping
            addSubview(label)
        }
        dot.isHidden = true
        label.stringValue = "+"
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

    override func layout() {
        super.layout()
        // Everything centers within the pill's real height — fixed offsets
        // went stale when the pill height token changed (28pt).
        if isAddStyle {
            // Centered plus across the full chip — the dot-side formula
            // computes a ZERO width at the 32pt add chip (invisible ＋).
            label.frame = NSRect(x: 0, y: (bounds.height - 16) / 2, width: bounds.width, height: 16)
        } else {
            // Label fills everything right of the dot; the chip-row flow
            // sizes the chip with slack (fittingSize +40) so text never clips.
            label.frame = NSRect(x: 24, y: (bounds.height - 16) / 2, width: bounds.width - 32, height: 16)
            dot.frame = NSRect(x: 11, y: (bounds.height - 7) / 2, width: 7, height: 7)
        }
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

    // Drag-to-reorder (tag chips only): a >4pt move after mouse-down turns
    // into a drag handled by the controller; otherwise mouse-UP activates
    // the tab (click semantics preserved).
    var isDraggable = false
    var onDragBegin: ((ChipPillView, NSEvent) -> Void)?
    var onDragMove: ((ChipPillView, NSEvent) -> Void)?
    var onDragEnd: ((ChipPillView) -> Void)?
    private var pressLocation: NSPoint?
    private var isDragging = false

    override func mouseDown(with event: NSEvent) {
        pressLocation = NSEvent.mouseLocation
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggable, let start = pressLocation else { return }
        let moved = hypot(
            NSEvent.mouseLocation.x - start.x,
            NSEvent.mouseLocation.y - start.y
        )
        if !isDragging, moved > 4 {
            isDragging = true
            onDragBegin?(self, event)
        }
        if isDragging {
            onDragMove?(self, event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressLocation = nil
            isDragging = false
        }
        if isDragging {
            onDragEnd?(self)
        } else {
            onActivate?()
        }
    }

    private func applyBackground() {
        wantsLayer = true
        layer?.cornerRadius = PanelDesign.pillCornerRadius
        layer?.backgroundColor = selected
            ? theme.selectedFill.cgColor
            : (hovering ? theme.hoverFill.cgColor : NSColor.clear.cgColor)
        layer?.borderWidth = 0.5
        layer?.borderColor = theme.isDark
            ? NSColor.white.withAlphaComponent(0.14).cgColor
            : NSColor.black.withAlphaComponent(0.10).cgColor
        dot.layer?.backgroundColor = chipColor.cgColor
    }
}

/// The always-visible inline input at the end of the chip row: type a new
/// category name, Enter creates it (controller owns the delegate). Styled as
/// a pill so it reads as the last tab.
final class ChipInputView: NSView {
    let field = NSTextField()
    private let plus = NSTextField(labelWithString: "+")
    private var theme: CardTheme = .dark
    private var didLayout = false

    override var isFlipped: Bool { true }

    override var fittingSize: NSSize {
        NSSize(width: 104, height: PanelDesign.pillHeight)
    }

    var stringValue: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    func setup(theme: CardTheme, delegate: NSTextFieldDelegate) {
        self.theme = theme
        if !didLayout {
            didLayout = true
            wantsLayer = true
            layer?.cornerRadius = PanelDesign.pillCornerRadius

            plus.font = .systemFont(ofSize: 14, weight: .medium)
            plus.frame = NSRect(x: 8, y: 6, width: 10, height: 16)
            addSubview(plus)

            field.font = .systemFont(ofSize: 13)
            field.isBordered = false
            field.isEditable = true
            field.isSelectable = true
            field.drawsBackground = false
            field.focusRingType = .none
            field.placeholderString = "新分类"
            field.delegate = delegate
            field.frame = NSRect(x: 22, y: 6, width: 76, height: 16)
            addSubview(field)
        }
        applyTheme(theme)
    }

    func applyTheme(_ theme: CardTheme) {
        self.theme = theme
        plus.textColor = theme.tertiaryText
        field.textColor = theme.foreground
        applyBackground()
    }

    private func applyBackground() {
        wantsLayer = true
        layer?.cornerRadius = PanelDesign.pillCornerRadius
        layer?.backgroundColor = theme.isDark
            ? NSColor.white.withAlphaComponent(0.06).cgColor
            : NSColor.white.withAlphaComponent(0.30).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = PanelStyle.controlBorder(dark: theme.isDark).cgColor
    }
}


/// Section header row (「置顶」).
final class ClipboardHeaderCell: NSView {
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

/// Clipboard row, laid out with Auto Layout constraints (declared once, the
/// system solves positions — no hand-computed frames to drift). Geometry:
///
///   icon: leading 16, 24×24, vertically centered
///   text: leading icon+10, trailing ≤ superview-16
///   selection capsule (insetDx 6 → 6..514): pads the content 10pt per side
/// Rows show exactly one of: single-line text (name label, centered),
/// wrapping text (up to 2 lines, fills the row), file (name over dim path),
/// image (40pt thumbnail; quiet placeholder while it decodes), note (same
/// two-deck as file rows; unnamed notes collapse to a text row).
final class ClipCell: NSView {
    private let iconView = NSImageView()
    private let thumbnailView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")  // single-line text / file or note name
    private let pathLabel = NSTextField(labelWithString: "")  // file path / note content (dim)
    private let previewLabel = NSTextField(wrappingLabelWithString: "")
    /// Inline rename editor (ActionPanel NoteRowCell pattern): overlays the
    /// name label; Enter commits via closure, Esc/focus-loss cancels.
    private let nameEditor = RenameField()
    private var renameCommit: ((String) -> Void)?
    private var isRenaming = false
    private var installed = false
    /// Rendered text height (cellSize), capped at two lines — the one true
    /// input for the row's self-sized height. Auto Layout's intrinsic size
    /// under-reports multi-line CJK/emoji text (fallback-font line height)
    /// and the second line silently clips.
    private var textHeight: NSLayoutConstraint!
    private var thumbSide: NSLayoutConstraint!

    func beginRenaming(current: String, onCommit: @escaping (String) -> Void) {
        renameCommit = onCommit
        isRenaming = true
        nameEditor.stringValue = current
        nameLabel.isHidden = true
        nameEditor.isHidden = false
        window?.makeFirstResponder(nameEditor)
        nameEditor.currentEditor()?.selectAll(nil)
    }

    private func endRenaming(commit: Bool) {
        guard isRenaming else { return }
        isRenaming = false
        let value = nameEditor.stringValue.trimmingCharacters(in: .whitespaces)
        nameEditor.isHidden = true
        nameLabel.isHidden = false
        window?.makeFirstResponder(nil)
        if commit, !value.isEmpty {
            renameCommit?(value)
        }
        renameCommit = nil
    }

    func configure(
        item: ClipboardItem, theme: CardTheme,
        thumbnail: NSImage?, sourceIcon: NSImage?
    ) {
        installConstraints()

        nameLabel.isHidden = true
        pathLabel.isHidden = true
        previewLabel.isHidden = false
        previewLabel.alignment = .natural
        thumbnailView.isHidden = true

        switch item.kind {
        case .text:
            // One label does it all: wraps to two lines, trailing … after
            // that. Row height follows from the label's intrinsic size.
            previewLabel.font = .systemFont(ofSize: 15)
            previewLabel.textColor = theme.foreground
            previewLabel.stringValue = item.previewText ?? ""
            previewLabel.cell?.wraps = true
            textHeight.constant = measuredTextHeight(item.previewText ?? "", wraps: true)
        case .file:
            let url = URL(fileURLWithPath: item.text ?? "")
            showTwoDeck(
                name: url.lastPathComponent, nameColor: theme.foreground,
                detail: url.deletingLastPathComponent().path,
                detailColor: theme.tertiaryText, truncatesPath: true)
        case .image:
            // Image rows occupy a three-line text box, the same metric the
            // text rows cap at.
            thumbSide.constant = PanelDesign.textLineBoxHeight(lines: 3)
            textHeight.constant = thumbSide.constant
            if let thumbnail {
                thumbnailView.image = thumbnail
                thumbnailView.isHidden = false
                previewLabel.isHidden = true
            } else {
                // Without a decoded thumbnail yet, a quiet placeholder keeps
                // the row from looking broken.
                previewLabel.font = .systemFont(ofSize: 13)
                previewLabel.textColor = theme.tertiaryText
                previewLabel.stringValue = "图片"
                previewLabel.alignment = .center
            }
        }
        iconView.image = sourceIcon
    }

    /// Rendered height of `text`, capped at two lines. cellSize runs the
    /// same layout engine that draws the text, so the number matches what
    /// renders (unlike intrinsicContentSize, which under-reports CJK/emoji
    /// fallback line heights and silently clips the second line).
    private func measuredTextHeight(_ text: String, wraps: Bool) -> CGFloat {
        let textWidth = ClipboardPanelController.panelWidth
            - PanelDesign.rowContentLeading - PanelDesign.rowIconSize
            - PanelDesign.rowIconToText - PanelDesign.rowContentTrailing
        let oldWraps = previewLabel.cell?.wraps ?? false
        previewLabel.cell?.wraps = wraps
        let size = previewLabel.cell!.cellSize(forBounds: NSRect(
            x: 0, y: 0, width: textWidth, height: 10_000))
        previewLabel.cell?.wraps = oldWraps
        // Single-line height from the same engine — real fallback-font metrics.
        let single = previewLabel.cell!.cellSize(forBounds: NSRect(
            x: 0, y: 0, width: 10_000, height: 10_000)).height
        return min(size.height, single * 2 + 2)
    }

    private func showTwoDeck(name: String, nameColor: NSColor,
                             detail: String, detailColor: NSColor,
                             truncatesPath: Bool) {
        previewLabel.isHidden = true
        nameLabel.font = .systemFont(ofSize: 15, weight: .medium)
        nameLabel.textColor = nameColor
        nameLabel.stringValue = name
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.cell?.usesSingleLineMode = true
        nameLabel.isHidden = false
        pathLabel.font = .systemFont(ofSize: 13)
        pathLabel.textColor = detailColor
        pathLabel.stringValue = detail
        pathLabel.isHidden = false
        if truncatesPath {
            // File row: one line, middle-… keeps the extension visible.
            pathLabel.lineBreakMode = .byTruncatingMiddle
            pathLabel.cell?.usesSingleLineMode = true
        } else {
            // Note content: same two-line rule as clipboard text rows.
            pathLabel.lineBreakMode = .byWordWrapping
            pathLabel.cell?.wraps = true
            pathLabel.maximumNumberOfLines = 2
            pathLabel.preferredMaxLayoutWidth = ClipboardPanelController.panelWidth
                - PanelDesign.rowContentLeading - PanelDesign.rowIconSize
                - PanelDesign.rowIconToText - PanelDesign.rowContentTrailing
        }
    }

    /// Note rows reuse the same skeleton: named notes render name over dim
    /// content (file-row shape); unnamed notes collapse to a text row.
    func configureNote(
        note: ClipboardNote, theme: CardTheme, sourceIcon: NSImage?
    ) {
        installConstraints()

        nameLabel.isHidden = true
        pathLabel.isHidden = true
        previewLabel.isHidden = false
        previewLabel.alignment = .natural
        thumbnailView.isHidden = true

        let text = ClipboardNotePreview.text(note)
        if note.name.isEmpty {
            // Unnamed note: the content IS the row.
            previewLabel.font = .systemFont(ofSize: 15)
            previewLabel.textColor = theme.foreground
            previewLabel.stringValue = text ?? ""
            previewLabel.cell?.wraps = true
            textHeight.constant = measuredTextHeight(text ?? "", wraps: true)
        } else {
            showTwoDeck(
                name: note.name, nameColor: theme.foreground,
                detail: text ?? "", detailColor: theme.tertiaryText,
                truncatesPath: false)
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
        nameEditor.delegate = self
        nameEditor.translatesAutoresizingMaskIntoConstraints = false
        nameEditor.isHidden = true
        addSubview(nameEditor)
        // The editor rides exactly on the name label's slot, whichever
        // vertical anchor (top for two-deck rows, centerY for single-line)
        // is active.
        nameEditor.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor).isActive = true
        nameEditor.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor).isActive = true
        nameEditor.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor).isActive = true
        nameEditor.heightAnchor.constraint(equalToConstant: 19).isActive = true
        // Two-deck rows (named notes, file clips): name over dim detail.
        // Text-only rows show previewLabel alone, centered; the row height
        // is the label's intrinsic size plus the table's own padding.
        nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8).isActive = true
        pathLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1).isActive = true
        pathLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8).isActive = true
        // ORDER MATTERS: on NSTextField, setting lineBreakMode to a truncating
        // mode (.byTruncatingTail) resets cell.wraps to false — ONE line only.
        // Word wrap + maximumNumberOfLines(2) gives the two-line preview with
        // an automatic trailing … from TextKit.
        // ORDER MATTERS (verified): a truncating lineBreakMode (.byTruncatingTail)
        // resets cell.wraps to false — the label collapses to ONE line and
        // self-sizing rows all come out single-line height. Word wrap keeps
        // the two-line preview; TextKit appends the trailing … itself.
        previewLabel.lineBreakMode = .byWordWrapping
        previewLabel.cell?.wraps = true
        previewLabel.maximumNumberOfLines = 2
        // Self-sizing rows measure the cell before its width is known; a
        // wrapping label then reports ONE-line height and the row clips the
        // second line. State the wrap width explicitly.
        previewLabel.preferredMaxLayoutWidth = ClipboardPanelController.panelWidth
            - PanelDesign.rowContentLeading - PanelDesign.rowIconSize
            - PanelDesign.rowIconToText - PanelDesign.rowContentTrailing

        let iconSize = PanelDesign.rowIconSize
        iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelDesign.rowContentLeading).isActive = true
        iconView.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        iconView.widthAnchor.constraint(equalToConstant: iconSize).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: iconSize).isActive = true

        thumbnailView.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: PanelDesign.rowIconToText).isActive = true
        thumbnailView.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        thumbnailView.widthAnchor.constraint(equalTo: thumbnailView.heightAnchor).isActive = true
        thumbSide = thumbnailView.heightAnchor.constraint(equalToConstant: 44)
        thumbSide.isActive = true

        for label in [nameLabel, pathLabel, previewLabel] {
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: PanelDesign.rowIconToText).isActive = true
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -PanelDesign.rowContentTrailing).isActive = true
        }
        previewLabel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8).isActive = true
        previewLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8).isActive = true
        textHeight = previewLabel.heightAnchor.constraint(equalToConstant: 19)
        textHeight.isActive = true
        // The table pads self-sized rows (~14pt total), so the cell is
        // taller than the label — anchor the label to center or it rides
        // the top pin while the icon centers (7pt skew on single lines).
        previewLabel.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        // Two-deck rows (named notes, file clips): name over dim detail;
        // the stack's pins drive the row height together with textHeight.
        nameLabel.setContentCompressionResistancePriority(.required, for: .vertical)
    }
}
extension ClipCell: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case NSSelectorFromString("insertNewline:"):
            endRenaming(commit: true)
            return true
        case NSSelectorFromString("cancelOperation:"):
            endRenaming(commit: false)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Focus moved elsewhere (panel resign, row click): cancel quietly.
        endRenaming(commit: false)
    }
}

/// Single-line inline rename input styled like the panel's other inputs.
final class RenameField: NSTextField {
    init() {
        super.init(frame: .zero)
        font = .systemFont(ofSize: 13, weight: .medium)
        isBordered = false
        isEditable = true
        isSelectable = true
        drawsBackground = true
        backgroundColor = .clear
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        focusRingType = .none
        cell?.usesSingleLineMode = true
        cell?.wraps = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func applyTheme(_ theme: CardTheme) {
        textColor = theme.foreground
        backgroundColor = theme.isDark
            ? NSColor.white.withAlphaComponent(0.10)
            : NSColor.white.withAlphaComponent(0.55)
        layer?.borderColor = theme.hairline.cgColor
    }
}

/// Table with a right-click hook: hit-tests the row and asks the controller
/// for its management menu (NotesTable precedent in SelectionToolbarHelper).
final class ClipTable: NSTableView {
    var onMenu: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard row >= 0 else { return nil }
        return onMenu?(row)
    }
}

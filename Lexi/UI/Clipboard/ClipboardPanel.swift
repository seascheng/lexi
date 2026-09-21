import AppKit

// Class declaration, stored properties, lifecycle (init/attach/updateNotes/
// show/hide/applyTheme), chrome construction/layout, and the panel's small
// top-level view types. Methods live in sibling extensions:
// ClipboardPanelChips.swift (chip row/drag/tag input), ClipboardPanelData.swift
// (reload/table data source+delegate), ClipboardPanelActions.swift (paste/
// context menus/keyboard). ClipCell.swift and ChipViews.swift hold the row/chip
// view types split out of this file.

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
/// `CardTheme`, `FlippedView`, `LauncherRowView`, `panelIcon`, `tagColor`,
/// `PanelDesign` (SelectionToolbarHelper.swift / LauncherPanel.swift) and the
/// TCP dispatch in `SelectionToolbarApp.handleRequestData`.
///
/// Layout follows hapigo's clipboard: chip tab row, search field, variable
/// preview rows with source-app icons, and a footer status strip — drawn in
/// the helper's goty visual language via the shared `PanelDesign` tokens.
final class ClipboardPanelController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
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

    /// Compact chrome rhythm: search strip (28pt) → 2pt gap → chips row
    /// (pills sit 2pt into their 32pt scroller) → tight visual chain.
    private static let searchStripHeight: CGFloat = 28
    private static let chipsRowY: CGFloat = 12 + searchStripHeight + 2

    /// The category that absorbs uncategorized + toolbar-note saves in the
    /// chip tabs.
    static let defaultTag = "Note"

    let panel: KeyablePanel

    /// Whether THIS panel owns the keyboard (the app-level Tab router needs
    /// it: panels are independent, Tab goes to whoever is key).
    var isKeyWindow: Bool { panel.isKeyWindow }

    /// Tab from the app-level router: cycle this panel's chip tabs.
    func cycleChipTabs() { cycleTabs(1) }

    private let root: NSView
    private let glassContent: NSView
    let searchField = PanelSearchField()
    var chipViews: [(kind: ChipKind, view: ChipPillView)] = []
    let scrollView = NSScrollView()
    let tableView = ClipTable()
    let emptyLabel = makePanelEmptyLabel()
    let footerLeft = NSTextField(labelWithString: "")
    let footerRight = NSTextField(labelWithString: "")
    var cardTheme: CardTheme = .dark
    /// Row index with an active inline rename session (its height comes
    /// from the session's two-deck shape; heightOfRow reads this during
    /// the table's tile pass — querying the row's live view there is
    /// re-entrant and aborts AppKit).
    var renamingRow: Int?

    /// Set once at helper startup; the monitor keeps filling it.
    var store: ClipboardStore?
    var rows: [Row] = []

    /// Pasteboard type carrying one note id (table row drag-reorder).
    static let noteDragType = NSPasteboard.PasteboardType("com.lexi.app.note-id")
    /// Flat selectable clips in display order (clipboard tab only).
    var visibleItems: [ClipboardItem] = []
    /// Small live cache of decoded thumbnails so scrolling doesn't re-read
    /// PNGs. Image rows only. NSCache evicts under memory pressure
    /// (class-keyed by uuid string).
    let thumbnailCache = NSCache<NSString, NSImage>()

    /// Notes snapshot (fed by the /card-notes push) + the tags table names.
    var notes: [ClipboardNote] = []
    var allTags: [String] = []
    /// Custom chip hex colors by tag name, refreshed with each notes push.
    var tagHexColors: [String: String] = [:]

    /// Which chip is active. `.clipboard` shows the history; `.tag(name)`
    /// shows that category's notes.
    var tab: Tab = .clipboard
    /// Inline "new category" input at the end of the chip row — hidden until
    /// the ＋ button is clicked.
    let tagInputView = ChipInputView()
    let addChip = AddTagButton()
    /// Horizontal stack of tab chips (AppKit-native flow: hide/insert/
    /// reorder all reflow automatically — no hand-rolled layout).
    var chipsContent = NSStackView()
    let chipsScrollView = NSScrollView()
    /// The app that was frontmost when the panel opened — the paste target.
    var previousApp: NSRunningApplication?

    /// Temporary footer message (e.g. vanished file) that self-clears on the
    /// next selection change or reload.
    var footerNoticeUntil: Date?

    enum Tab: Equatable {
        case clipboard
        case tag(String)
    }

    enum ChipKind: Equatable {
        case clipboard
        case tag(String)
    }

    enum Row {
        case header(String)
        case clip(ClipboardItem)
        case note(ClipboardNote)
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
            surface: .list,
            dark: cardTheme.isDark
        )
        panel.contentView = background
        glassContent = content
        glassContent.wantsLayer = true
        root = ClipboardPanelRootView(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 300))
        content.addSubview(root)
        super.init()
        panel.delegate = self
        // ⌘P (pin toggle) arrives as a key equivalent — the search field's
        // command path never sees modifier combos.
        panel.keyEquivalentHandler = { [weak self] event in
            // Esc folds the inline tag input no matter which view holds
            // focus (field-editor timing is not something to depend on).
            if event.type == .keyDown, event.characters == "\u{1b}",
               let self, !self.tagInputView.isHidden {
                self.endTagInput()
                return true
            }
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

    /// Notes snapshot from the /card-notes feed — same data the ActionPanel's
    /// notes list renders. Rebuilds the chip tab row and reloads.
    func updateNotes(notes: [ClipboardNote], categories: [String]) {
        self.notes = notes
        var categories = categories
        if !categories.contains(Self.defaultTag) {
            categories.append(Self.defaultTag) // uncategorized notes always have a home
        }
        allTags = categories
        // One query per push feeds every chip's color (replaces a per-chip
        // SELECT in tagChipColor).
        tagHexColors = Dictionary(
            LexiStore.noteCategories().map { ($0.name, $0.color) },
            uniquingKeysWith: { a, _ in a })
        rebuildChips()
        // A data refresh, not a navigation: the selected note stays
        // selected and the chip row keeps its scroll place.
        reload(preservingSelection: true, revealActiveChip: false)
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
        panel.makeFirstResponder(searchField.field)
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
        searchField.frame = NSRect(x: Self.side, y: 12, width: Self.panelWidth - Self.side * 2, height: Self.searchStripHeight)
        searchField.placeholder = "输入关键词搜索"
        searchField.field.delegate = self
        root.addSubview(searchField)

        // Chip row: horizontal scroller, one line, always the input at the end.
        // Sits 4pt under the search strip — a tight chrome rhythm.
        chipsScrollView.frame = NSRect(x: Self.side, y: Self.chipsRowY, width: Self.panelWidth - Self.side * 2, height: PanelDesign.pillHeight + 4)
        chipsScrollView.drawsBackground = false
        chipsScrollView.hasVerticalScroller = false
        // content == viewport stops actual scrolling, but trackpad swipes
        // still rubber-band the row vertically (elasticity is not gated on
        // "can scroll") — pin the axis dead.
        chipsScrollView.verticalScrollElasticity = .none
        chipsScrollView.hasHorizontalScroller = false // gestures still scroll; no bar
        chipsScrollView.translatesAutoresizingMaskIntoConstraints = true
        chipsContent = ChipsStackView(frame: NSRect(x: 0, y: 0, width: chipsScrollView.contentSize.width, height: PanelDesign.pillHeight + 4))
        chipsContent.orientation = .horizontal
        chipsContent.spacing = 0
        chipsContent.alignment = .centerY
        chipsContent.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        chipsContent.translatesAutoresizingMaskIntoConstraints = true
        chipsScrollView.documentView = chipsContent
        root.addSubview(chipsScrollView)

        addChip.target = self
        addChip.action = #selector(addChipClicked)
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
        // Manual exact row heights (heightOfRow): self-sizing rows add the
        // table's own padding on top of the cell's, so the same cell code
        // renders different gaps per row kind. With heights owned here the
        // cell fills the row rect exactly — padding is uniform by
        // construction.
        tableView.usesAutomaticRowHeights = false
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
        // Double-click = Enter: paste the row through and dismiss.
        tableView.target = self
        tableView.doubleAction = #selector(tableDoubleClicked)
        // Notes tabs drag-reorder rows (native table drag & drop).
        tableView.registerForDraggedTypes([Self.noteDragType])
        tableView.draggingDestinationFeedbackStyle = .regular
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        // Vertical breathing room comes from the FRAME inset in layoutChrome.
        root.addSubview(scrollView)
        // The mouse ONLY selects. Enter (search field's delegate path) is
        // the single trigger for hide-panel + paste-into-the-previous-app.
        // Right-click management menus (delete / move / rename).
        tableView.onMenu = { [weak self] row in
            self?.contextMenu(for: row)
        }

        footerLeft.font = .systemFont(ofSize: 12)
        footerRight.font = .systemFont(ofSize: 12)
        footerRight.alignment = .right
        root.addSubview(footerLeft)
        root.addSubview(footerRight)

        emptyLabel.stringValue = "暂无粘贴板历史 — 复制任意内容开始"
        root.addSubview(emptyLabel)
    }
    var dragChip: ChipPillView?
    var dragGrabOffset: CGFloat = 0
    /// Zero-width placeholder holding the drop slot — the stack reflows
    /// everyone around it automatically.
    let dragSpacer = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: PanelDesign.pillHeight))

    func syncChips() {
        for (kind, view) in chipViews {
            view.setSelected(kind == activeChipKind)
        }
    }

    var activeChipKind: ChipKind {
        switch tab {
        case .clipboard: return .clipboard
        case .tag(let name): return .tag(name)
        }
    }
    private func styleChrome() {
        // Content-layer veil: 26+ materials self-manage contrast (no
        // hand-painted scrim); legacy systems keep the TinyCast veil.
        PanelStyle.applyContentScrim(to: glassContent, dark: cardTheme.isDark)
        emptyLabel.textColor = cardTheme.tertiaryText
        footerLeft.textColor = cardTheme.secondaryText
        searchField.applyTheme(cardTheme)
    }

    /// Chips flow is the STACK's job: this only sizes the document to its
    /// content (the scroller needs the frame; the stack needs no layout
    /// math). Width floors at the viewport, height is the row.
    func refitChipsRow() {
        let width = max(chipsContent.fittingSize.width, chipsScrollView.contentSize.width)
        chipsContent.setFrameSize(NSSize(width: width, height: PanelDesign.pillHeight + 4))
    }

    private func layoutChrome(height: CGFloat) {
        refitChipsRow()
        scrollActiveChipVisible()
        // Symmetric breathing room: 6pt from the chips pill's bottom edge to
        // the first row, and 6pt from the last row to the footer label
        // (footerY + 5). The viewport therefore equals the row total exactly
        let listY = Self.chipsRowY + PanelDesign.pillHeight + 4 + 6
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
    /// Tag being RENAMED while the inline input shows (nil = creating).
    var tagRenameTarget: String?

    var tagInputField: NSTextField { tagInputView.field }
}

/// A note as seen by the clipboard panel: the ActionPanel owns editing; this
/// surface reads name/content/category and pastes content.
struct ClipboardNote {
    let id: Int64
    let name: String
    let content: String
    let category: String?
    /// Manual order inside the category (drag-reorder).
    var sort: Int = 0
}

enum ClipboardNotePreview {
    /// Whitespace-collapsed preview for rows and matching; empty when there
    /// is nothing readable.
    static func text(_ note: ClipboardNote) -> String? {
        guard !note.content.isEmpty else { return nil }
        let collapsed = note.content.whitespaceCollapsed
        return collapsed.isEmpty ? nil : collapsed
    }
}
/// Panel content root: swallows background right-clicks — only table rows
/// and tab chips carry context menus on this surface, the system menu
/// never belongs here. (FlippedView is final, so this is its own flipped
/// container.)
final class ClipboardPanelRootView: NSView {
    override var isFlipped: Bool { true }

    override func rightMouseDown(with event: NSEvent) {}
}

final class ClipTable: NSTableView {
    var onMenu: ((Int) -> NSMenu?)?

    /// Right-click on a row shows OUR menu; right-click on the empty area
    /// below the rows is swallowed — otherwise AppKit walks the responder
    /// chain and pops the system text menu, which is exactly the "wrong
    /// menu" complaint.
    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard row(at: point) >= 0 else { return }
        super.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard row >= 0 else { return nil }
        return onMenu?(row)
    }
}

extension NSColor {
    /// "#RRGGBB" parser for the stored chip colors.
    convenience init?(lexiHex hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return nil }
        self.init(
            calibratedRed: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1)
    }
}

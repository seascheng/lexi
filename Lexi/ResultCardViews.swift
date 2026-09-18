import AppKit

// ---------------------------------------------------------------------------
// Result card view types: rows, cells, table, dropdown, chips, inputs —
// plus the table/text delegates the card's Notes tab conforms to.
// ---------------------------------------------------------------------------

struct ShowPayload: Decodable {
    let text: String
    let x: Int
    let y: Int
    let downX: Int?
    let downY: Int?
    let pending: Bool?
    let actions: [ToolbarAction]?

    init(text: String, x: Int, y: Int, downX: Int? = nil, downY: Int? = nil,
         pending: Bool? = nil, actions: [ToolbarAction]? = nil) {
        self.text = text
        self.x = x
        self.y = y
        self.downX = downX
        self.downY = downY
        self.pending = pending
        self.actions = actions
    }
}

struct ResultShowPayload: Decodable {
    let runId: String?
    let featureId: String?
    var title: String?
    var icon: String?
    var autoSave: Bool?
    let inputText: String?

    init(runId: String? = nil, featureId: String? = nil, title: String? = nil,
         icon: String? = nil, autoSave: Bool? = nil, inputText: String? = nil) {
        self.runId = runId
        self.featureId = featureId
        self.title = title
        self.icon = icon
        self.autoSave = autoSave
        self.inputText = inputText
    }
}

struct ResultEventPayload: Decodable {
    let runId: String?
    let chunk: String?
    let done: Bool
    let error: String?
    let translationJson: String?
    let saved: Bool?

    init(runId: String? = nil, chunk: String? = nil, done: Bool = false,
         error: String? = nil, translationJson: String? = nil, saved: Bool? = nil) {
        self.runId = runId
        self.chunk = chunk
        self.done = done
        self.error = error
        self.translationJson = translationJson
        self.saved = saved
    }
}

struct CardActionsPayload: Decodable {
    struct Item: Decodable {
        let id: String
        let name: String
        let icon: String
        let kind: String?

        init(id: String, name: String, icon: String, kind: String? = nil) {
            self.id = id
            self.name = name
            self.icon = icon
            self.kind = kind
        }
    }
    struct PanelDef: Decodable {
        let id: String
        let name: String
        let icon: String

        init(id: String, name: String, icon: String) {
            self.id = id
            self.name = name
            self.icon = icon
        }
    }
    let actions: [Item]
    let panels: [PanelDef]?

    init(actions: [Item], panels: [PanelDef]? = nil) {
        self.actions = actions
        self.panels = panels
    }
}

/// One notes-table row (view-based NSTableView cell). The system provides
/// selection (accent capsule), row height, scrolling, and width tracking;
/// this cell only lays out its subviews and retints on selection/hover.
/// A borderless NSTextField draws its text top-aligned while its label
/// counterpart centers vertically — and the field EDITOR uses yet another
/// rect. Route draw/edit/select through one centered rect so the renamed
/// title sits exactly where the label was, mid-line, in both states.
final class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        var r = super.titleRect(forBounds: rect)
        let lineHeight = (font?.boundingRectForFont.height ?? 16).rounded()
        r.origin.y = rect.minY + ((rect.height - lineHeight) / 2).rounded()
        r.size.height = lineHeight
        return r
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                       delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: titleRect(forBounds: rect), in: controlView,
                   editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                         delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: titleRect(forBounds: rect), in: controlView,
                     editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: titleRect(forBounds: cellFrame), in: controlView)
    }
}

final class NoteRowCell: NSTableCellView, NSTextFieldDelegate {
    /// Traffic-light dot tinted by the note's tag hue (replaces the old
    /// per-row file glyph — same icon on every row carried no information).
    private let tagDot = NSView()
    private var tagName = ""
    let titleLabel = NSTextField(labelWithString: "")
    let contentLabel = NSTextField(labelWithString: "")
    private var tagLabel: NSTextField?
    private var tagButton: TagPillButton?
    private var onTagPicked: ((Int64, NSView) -> Void)?

    func fireTagClick() {
        if let noteId { onTagPicked?(noteId, tagButton ?? (self as NSView)) }
    }
    private var tagWidth: CGFloat = 40
    /// Inline rename editor: hidden until a double-click swaps it in.
    let titleEditor = NSTextField()
    var deleteButton: NSButton?
    private var onDelete: ((Int64) -> Void)?
    private var onRename: ((Int64, String) -> Void)?
    private var noteId: Int64?
    private var renameCancelled = false
    private var titleBeforeRename = ""
    private var caretToEndOnBegin = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        tagDot.wantsLayer = true
        tagDot.layer?.cornerRadius = 4
        addSubview(tagDot)
        addSubview(titleLabel)
        addSubview(contentLabel)

        let centeredCell = VerticallyCenteredTextFieldCell()
        centeredCell.stringValue = "" // bare cells ship titled "Field"
        centeredCell.isEditable = true
        centeredCell.isBordered = false
        centeredCell.font = .systemFont(ofSize: 13, weight: .medium)
        centeredCell.lineBreakMode = .byTruncatingTail
        centeredCell.usesSingleLineMode = true
        titleEditor.cell = centeredCell
        titleEditor.drawsBackground = false
        // SAME input surface as the Actions bar and search field:
        // inputFill + hairline + radius 8; focus border comes with the edit.
        titleEditor.wantsLayer = true
        titleEditor.layer?.cornerRadius = 8
        titleEditor.layer?.borderWidth = 1
        titleEditor.layer?.masksToBounds = true
        titleEditor.focusRingType = .none
        titleEditor.isHidden = true
        titleEditor.delegate = self
        addSubview(titleEditor)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Labels are the deepest hit-test targets and reject the first mouse by
    /// default — claim every non-button hit so the table gets the click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let hit = super.hitTest(point), hit is NSButton || hit === titleEditor {
            return hit
        }
        return self
    }

    var themeColors: CardTheme = .dark {
        didSet { applyThemeColors() }
    }

    func applyThemeColors() {
        titleEditor.textColor = themeColors.foreground
        titleEditor.layer?.backgroundColor = themeColors.inputFill.cgColor
        titleEditor.layer?.borderColor = themeColors.hairline.cgColor
        titleLabel.textColor = themeColors.foreground
        contentLabel.textColor = themeColors.secondaryText
        deleteButton?.contentTintColor = themeColors.tertiaryText
        refreshTagColors()
        if let tagButton {
            tagButton.contentTintColor = themeColors.secondaryText
            tagButton.layer?.backgroundColor = NSColor.labelColor
                .withAlphaComponent(themeColors.isDark ? 0.10 : 0.06).cgColor
        }

        // Rename editor: always its own surface (inputFill + foreground) —
        // following the capsule's white-on-accent made white-on-white text
        // on the light theme.
        titleEditor.textColor = themeColors.foreground
        titleEditor.backgroundColor = themeColors.inputFill
        titleEditor.layer?.borderColor = themeColors.hairline.cgColor
        titleEditor.layer?.borderWidth = 1
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyThemeColors() }
    }

    func configure(note: CardNotesPayload.Note, dark: Bool,
                   onDelete: ((Int64) -> Void)?,
                   onRename: ((Int64, String) -> Void)? = nil,
                   onTagPicked: ((Int64, NSView) -> Void)? = nil) {

        noteId = note.id
        self.onRename = onRename
        tagName = note.category ?? ""
        let titleText = note.name.isEmpty ? String(note.content.prefix(40)) : note.name
        titleLabel.stringValue = titleText
        if titleEditor.isHidden {
            titleEditor.stringValue = titleText
        }
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.cell?.wraps = false
        titleLabel.toolTip = note.content

        contentLabel.stringValue = note.content
        contentLabel.font = .systemFont(ofSize: 12)
        contentLabel.maximumNumberOfLines = 1
        contentLabel.cell?.truncatesLastVisibleLine = true
        contentLabel.cell?.wraps = false

        // Trailing category pill (one category per note). It is a
        // BUTTON: click opens the picker dropdown for this note.
        tagLabel?.removeFromSuperview()
        tagLabel = nil
        tagButton?.removeFromSuperview()
        tagButton = nil
        if let tag = note.category {
            let button = TagPillButton()
            button.title = tag
            button.isBordered = false
            button.font = .systemFont(ofSize: 10, weight: .medium)
            button.alignment = .center
            button.lineBreakMode = .byTruncatingTail
            button.toolTip = "Change tag"
            tagWidth = max((tag as NSString).size(withAttributes: [.font: button.font!]).width + 14, 34)
            button.wantsLayer = true
            button.layer?.cornerRadius = 8
            button.onTagClicked = { [weak self] in
                self?.fireTagClick()
            }
            addSubview(button)
            tagButton = button
        }

        if let deleteButton {
            deleteButton.removeFromSuperview()
        }
        if let id = note.id, let onDelete {
            let button = NSButton(image: lucideImage(for: "x", title: "Delete note") ?? NSImage(),
                                  target: self,
                                  action: #selector(deleteTapped))
            button.isBordered = false
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = "Delete note"
            button.identifier = NSUserInterfaceItemIdentifier(String(id))
            self.onDelete = onDelete
            deleteButton = button
            addSubview(button)
        }
        needsLayout = true
        refreshTagColors()
    }

    /// One hue per tag: the leading dot AND the pill text/fill share it, so
    /// tags are tellable apart pre-attentively (traffic-light language).
    func refreshTagColors() {
        let dark = themeColors.isDark
        if tagName.isEmpty {
            tagDot.isHidden = true
        } else {
            tagDot.isHidden = false
            tagDot.layer?.backgroundColor = tagColor(for: tagName, dark: dark).cgColor
        }
        if let tagButton, !tagName.isEmpty {
            let color = tagColor(for: tagName, dark: dark)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            tagButton.attributedTitle = NSAttributedString(
                string: tagName,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: color,
                    .paragraphStyle: paragraph,
                ]
            )
            tagButton.layer?.backgroundColor = color.withAlphaComponent(dark ? 0.16 : 0.12).cgColor
        }
    }

    @objc private func deleteTapped(_ sender: NSButton) {
        if let raw = sender.identifier?.rawValue, let id = Int64(raw) {
            onDelete?(id)
        }
    }

    /// Double-click → the title becomes an input; Enter or losing focus
    /// commits, Esc cancels.
    func beginRenaming() {
        guard noteId != nil else { return }
        titleBeforeRename = titleLabel.stringValue
        renameCancelled = false
        titleEditor.stringValue = titleBeforeRename
        titleLabel.isHidden = true
        titleEditor.isHidden = false
        caretToEndOnBegin = true
        titleEditor.layer?.borderColor = themeColors.foreground.withAlphaComponent(0.45).cgColor
        window?.makeFirstResponder(titleEditor)
        DispatchQueue.main.async { [weak self] in
            self?.placeCaretAtEndOnce()
        }
    }

    func placeCaretAtEndOnce() {
        guard caretToEndOnBegin, let editor = titleEditor.currentEditor() else { return }
        caretToEndOnBegin = false
        // Finder semantics: entering rename PRE-SELECTS everything, so
        // typing replaces and arrow keys/home reveal the caret as needed.
        editor.selectAll(nil)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard obj.object as? NSTextField === titleEditor else { return }
        placeCaretAtEndOnce()
    }

    func endRenaming() {
        titleEditor.layer?.borderColor = themeColors.hairline.cgColor
        titleEditor.isHidden = true
        titleLabel.isHidden = false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard obj.object as? NSTextField === titleEditor else { return }
        let committed = !renameCancelled
        endRenaming()
        guard committed, let id = noteId else { return }
        let newValue = titleEditor.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !newValue.isEmpty, newValue != titleBeforeRename {
            onRename?(id, newValue)
        } else {
            titleEditor.stringValue = titleBeforeRename
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === titleEditor else { return false }
        if commandSelector == NSSelectorFromString("cancelOperation:") {
            renameCancelled = true
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        // Content-first rows (Notes/Mail language): the tag-colored dot
        // rides the title line at the pill's own 14pt inset, the two-line
        // text block follows; the trailing column (tag pill + delete)
        // shares one right margin.
        tagDot.frame = NSRect(x: 14, y: 24, width: 8, height: 8)
        deleteButton?.frame = NSRect(x: w - 28, y: bounds.midY - 9, width: 18, height: 18)
        let hasTag = tagButton != nil
        if hasTag {
            tagButton!.frame = NSRect(x: w - 28 - 6 - tagWidth, y: bounds.midY - 8, width: tagWidth, height: 16)
        }
        let textX: CGFloat = 30
        let trailingX: CGFloat = (hasTag ? (w - 28 - 6 - tagWidth) : w - 28) - 6
        titleLabel.frame = NSRect(x: textX, y: 20, width: max(trailingX - textX, 24), height: 16)
        contentLabel.frame = NSRect(x: textX, y: 4, width: max(trailingX - textX, 24), height: 15)
        // Rename editor: same text origin as the title label, grown downward.
        titleEditor.frame = NSRect(
            x: titleLabel.frame.minX - 2,
            y: titleLabel.frame.minY - 4,
            width: trailingX - titleLabel.frame.minX + 2,
            height: 23
        )
    }
}

/// Row view: paints ONLY the hover (the system has none), mimicking the
/// system capsule's inset/radius so the two geometries read as one.
final class NotesTable: NSTableView {
    override var mouseDownCanMoveWindow: Bool { false }

    /// Responder-chain keyboard: the panel is key (OS-normal model), so
    /// Enter inserts the highlighted note and Tab cycles panel tabs — no
    /// global event tap involved.
    var onEnterKey: (() -> Void)?
    var onDoubleClickRow: ((Int) -> Void)?
    private var lastClickRow = -1
    private var lastClickTime = TimeInterval(0)

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 52: // Enter / keypad Enter
            onEnterKey?()
        default:
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // While a row's title editor is live, a click INSIDE that row belongs
        // to the edit (caret moves, selection clears) — running the table's
        // tracking would resign the editor and snap back to the label.
        // The event still belongs to the FIELD EDITOR: forward it, otherwise
        // double-click-to-select-word and drag-select die inside the editor.
        if let editor = window?.firstResponder as? NSText,
           editor.isFieldEditor,
           let host = editor.delegate as? NSTextField,
           host === (view(atColumn: 0, row: row(at: convert(event.locationInWindow, from: nil)), makeIfNecessary: false) as? NoteRowCell)?.titleEditor {
            editor.mouseDown(with: event)
            return
        }
        // The panel is nonactivating: NSTableView's own tracking silently
        // bails before the app is active. Select the clicked row
        // PROGRAMMATICALLY — works without key status.
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = self.row(at: point)
        if clickedRow >= 0 {
            // Double-click is ours to detect: the system's doubleAction dispatch
            // ran a longer event chain that beeped. Same row inside the
            // double-click interval = rename, nothing else.
            let now = event.timestamp
            if clickedRow == lastClickRow,
               now - lastClickTime < NSEvent.doubleClickInterval,
               let onDoubleClickRow {
                lastClickRow = -1
                onDoubleClickRow(clickedRow)
                return
            }
            lastClickRow = clickedRow
            lastClickTime = now
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
        super.mouseDown(with: event)
    }
}

/// In-card tag picker: flipped layer list pinned at the pill. One row per
/// known tag (check on the current), divider, clear row. System menus
/// misplace themselves on nonactivating panels - this stays in the card.
final class TagDropdownView: NSView {
    private let onPick: (String?) -> Void
    private let theme: CardTheme
    private var rows: [NSView] = []
    private(set) var naturalWidth: CGFloat = 120

    init(tags: [String], current: String?, theme: CardTheme, onPick: @escaping (String?) -> Void) {
        self.onPick = onPick
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        shadow = NSShadow()
        shadow?.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow?.shadowBlurRadius = 14
        shadow?.shadowOffset = NSSize(width: 0, height: -3)

        var y: CGFloat = 4
        func addRow(_ title: String, value: String?, checked: Bool) {
            let button = RowPickButton(title: title)
            button.font = .systemFont(ofSize: 12, weight: checked ? .medium : .regular)
            button.alignment = .left
            button.lineBreakMode = .byTruncatingTail
            if checked, let check = lucideImage(for: "check", title: title, color: theme.foreground) {
                check.size = NSSize(width: 12, height: 12)
                let attachment = NSTextAttachment()
                attachment.image = check
                attachment.bounds = NSRect(x: 0, y: (button.font!.capHeight - 12) / 2, width: 12, height: 12)
                let title = NSMutableAttributedString(string: title, attributes: [
                    .font: button.font!,
                    .foregroundColor: theme.foreground,
                ])
                title.append(NSAttributedString(string: "  "))
                title.append(NSAttributedString(attachment: attachment))
                button.attributedTitle = title
            } else {
                button.attributedTitle = NSAttributedString(string: title, attributes: [
                    .font: button.font!,
                    .foregroundColor: value == nil ? theme.secondaryText : theme.foreground,
                ])
            }
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.onPickRow = { [weak self] in self?.onPick(value) }
            rows.append(button)
            addSubview(button)
            y += 26
        }
        for tag in tags {
            addRow(tag, value: tag, checked: tag == current)
        }
        // Width hugs the longest label (+check mark slot); never the old
        // blanket 150+.
        let longest = (["No tag"] + tags).map {
            ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
        }.max() ?? 60
        naturalWidth = min(max(longest + 46, 96), 190)
        if !tags.isEmpty {
            let divider = NSView()
            divider.wantsLayer = true
            divider.layer?.backgroundColor = theme.hairline.cgColor
            rows.append(divider)
            addSubview(divider)
            y += 5
        }
        addRow("No tag", value: nil, checked: current == nil)
        frame.size = NSSize(width: 150, height: y)
        sizeToFit(width: 150)
    }

    func sizeToFit(width: CGFloat) {
        frame.size.width = width
        var y: CGFloat = 3
        for view in rows {
            if view is RowPickButton {
                view.frame = NSRect(x: 6, y: y, width: width - 12, height: 24)
                y += 26
            } else {
                view.frame = NSRect(x: 8, y: y + 2, width: width - 16, height: 1)
                y += 5
            }
        }
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // OPAQUE card-colored panel + hairline. Layer backgrounds never
        // composited here; painting does (same as the notes row pills).
        theme.background.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        theme.hairline.setStroke()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 8,
            yRadius: 8
        ).stroke()
    }

    required init?(coder: NSCoder) {
        fatalError("programmatic only")
    }
}

/// A dropdown row: whole-row click, goty quiet-wash hover.
final class RowPickButton: NSButton {
    var onPickRow: (() -> Void)?
    private var hoverArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        target = self
        action = #selector(rowPicked)
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    override var title: String {
        didSet {}
    }

    /// Text sits 10pt from the row's left edge, not flush against it.
    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 8, dy: 0)
        attributedTitle.draw(in: NSRect(
            x: inset.minX + 2,
            y: (bounds.height - attributedTitle.size().height) / 2,
            width: inset.width,
            height: attributedTitle.size().height
        ))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        if let hoverArea { addTrackingArea(hoverArea) }
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
        super.mouseDown(with: event)
        onPickRow?()
    }

    @objc private func rowPicked() {}

    required init?(coder: NSCoder) {
        fatalError("programmatic only")
    }
}


/// Tag pill: a borderless button that fires on ANY click inside its bounds.
final class TagPillButton: NSButton {
    var onTagClicked: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init() {
        super.init(frame: .zero)
        target = self
        action = #selector(pillClicked)
    }

    @objc private func pillClicked() {
        onTagClicked?()
    }

    required init?(coder: NSCoder) {
        fatalError("programmatic only")
    }
}

final class NoteRowView: NSTableRowView {
    private var hoverArea: NSTrackingArea?
    private var hovering = false
    var pillColor: NSColor = .clear { didSet { needsDisplay = true } }
    // With selectionHighlightStyle = .none the table does NOT redraw on
    // selection change — without this the deselected row keeps its stale
    // pill and two rows read as selected at once.
    override var isSelected: Bool {
        didSet { needsDisplay = true }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        if let hoverArea { addTrackingArea(hoverArea) }
    }

    override func mouseEntered(with event: NSEvent) {
        // Tracking areas ignore occlusion by sibling layers (the tag
        // dropdown floats above the list): only hover when THIS row is the
        // top-most view under the cursor.
        if let top = window?.contentView?.hitTest(event.locationInWindow),
           top === self || top.isDescendant(of: self) {
            hovering = true
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    func clearHover() {
        hovering = false
        needsDisplay = true
    }

    var hoverColor: NSColor = NSColor.labelColor.withAlphaComponent(0.06) {
        didSet { needsDisplay = true }
    }

    // goty tty7 pill: hugging the row's edge by the same inset on both
    // sides, full-radius caps. Selection is a quiet same-hue wash (text
    // keeps its color); hover is one step lighter.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let pill = bounds.insetBy(dx: 3, dy: 2)
        let path = NSBezierPath(
            roundedRect: pill,
            xRadius: 8,
            yRadius: 8
        )
        if isSelected {
            // Selection = the wash capsule; glyphs keep their own color.
            pillColor.setFill()
            path.fill()
        } else if hovering {
            hoverColor.setFill()
            path.fill()
        }
    }
}

struct CardNotesPayload: Decodable {
    var categories: [String]?
    struct Note: Decodable {
        let id: Int64?
        let name: String
        let category: String?
        let content: String

        init(id: Int64? = nil, name: String, category: String? = nil, content: String) {
            self.id = id
            self.name = name
            self.category = category
            self.content = content
        }
    }
    let notes: [Note]

    init(notes: [Note], categories: [String]? = nil) {
        self.notes = notes
        self.categories = categories
    }
}

struct CardReviewPayload: Decodable {
    struct ReviewWord: Decodable {
        let id: Int64
        let word: String
        let translation: String?
        let pos: String?
        let entryType: String?
    }
    let word: ReviewWord?
}

final class CardRun {
    let id: String
    let featureId: String
    let title: String
    let icon: String
    var status: String = "loading" // loading | streaming | ready | error
    var text: String = ""
    var translationJson: String?
    var entryType: String = "word"
    var saved = false
    init(id: String, featureId: String, title: String, icon: String) {
        self.id = id
        self.featureId = featureId
        self.title = title
        self.icon = icon
    }
}

/// A run chip in the tabs strip: icon + title + inline dismiss (×),
/// whole-chip click selects the run.
final class RunChipView: NSView {
    var onSelected: (() -> Void)?
    var onDismissed: (() -> Void)?
    let fitWidth: CGFloat
    private let iconView: NSImageView
    private let titleLabel: NSTextField
    private let dismissButton: NSButton
    private var isActive = false
    private var isDark = false
    private var statusDot: NSView!
    var runId = ""
    var statusKey = ""
    var isActiveChip = false

    init(run: CardRun, dark: Bool) {
        isDark = dark
        runId = run.id
        statusKey = run.status
        let icon = lucideImage(for: run.icon, title: run.title) ?? NSImage()
        let title = run.title
        let titleWidth = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width + 8
        fitWidth = 8 + 4 + 5 + 13 + 4 + titleWidth + 8 + 14
        let frame = NSRect(x: 0, y: 0, width: fitWidth, height: 24)

        statusDot = NSView(frame: NSRect(x: 8, y: 10, width: 4, height: 4))
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3

        iconView = NSImageView(frame: NSRect(x: 18, y: 5.5, width: 13, height: 13))
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyDown

        titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.frame = NSRect(x: 35, y: 4.5, width: titleWidth, height: 15)

        dismissButton = NSButton(title: "", target: nil, action: nil)
        dismissButton.bezelStyle = .regularSquare
        dismissButton.isBordered = false
        dismissButton.title = "✕"
        dismissButton.font = .systemFont(ofSize: 8)
        dismissButton.frame = NSRect(x: fitWidth - 20, y: 4, width: 14, height: 14)

        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        addSubview(statusDot)
        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(dismissButton)
        dismissButton.target = self
        dismissButton.action = #selector(dismissTapped)
        setActive(false, dark: dark)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func setActive(_ active: Bool, dark: Bool) {
        isActive = active
        isActiveChip = active
        isDark = dark
        layer?.backgroundColor = active
            ? (dark ? NSColor.white.withAlphaComponent(0.14).cgColor : NSColor.black.withAlphaComponent(0.08).cgColor)
            : NSColor.clear.cgColor
        let color: NSColor = active ? .labelColor : .secondaryLabelColor
        titleLabel.textColor = color
        iconView.contentTintColor = color
        statusDot.layer?.backgroundColor = Self.dotColor(for: statusKey).cgColor
    }

    private static func dotColor(for status: String) -> NSColor {
        switch status {
        case "error": return .systemRed.withAlphaComponent(0.85)
        case "ready": return .controlAccentColor.withAlphaComponent(0.65)
        default: return .secondaryLabelColor.withAlphaComponent(0.55)
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        onSelected?()
    }

    @objc private func dismissTapped() {
        onDismissed?()
    }
}

/// NSTextView subclass is not needed for behavior — the delegate handles
/// Enter/Esc — but a distinct type keeps the firstResponder check readable.
final class CardInputTextView: NSTextView {
    var onBecameFocus: (() -> Void)?
    var onLostFocus: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onBecameFocus?() }
        return ok
    }
    /// Multiline text views have no native placeholder; this one paints the
    /// hint INSIDE draw() at textContainerOrigin with the same font — text
    /// hint and real text share one layout pipeline, so they cannot drift.
    var placeholder: NSAttributedString?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let placeholder else { return }
        let origin = textContainerOrigin
        let lineH = font?.boundingRectForFont.height.rounded() ?? 16
        placeholder.draw(in: NSRect(
            x: origin.x,
            y: origin.y,
            width: bounds.width - origin.x * 2,
            height: lineH
        ))
    }

    override func resignFirstResponder() -> Bool {
        onLostFocus?()
        return super.resignFirstResponder()
    }
}

/// Single-line card input: native NSTextField with the placeholder STRING
/// drawn by the cell itself — caret and placeholder share one layout, so
/// they cannot drift apart. Vertically centered via the same cell used by
/// the inline rename editor.
class CardInputTextField: NSTextField {
    var onBecameFocus: (() -> Void)?
    var onLostFocus: (() -> Void)?
    var onCommit: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onBecameFocus?() }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        onLostFocus?()
        return super.resignFirstResponder()
    }
}

/// Lightweight Markdown → NSAttributedString for the result card.
/// Supports headings, lists, quotes, fenced code, bold/italic/inline code —
/// enough to mirror the WebView renderer's output shapes. Zero dependencies.
enum LightMarkdown {
    static func attributed(_ markdown: String, dark: Bool) -> NSAttributedString {
        let body = dark
            ? NSColor.white.withAlphaComponent(0.9)
            : NSColor.black.withAlphaComponent(0.85)
        let muted = dark
            ? NSColor.white.withAlphaComponent(0.55)
            : NSColor.black.withAlphaComponent(0.55)
        let codeBackground = dark
            ? NSColor.white.withAlphaComponent(0.08)
            : NSColor.black.withAlphaComponent(0.06)
        let bodyFont = NSFont.systemFont(ofSize: 13)
        let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        paragraphStyle.paragraphSpacing = 8
        let listStyle = NSMutableParagraphStyle()
        listStyle.lineSpacing = 3
        listStyle.headIndent = 18

        let out = NSMutableAttributedString()
        var inCode = false
        var codeLines: [String] = []
        var paragraphLines: [String] = []

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            let paragraph = NSMutableAttributedString(
                string: paragraphLines.joined(separator: "\n"),
                attributes: [.font: bodyFont, .foregroundColor: body, .paragraphStyle: paragraphStyle]
            )
            applyInline(paragraph, bodyFont: bodyFont, body: body, mono: monoFont, codeBg: codeBackground)
            out.append(paragraph)
            paragraphLines.removeAll()
        }

        func flushCode() {
            guard !codeLines.isEmpty else { return }
            let text = codeLines.joined(separator: "\n")
            let block = NSMutableAttributedString(
                string: text + "\n",
                attributes: [
                    .font: monoFont,
                    .foregroundColor: body,
                    .backgroundColor: codeBackground,
                    .paragraphStyle: paragraphStyle,
                ]
            )
            out.append(block)
            codeLines.removeAll()
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCode {
                    flushCode()
                } else {
                    flushParagraph()
                    inCode = true
                }
                continue
            }
            if inCode {
                codeLines.append(rawLine)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if trimmed.hasPrefix("#") {
                flushParagraph()
                let level = trimmed.prefix(while: { $0 == "#" }).count
                let heading = trimmed.drop(while: { $0 == "#" })
                    .trimmingCharacters(in: .whitespaces)
                let size: CGFloat = level <= 1 ? 17 : (level == 2 ? 15 : 14)
                out.append(NSAttributedString(string: heading + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                    .foregroundColor: body,
                ]))
                continue
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                flushParagraph()
                let item = NSMutableAttributedString(
                    string: "•  " + trimmed.dropFirst(2) + "\n",
                    attributes: [.font: bodyFont, .foregroundColor: body, .paragraphStyle: listStyle]
                )
                applyInline(item, bodyFont: bodyFont, body: body, mono: monoFont, codeBg: codeBackground)
                out.append(item)
                continue
            }

            if trimmed.hasPrefix("> ") {
                flushParagraph()
                out.append(NSAttributedString(
                    string: "▎" + trimmed.dropFirst(2) + "\n",
                    attributes: [.font: bodyFont, .foregroundColor: muted, .paragraphStyle: listStyle]
                ))
                continue
            }

            paragraphLines.append(rawLine)
        }

        if inCode { flushCode() }
        flushParagraph()
        return out
    }

    /// Inline `code`, **bold**, *italic*. Each pass recomputes its NSRange
    /// against the current string — a stale range from an earlier
    /// replacement is out of bounds and NSRegularExpression throws
    /// NSRangeException, which is fatal in Swift (no ObjC catch).
    private static func applyInline(
        _ text: NSMutableAttributedString,
        bodyFont: NSFont,
        body: NSColor,
        mono: NSFont,
        codeBg: NSColor
    ) {
        let bold = NSFontManager.shared.convert(bodyFont, toHaveTrait: .boldFontMask)
        let italic = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)

        replaceInline(text, pattern: "`([^`]+)`", attributes: [
            .font: mono, .foregroundColor: body, .backgroundColor: codeBg,
        ])
        replaceInline(text, pattern: "\\*\\*([^*]+)\\*\\*", attributes: [.font: bold])
        replaceInline(text, pattern: "\\*([^*]+)\\*", attributes: [.font: italic])
    }

    /// Replace `pattern` matches with their capture group, applying
    /// `attributes` over the replacement. Matches are applied back-to-front
    /// so earlier offsets survive each replacement.
    private static func replaceInline(
        _ text: NSMutableAttributedString,
        pattern: String,
        attributes: [NSAttributedString.Key: Any]
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let current = text.string
        let full = NSRange(location: 0, length: (current as NSString).length)
        for match in regex.matches(in: current, range: full).reversed() {
            guard let inner = Range(match.range(at: 1), in: current) else { continue }
            let innerText = String(current[inner])
            text.replaceCharacters(in: match.range, with: innerText)
            text.addAttributes(
                attributes,
                range: NSRange(location: match.range.location, length: (innerText as NSString).length)
            )
        }
    }
}


extension SelectionToolbarApp: NSTextViewDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSTextField === noteSearchField else { return }
        noteSearchText = noteSearchField.stringValue
        applyNoteFilters()
    }

    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === inputTextView else { return }
        // AiForm parity: re-measure and re-flow single- vs multi-line on
        // every edit, and re-enable the action buttons when text exists.
        layoutResultCard()
        rebuildInputButtons()
    }

    func textDidBeginEditing(_ notification: Notification) {
        guard notification.object as? NSTextView === inputTextView else { return }
        setInputFocused(true)
    }

    func textDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextView === inputTextView else { return }
        setInputFocused(false)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === inputTextView else { return false }
        let newline = NSSelectorFromString("insertNewline:")
        let cancel = NSSelectorFromString("cancelOperation:")
        if commandSelector == newline {
            // Enter runs the default feature; Shift+Enter keeps a newline
            // (WebView AiForm keydown parity).
            if !NSEvent.modifierFlags.contains(.shift) {
                submitInput(kind: "feature", id: "")
                return true
            }
            return false
        }
        if commandSelector == cancel {
            escapeResultCardIfNeeded()
            return true
        }
        return false
    }
}



extension SelectionToolbarApp {
    /// Hovers are the only self-drawn effect; scrolling invalidates them.
    @objc func notesClipScrolled() {
        let range = notesTableView.rows(in: notesTableView.visibleRect)
        for row in range.location..<max(range.location, range.location + range.length) {
            if let rowView = notesTableView.rowView(atRow: row, makeIfNecessary: false) as? NoteRowView {
                rowView.clearHover()
            }
        }
    }
}

extension SelectionToolbarApp: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === noteSearchField else { return false }
        if commandSelector == NSSelectorFromString("cancelOperation:") {
            if !noteSearchField.stringValue.isEmpty {
                noteSearchField.stringValue = ""
                noteSearchText = ""
                applyNoteFilters()
            } else {
                notesTableView.window?.makeFirstResponder(notesTableView)
            }
            return true
        }
        return false
    }
}

extension SelectionToolbarApp: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        displayedNotes.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < displayedNotes.count else { return nil }
        let cell = tableView.makeView(
            withIdentifier: NSUserInterfaceItemIdentifier("NoteRow"),
            owner: self
        ) as? NoteRowCell ?? NoteRowCell(frame: .zero)
        cell.identifier = NSUserInterfaceItemIdentifier("NoteRow")
        let note = displayedNotes[row]
        cell.configure(note: note, dark: theme == .dark,
                       onDelete: { [weak self] id in
                           self?.noteDeleteClickedId(id)
                       },
                       onRename: { [weak self] id, name in
                           self?.noteRenamed(id: id, name: name)
                       },
                       onTagPicked: { [weak self] id, anchor in
                           self?.showTagMenu(noteId: id, tag: note.category, anchor: anchor)
                       })
        cell.themeColors = cardTheme
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if let reused = tableView.makeView(
            withIdentifier: NSUserInterfaceItemIdentifier("NoteRowView"),
            owner: self
        ) as? NoteRowView {
            return reused
        }
        let view = NoteRowView(frame: .zero)
        view.identifier = NSUserInterfaceItemIdentifier("NoteRowView")
        view.hoverColor = cardTheme.hoverFill
        view.pillColor = cardTheme.selectedFill
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        FileLog.write("SEL didChange row=\(notesTableView.selectedRow)")
        let selected = notesTableView.selectedRow
        if selected >= 0, selected < displayedNotes.count {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(displayedNotes[selected].content, forType: .string)
        }
    }
}


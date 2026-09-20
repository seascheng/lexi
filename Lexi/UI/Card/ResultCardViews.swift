import AppKit

// ---------------------------------------------------------------------------
// Result card view types: rows, cells, table, dropdown, chips —
// the reusable AppKit views the card's Notes tab is built from.
// ---------------------------------------------------------------------------

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
    /// Stored category colors (name → hex), pushed with the notes feed.
    private var tagHexColors: [String: String] = [:]
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
                   tagHexColors: [String: String] = [:],
                   onDelete: ((Int64) -> Void)?,
                   onRename: ((Int64, String) -> Void)? = nil,
                   onTagPicked: ((Int64, NSView) -> Void)? = nil) {

        noteId = note.id
        self.onRename = onRename
        self.tagHexColors = tagHexColors
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
            let button = NSButton(image: panelIcon(for: "x", title: "Delete note") ?? NSImage(),
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
    /// Stored category color first, hash hue otherwise — the same rule the
    /// clipboard panel's chip dots use.
    func refreshTagColors() {
        let dark = themeColors.isDark
        let color: NSColor
        if let hex = tagHexColors[tagName], !hex.isEmpty,
           let stored = NSColor(lexiHex: hex) {
            color = stored
        } else {
            color = tagColor(for: tagName, dark: dark)
        }
        if tagName.isEmpty {
            tagDot.isHidden = true
        } else {
            tagDot.isHidden = false
            tagDot.layer?.backgroundColor = color.cgColor
        }
        if let tagButton, !tagName.isEmpty {
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshHoverTracking(&hoverArea)
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
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


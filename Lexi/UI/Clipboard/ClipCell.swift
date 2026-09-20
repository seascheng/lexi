import AppKit



/// Section header row (「置顶」).
final class ClipboardHeaderCell: NSView {
    static let height: CGFloat = 28

    private let label = NSTextField(labelWithString: "")
    private var didLayout = false

    override var isFlipped: Bool { true }

    func configure(title: String, color: NSColor) {
        label.stringValue = title.uppercased()
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = color
        if !didLayout {
            didLayout = true
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(
            x: PanelDesign.rowContentLeading,
            y: (bounds.height - 14) / 2,
            width: bounds.width - PanelDesign.rowContentLeading - PanelDesign.rowContentTrailing,
            height: 14
        )
    }
}

/// Clipboard row — frame layout, one padding set, no Auto Layout. The
/// table hands the cell the exact row rect (`heightOfRow` asks this class
/// for the height), and `layout()` positions every subview from the SAME
/// measurement helpers that computed it, so row height and rendered
/// content can never disagree.
///
/// Geometry, identical on every row kind:
///   icon 24×24 at rowContentLeading, vertically centered on the FIRST
///     text line (image rows: on the thumbnail box) — icon and text read
///     as one horizontal line
///   text column at rowContentLeading + rowIconSize + rowIconToText,
///     padded rowPaddingVertical top/bottom, rowContentTrailing right
///
/// Heights (all from one measuring label — cellSize runs the same TextKit
/// engine that draws, so the numbers match what renders):
///   text  → wrapped preview height, capped at 5 lines; beyond that
///           TextKit appends the trailing … itself
///   image → exactly the 5-line text box
///   file  → name line over a single-line path (middle-…)
///   note  → named: name over content (2-line cap); unnamed: text row
final class ClipCell: NSView {
    override var isFlipped: Bool { true }

    private enum Deck {
        case text
        case image
        case twoDeck
    }

    private var renameCommit: ((String) -> Void)?
    /// Session-end hook: the controller drops its row index before the
    /// row-height re-ask (heightOfRow serves the session height by index).
    private var renameEnd: (() -> Void)?
    private var isRenaming = false
    /// True when the cell already rendered name+content (its name line
    /// becomes the editor); false when the cell was content-only and the
    /// session switches it to the name+content style.
    private var renameUsesNameLine = false
    /// Esc sets this; every other session end (Enter, focus loss) commits.
    private var renameCancelled = false
    /// Content-only geometry captured at morph, restored on cancel.
    private var renameSavedGeometry: Geometry?
    private var didInstall = false
    private var geometry = Geometry()

    private let iconView = NSImageView()
    private let thumbnailView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")  // file/note name (first line)
    private let pathLabel = NSTextField(labelWithString: "")  // file path / note content
    private let previewLabel = NSTextField(wrappingLabelWithString: "")
    /// Inline rename editor: rides the name line during a session.
    private let nameEditor = RenameField()

    // Normal (unselected) label colors for this row's configured deck;
    // draw() flips every label to white while the row is selected (the
    // system selection fill is blue in both themes).
    private var contentColor: NSColor = .white
    private var detailColor: NSColor = .systemGray

    // MARK: measurement — one engine for row heights and layout

    static let textX: CGFloat = PanelDesign.rowContentLeading
        + PanelDesign.rowIconSize + PanelDesign.rowIconToText
    static let textWidth: CGFloat = ClipboardPanelController.panelWidth
        - textX - PanelDesign.rowContentTrailing

    private static let previewFont = NSFont.systemFont(ofSize: 13)
    private static let nameFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    private static let detailFont = NSFont.systemFont(ofSize: 12)

    /// The text cell draws its content with a hair of slack inside its
    /// frame; every measured label height carries it so descenders never
    /// clip on an exact-fit frame.
    private static let cellEpsilon: CGFloat = 2

    /// Exact DRAWN height of `text`: an NSLayoutManager with the same
    /// font, word wrap and container width TextKit renders the label
    /// with, summed over at most `maxLines` line fragments. Fragment
    /// rects carry the real per-line heights — cellSize assumes the
    /// tallest fallback font for EVERY line, over-reports mixed
    /// CJK/latin text, and the surplus then clipped instead of
    /// truncating. Main-thread only (every caller is a table delegate
    /// path).
    private static func drawnHeight(text: String, font: NSFont, width: CGFloat, maxLines: Int) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let storage = NSTextStorage(attributedString: NSAttributedString(
            string: text,
            attributes: [.font: font, .paragraphStyle: paragraph]))
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            containerSize: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        var height: CGFloat = 0
        var lines = 0
        var glyphIndex = 0
        while lines < maxLines, glyphIndex < layoutManager.numberOfGlyphs {
            var lineRange = NSRange()
            let rect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineRange)
            height = rect.maxY
            lines += 1
            glyphIndex = NSMaxRange(lineRange)
        }
        return height
    }

    /// One line of `font` (tallest CJK glyph) — floor for empty text and
    /// the unit the icon centers against.
    private static func fontLineHeight(_ font: NSFont) -> CGFloat {
        drawnHeight(text: "祥", font: font, width: 10_000, maxLines: 1)
    }

    /// Height of `text` as ONE line — the first line the icon aligns to,
    /// with its real fallback-font metrics.
    private static func firstLineHeight(text: String, font: NSFont) -> CGFloat {
        max(drawnHeight(text: text, font: font, width: 10_000, maxLines: 1),
            fontLineHeight(font))
    }

    /// Wrapped height of `text` at the row's text width, floored at one
    /// line, capped at `maxLines` lines (… renders past the cap).
    private static func wrappedHeight(text: String, font: NSFont, maxLines: Int) -> CGFloat {
        max(drawnHeight(text: text, font: font, width: textWidth, maxLines: maxLines),
            fontLineHeight(font)) + cellEpsilon
    }

    // MARK: row geometry — heightOfRow and layout() share these numbers

    /// Everything heightOfRow and layout() need for one row, from one
    /// measurement pass — the row rect and the subview frames can never
    /// disagree.
    private struct Geometry {
        var deck: Deck = .text
        /// Text deck: the preview label frame. Image deck: the centered
        /// placeholder line.
        var previewHeight: CGFloat = 19
        /// The first line's height the icon centers on (text deck).
        var firstLineHeight: CGFloat = 19
        /// Two-deck name / detail label frames.
        var nameHeight: CGFloat = 19
        var detailHeight: CGFloat = 17
        /// Image deck: thumbnail frame width — the 5-line box scaled to
        /// the image's aspect so the bitmap fills the box height exactly
        /// (no letterbox slack inside the row's padding).
        var thumbnailWidth: CGFloat = ClipCell.fiveLineBox

        /// Content height inside the row padding.
        var contentHeight: CGFloat {
            switch deck {
            case .text: return previewHeight
            case .image: return ClipCell.fiveLineBox
            case .twoDeck: return nameHeight + 1 + detailHeight
            }
        }
    }

    /// The 5-line text box: image rows render exactly this height and no
    /// text row may exceed it — five explicit CJK lines through the same
    /// engine that draws (the tallest common metrics).
    static let fiveLineBox = drawnHeight(
        text: String(repeating: "祥\n", count: 5), font: previewFont,
        width: 10_000, maxLines: 5) + cellEpsilon

    /// Widest a thumbnail may reach (ultra-wide captures clamp here and
    /// fall back to aspect-fitting inside).
    private static let thumbnailMaxWidth: CGFloat = 240

    static func rowHeight(for item: ClipboardItem) -> CGFloat {
        PanelDesign.rowPaddingVertical * 2 + geometry(for: item).contentHeight
    }

    static func rowHeight(forNote note: ClipboardNote) -> CGFloat {
        PanelDesign.rowPaddingVertical * 2 + geometry(forNote: note).contentHeight
    }

    private static func geometry(for item: ClipboardItem) -> Geometry {
        var g = Geometry()
        switch item.kind {
        case .text:
            g.deck = .text
            let text = item.previewText ?? ""
            g.previewHeight = wrappedHeight(text: text, font: previewFont, maxLines: 5)
            g.firstLineHeight = firstLineHeight(text: text, font: previewFont)
        case .image:
            g.deck = .image
            g.previewHeight = firstLineHeight(text: "图片", font: detailFont) + cellEpsilon
            // The icon top-aligns exactly like a text row's: against the
            // first preview-font line the 5-line box starts with.
            g.firstLineHeight = fontLineHeight(previewFont)
        case .file:
            g.deck = .twoDeck
            let url = URL(fileURLWithPath: item.text ?? "")
            g.nameHeight = firstLineHeight(text: url.lastPathComponent, font: nameFont) + cellEpsilon
            g.detailHeight = firstLineHeight(
                text: url.deletingLastPathComponent().path, font: detailFont) + cellEpsilon
        }
        return g
    }

    private static func geometry(forNote note: ClipboardNote) -> Geometry {
        var g = Geometry()
        let content = ClipboardNotePreview.text(note) ?? ""
        if note.name.isEmpty {
            g.deck = .text
            g.previewHeight = wrappedHeight(text: content, font: previewFont, maxLines: 5)
            g.firstLineHeight = firstLineHeight(text: content, font: previewFont)
        } else {
            g.deck = .twoDeck
            g.nameHeight = firstLineHeight(text: note.name, font: nameFont) + cellEpsilon
            g.detailHeight = wrappedHeight(text: content, font: detailFont, maxLines: 2)
        }
        return g
    }

    // MARK: rename

    /// Rename-session geometry: the name slot holds the editor (one
    /// name-font line), the content wraps below capped at 2 lines — the
    /// same shape a named note renders.
    private static func renameGeometry(content: String) -> Geometry {
        var g = Geometry()
        g.deck = .twoDeck
        g.nameHeight = fontLineHeight(nameFont) + cellEpsilon
        g.detailHeight = wrappedHeight(text: content, font: detailFont, maxLines: 2)
        return g
    }

    /// Row height while this cell's rename session is active (a
    /// content-only cell switches to the name+content shape, so the row
    /// height follows the session).
    static func renameRowHeight(forNote note: ClipboardNote) -> CGFloat {
        PanelDesign.rowPaddingVertical * 2
            + renameGeometry(content: ClipboardNotePreview.text(note) ?? "").contentHeight
    }

    func beginRenaming(
        current: String,
        onCommit: @escaping (String) -> Void,
        onEnd: @escaping () -> Void
    ) {
        renameCommit = onCommit
        renameEnd = onEnd
        renameCancelled = false
        isRenaming = true
        // Style rules: a named note already renders name+content — its
        // name line simply becomes the editor, nothing moves. A content-
        // only note switches to the name+content style for the session:
        // the caret blinks in the (empty) name slot, the content collapses
        // to the 2-line detail, the row height follows — and canceling
        // switches the style back.
        renameUsesNameLine = geometry.deck == .twoDeck
        if renameUsesNameLine {
            nameLabel.isHidden = true
        } else {
            enterRenameDeck()
        }
        nameEditor.stringValue = current
        nameEditor.font = Self.nameFont
        nameEditor.frame = renameEditorFrame()
        nameEditor.textColor = enclosingRowIsSelected ? .white : contentColor
        nameEditor.isHidden = false
        noteRowHeightChanged()
        window?.makeFirstResponder(nameEditor)
        if let editor = nameEditor.currentEditor() as? NSTextView {
            // Shared field editor defaults (white background, foreign
            // caret) are cleared at focus time — the begin-editing
            // delegate note only fires on the first keystroke, far too
            // late.
            editor.drawsBackground = false
            editor.backgroundColor = .clear
            editor.insertionPointColor = nameEditor.textColor ?? .white
        }
        nameEditor.currentEditor()?.selectAll(nil)
    }

    /// The name line's frame (the cell is always two-deck during a
    /// session — entered or morphed).
    private func renameEditorFrame() -> NSRect {
        NSRect(
            x: Self.textX,
            y: PanelDesign.rowPaddingVertical,
            width: Self.textWidth,
            height: geometry.nameHeight)
    }

    private func endRenaming(commit: Bool) {
        guard isRenaming else { return }
        isRenaming = false
        let value = nameEditor.stringValue.trimmingCharacters(in: .whitespaces)
        nameEditor.isHidden = true
        if renameUsesNameLine {
            // Was name+content: the name line returns unchanged (cancel)
            // or shows the committed name (optimistic — the notes push
            // re-renders the row authoritatively right after).
            if commit, !value.isEmpty {
                nameLabel.font = Self.nameFont
                nameLabel.stringValue = value
            }
            nameLabel.isHidden = false
        } else if commit, !value.isEmpty {
            // Content-only → committed: KEEP the session's name+content
            // shape and show the typed name until the push reload lands.
            nameLabel.font = Self.nameFont
            nameLabel.stringValue = value
            nameLabel.isHidden = false
        } else {
            // Content-only → canceled: back to the content-only style.
            exitRenameDeck()
        }
        window?.makeFirstResponder(nil)
        let onEnd = renameEnd
        renameEnd = nil
        onEnd?()
        noteRowHeightChanged()
        if commit, !value.isEmpty {
            renameCommit?(value)
        }
        renameCommit = nil
        renameCancelled = false
    }

    /// A content-only cell has no name slot — switch it to the
    /// name-over-content shape for the session. The captured geometry is
    /// restored on cancel.
    private func enterRenameDeck() {
        renameSavedGeometry = geometry
        let content = previewLabel.stringValue
        geometry = Self.renameGeometry(content: content)
        previewLabel.isHidden = true
        // The detail keeps the note's content color (foreground), not the
        // file-row dim tone.
        detailColor = contentColor
        pathLabel.font = Self.detailFont
        pathLabel.stringValue = content
        pathLabel.lineBreakMode = .byWordWrapping
        pathLabel.cell?.wraps = true
        pathLabel.cell?.truncatesLastVisibleLine = true
        pathLabel.maximumNumberOfLines = 2
        pathLabel.isHidden = false
        needsLayout = true
    }

    private func exitRenameDeck() {
        guard let saved = renameSavedGeometry else { return }
        renameSavedGeometry = nil
        geometry = saved
        pathLabel.isHidden = true
        previewLabel.isHidden = false
        needsLayout = true
    }

    /// The table re-asks heightOfRow for this cell: the session changes
    /// the row height both ways (content-only ⇄ name+content).
    private func noteRowHeightChanged() {
        guard let tableView = enclosingScrollView?.documentView as? NSTableView else {
            return
        }
        let row = tableView.row(for: self)
        if row >= 0 {
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
        }
    }



    func configure(
        item: ClipboardItem, theme: CardTheme,
        thumbnail: NSImage?, sourceIcon: NSImage?
    ) {
        installSubviews()
        resetRenameState()
        resetDecks()
        geometry = Self.geometry(for: item)


        switch item.kind {
        case .text:
            let text = item.previewText ?? ""
            previewLabel.font = Self.previewFont
            contentColor = theme.foreground
            previewLabel.textColor = theme.foreground
            previewLabel.stringValue = text
        case .file:
            let url = URL(fileURLWithPath: item.text ?? "")
            showTwoDeck(
                name: url.lastPathComponent, nameColor: theme.foreground,
                detail: url.deletingLastPathComponent().path,
                detailColor: theme.tertiaryText, wrapsDetail: false)
        case .image:
            if let thumbnail {
                thumbnailView.image = thumbnail
                thumbnailView.isHidden = false
                previewLabel.isHidden = true
                if thumbnail.size.height > 0 {
                    // Box width from the aspect: the bitmap then fills the
                    // 5-line box height exactly instead of letterboxing
                    // inside a square and faking the row's padding.
                    let aspect = thumbnail.size.width / thumbnail.size.height
                    geometry.thumbnailWidth = min(
                        Self.fiveLineBox * aspect, Self.thumbnailMaxWidth)
                }
            } else {
                // Quiet placeholder when the blob is not renderable.
                previewLabel.font = Self.detailFont
                contentColor = theme.tertiaryText
                previewLabel.textColor = theme.tertiaryText
                previewLabel.stringValue = "图片"
                previewLabel.alignment = .center
            }
        }
        iconView.image = sourceIcon
        // Recycled note cells carry a tint — clip rows show full-color
        // app icons and must never inherit it.
        iconView.contentTintColor = nil
        needsLayout = true
    }

    /// Note rows reuse the same skeleton: named notes render name over dim
    func configureNote(
        note: ClipboardNote, theme: CardTheme, sourceIcon: NSImage?,
        iconTint: NSColor = .systemGray
    ) {
        installSubviews()
        resetRenameState()
        resetDecks()

        geometry = Self.geometry(forNote: note)

        let text = ClipboardNotePreview.text(note)
        if note.name.isEmpty {
            // Unnamed note: the content IS the row.
            previewLabel.font = Self.previewFont
            contentColor = theme.foreground
            previewLabel.textColor = theme.foreground
            previewLabel.stringValue = text ?? ""
        } else {
            showTwoDeck(
                name: note.name, nameColor: theme.foreground,
                detail: text ?? "", detailColor: theme.foreground,
                wrapsDetail: true)
        }
        iconView.image = sourceIcon
        iconView.contentTintColor = iconTint
        needsLayout = true
    }
    /// A recycled cell never carries a rename session into its next row.
    private func resetRenameState() {
        isRenaming = false
        renameCancelled = false
        renameCommit = nil
        nameEditor.isHidden = true
    }

    private func resetDecks() {
        nameLabel.isHidden = true
        pathLabel.isHidden = true
        previewLabel.isHidden = false
        previewLabel.alignment = .natural
        thumbnailView.isHidden = true
    }

    /// Two-deck rows (file clips, named notes): name over dim detail.
    private func showTwoDeck(name: String, nameColor: NSColor,
                             detail: String, detailColor: NSColor,
                             wrapsDetail: Bool) {
        previewLabel.isHidden = true
        nameLabel.font = Self.nameFont
        contentColor = nameColor
        nameLabel.textColor = nameColor
        nameLabel.stringValue = name
        nameLabel.isHidden = false
        pathLabel.font = Self.detailFont
        self.detailColor = detailColor
        pathLabel.textColor = detailColor
        pathLabel.stringValue = detail
        pathLabel.isHidden = false
        if wrapsDetail {
            // Note content: word wrap, 2-line cap, TextKit's trailing ….
            pathLabel.lineBreakMode = .byWordWrapping
            pathLabel.cell?.wraps = true
            pathLabel.cell?.truncatesLastVisibleLine = true
            pathLabel.maximumNumberOfLines = 2
        } else {
            // File row: one line, middle-… keeps the extension visible.
            pathLabel.maximumNumberOfLines = 1
            pathLabel.lineBreakMode = .byTruncatingMiddle
            pathLabel.cell?.wraps = false
            pathLabel.cell?.usesSingleLineMode = true
        }
    }

    private func installSubviews() {
        guard !didInstall else { return }
        didInstall = true
        for view in [iconView, thumbnailView, nameLabel, pathLabel, previewLabel, nameEditor] {
            addSubview(view)
        }
        // Draw each image at its own logical size (app icons 24, note
        // glyphs 17), centered — proportional scaling would upscale the
        // smaller glyphs and fatten their strokes.
        iconView.imageScaling = .scaleNone
        iconView.imageAlignment = .alignCenter
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        // Wrapping preview: word wrap + 5-line cap; past the cap TextKit
        // truncates the last visible line with … itself.
        // (ORDER: truncating modes reset cell.wraps — wrap mode first.)
        previewLabel.lineBreakMode = .byWordWrapping
        previewLabel.cell?.wraps = true
        previewLabel.cell?.truncatesLastVisibleLine = true
        previewLabel.maximumNumberOfLines = 5
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.cell?.usesSingleLineMode = true
        nameEditor.delegate = self
        nameEditor.isHidden = true
    }

    // MARK: layout — frames from the same numbers that sized the row

    /// The row's selection fill is the system accent blue; flip the text
    /// white while selected. The guard compares the LABEL'S CURRENT color
    /// against the target — a cached "already flipped" BOOL goes stale the
    /// moment reloadData recycles cells (configure resets label colors),
    /// and then a selected row paints BLACK text on the blue fill. The
    /// rename editor joins the same flip: while editing, it IS the name
    /// line and must follow the row's state like every other label.
    override func draw(_ dirtyRect: NSRect) {
        let selected = enclosingRowIsSelected
        let primary = selected ? NSColor.white : contentColor
        if previewLabel.textColor != primary { previewLabel.textColor = primary }
        if nameLabel.textColor != primary { nameLabel.textColor = primary }
        if nameEditor.textColor != primary { nameEditor.textColor = primary }
        let detail = selected ? NSColor.white.withAlphaComponent(0.85) : detailColor
        if pathLabel.textColor != detail { pathLabel.textColor = detail }
        super.draw(dirtyRect)
    }

    override func layout() {
        super.layout()
        let pad = PanelDesign.rowPaddingVertical
        let iconSize = PanelDesign.rowIconSize
        switch geometry.deck {
        case .text:
            previewLabel.frame = NSRect(
                x: Self.textX, y: pad, width: Self.textWidth, height: geometry.previewHeight)
            iconView.frame = NSRect(
                x: PanelDesign.rowContentLeading,
                y: pad + (geometry.firstLineHeight - iconSize) / 2,
                width: iconSize, height: iconSize)
        case .image:
            let box = Self.fiveLineBox
            thumbnailView.frame = NSRect(x: Self.textX, y: pad, width: geometry.thumbnailWidth, height: box)
            if !previewLabel.isHidden {
                // Placeholder: one dim line centered in the image box.
                previewLabel.frame = NSRect(
                    x: Self.textX, y: pad + (box - geometry.previewHeight) / 2,
                    width: Self.textWidth, height: geometry.previewHeight)
            }
            // Top-aligned like every text row: the icon centers on the
            // first line position, not on the 5-line box.
            iconView.frame = NSRect(
                x: PanelDesign.rowContentLeading,
                y: pad + (geometry.firstLineHeight - iconSize) / 2,
                width: iconSize, height: iconSize)
        case .twoDeck:
            nameLabel.frame = NSRect(
                x: Self.textX, y: pad, width: Self.textWidth, height: geometry.nameHeight)
            pathLabel.frame = NSRect(
                x: Self.textX, y: pad + geometry.nameHeight + 1,
                width: Self.textWidth, height: geometry.detailHeight)
            iconView.frame = NSRect(
                x: PanelDesign.rowContentLeading,
                y: pad + (geometry.nameHeight - iconSize) / 2,
                width: iconSize, height: iconSize)
        }
        // The rename editor rides the line it is editing (frame set at
        // session start; rows never resize mid-session).
        if isRenaming {
            nameEditor.frame = renameEditorFrame()
        }
    }
}

extension ClipCell: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case NSSelectorFromString("insertNewline:"):
            // A Return with an active IME composition CONFIRMS the
            // candidate — it must not commit the rename (the user's next
            // click would then look like a silent name loss).
            if textView.hasMarkedText() {
                return false
            }
            endRenaming(commit: true)
            return true
        case NSSelectorFromString("cancelOperation:"):
            renameCancelled = true
            endRenaming(commit: false)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Any session end other than Esc (panel resign, clicking another
        // row, the move menu) COMMITS — a typed name must never silently
        // vanish. Same semantics as the card's NoteRowCell.
        endRenaming(commit: !renameCancelled)
    }
}

/// Single-line inline rename input — deliberately UNSTYLED. While editing
/// it IS the row's name line: transparent, no border, no box, its color
/// driven by the cell's selection flip in draw() so it matches the row in
/// both selected and unselected states.
final class RenameField: NSTextField {
    init() {
        super.init(frame: .zero)
        font = .systemFont(ofSize: 13, weight: .medium)
        isBordered = false
        isEditable = true
        isSelectable = true
        drawsBackground = false
        backgroundColor = .clear
        focusRingType = .none
        cell?.usesSingleLineMode = true
        cell?.wraps = false
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}

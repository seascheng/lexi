import AppKit

/// Top-down layout container (row 0 = the top edge).
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Section header row (tag name / "Recent").
final class LauncherHeaderCell: NSView {
    private let label = NSTextField(labelWithString: "")
    private var didLayout = false
    override var isFlipped: Bool { true }

    func configure(title: String, color: NSColor) {
        label.stringValue = title.uppercased()
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = color
        if !didLayout {
            didLayout = true
            // Bottom-anchored in the 28pt row: ~12pt above (separation
            // from the previous section), ~6pt below (hugs its own list).
            label.frame = NSRect(x: 16, y: 10, width: 600, height: 14)
            addSubview(label)
        }
    }
}

/// One wrapping grid line of folder chips (single-line Folders layout).
final class LauncherChipLineCell: NSView {
    private var chipViews: [FolderChipView] = []

    func configure(
        chips: [LauncherPanelController.FolderChip],
        theme: CardTheme,
        selectedIndex: Int?,
        onOpen: @escaping (String) -> Void
    ) {
        chipViews.forEach { $0.removeFromSuperview() }
        chipViews.removeAll()
        for (index, chip) in chips.enumerated() {
            let view = FolderChipView(frame: NSRect(x: chip.x + PanelDesign.rowContentLeading, y: 4, width: chip.width, height: 32))
            // Identity travels WITH the view: each chip holds its own
            // path and opens it — no index arithmetic anywhere on the
            // click path (the selected/opened mismatch class dies here).
            view.configure(chip: chip, theme: theme, selected: index == selectedIndex) {
                onOpen(chip.item.path)
            }
            addSubview(view)
            chipViews.append(view)
        }
    }
}


/// A single folder chip: folder glyph + name. Every kind shows a folder
/// glyph (tagged folders tint it with their tag color); clicking opens the
/// folder in Finder, exactly like Enter.
final class FolderChipView: NSView {
    private let glyphView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private var hoverArea: NSTrackingArea?
    private var onOpen: (() -> Void)?
    private var theme: CardTheme = .dark
    private var isSelectedChip = false
    private var didLayout = false

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshHoverTracking(&hoverArea)
        // Enter/exit pairs go STALE when the tracking rect moves under
        // the cursor (the grid scrolls past 12 rows; the Spotlight reload
        // rebuilds cells under the mouse) — an exit never fires and the
        // wash sticks. Re-derive hover from the live cursor on every
        // tracking update instead (same stateless rule as
        // enclosingRowIsSelected).
        applyBackground(hovering: cursorInside())
    }

    override func mouseEntered(with event: NSEvent) {
        applyBackground(hovering: true)
    }

    override func mouseExited(with event: NSEvent) {
        applyBackground(hovering: cursorInside())
    }

    /// The cursor's live position vs this chip's bounds — the single
    /// source of truth for the hover wash.
    private func cursorInside() -> Bool {
        guard let window, !isHidden else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    /// the earlier unconditional `return self` made every chip claim the
    /// entire row: the last-added chip won, so clicking Downloads opened
    /// Pictures.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden || !frame.contains(point) ? nil : self
    }

    override func mouseDown(with event: NSEvent) { onOpen?() }


    func configure(
        chip: LauncherPanelController.FolderChip,
        theme: CardTheme,
        selected: Bool,
        onOpen: @escaping () -> Void
    ) {
        self.theme = theme
        self.isSelectedChip = selected
        self.onOpen = onOpen
        if !didLayout {
            didLayout = true
            wantsLayer = true
            layer?.cornerRadius = PanelDesign.chipCornerRadius

            glyphView.frame = NSRect(x: 9, y: 9, width: 14, height: 14)
            addSubview(glyphView)

            nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
            nameLabel.lineBreakMode = .byTruncatingTail
            nameLabel.cell?.usesSingleLineMode = true
            addSubview(nameLabel)
        }

        nameLabel.stringValue = chip.item.name
        nameLabel.textColor = selected ? .white : theme.foreground
        // Uniform 9pt padding on every side: glyph leading 9, name at
        // 9+14+3, trailing 9 (the chipWidth guard covers the cell insets).
        // The label gets the 13pt font's NATURAL single-line height (~16)
        // vertically centered on the chip — a 14pt cell squeezes the line
        // box and the drawn text rides visibly off the 14pt glyph's
        // center (the reported icon/name misalignment).
        nameLabel.frame = NSRect(
            x: 26, y: 8, width: max(chip.width - 26 - 9, 36), height: 16
        )
        // Glyph color: the quiet gray glyphs flip to white on the blue
        // selection fill (contrast); tag colors stay — legible on blue and
        // they carry the tag identity. Tagged folders wear the FINDER tag
        // color (from the raw xattr slot); tags without a color slot fall
        // back to the deterministic hue.
        let glyphColor: NSColor
        switch chip.kind {
        case .favorite, .recent:
            glyphColor = selected ? .white : theme.secondaryText
        case .tagged:
            glyphColor = finderTagColor(chip.item.tagIndex)
                ?? vividTagColor(for: chip.item.tag, dark: theme.isDark)
        }
        glyphView.image = panelIcon(
            for: chip.kind == .recent ? "clock" : "folder",
            title: chip.item.name,
            color: glyphColor
        )
        applyBackground(hovering: false)
    }

    private func applyBackground(hovering: Bool) {
        wantsLayer = true
        layer?.cornerRadius = 6
        // Selected = the system selection blue with white text; hover is a
        // quiet wash; rest is bare on the glass.
        layer?.backgroundColor = isSelectedChip
            ? NSColor.selectedContentBackgroundColor.cgColor
            : (hovering ? theme.hoverFill.cgColor : NSColor.clear.cgColor)
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
    /// Enter/exit tracking on the row itself (AppKit standard): the wash
    /// clears when the cursor leaves the row OR the window — no external
    /// monitor to go stale.
    var hovering = false
    var insetDx: CGFloat = PanelDesign.rowCapsuleInsetX
    var insetDy: CGFloat = PanelDesign.rowCapsuleInsetY
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshHoverTracking(&hoverArea)
        // Enter/exit pairs go STALE when the tracking rect moves under a
        // stationary cursor (scroll, reload recycling) — re-check the live
        // cursor position, statelessly.
        setHovering(cursorInside())
    }

    override func mouseEntered(with event: NSEvent) {
        setHovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(cursorInside())
    }

    /// The cursor's live position vs this row's bounds.
    private func cursorInside() -> Bool {
        guard window != nil else { return false }
        return bounds.contains(convert(NSEvent.mouseLocation, from: nil))
    }

    private func setHovering(_ value: Bool) {
        if hovering != value {
            hovering = value
            needsDisplay = true
        }
    }

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

/// Search-result row: 24pt icon, title, and the parent path as a quiet
/// second line. Blue system-selection rows flip both lines white
/// (clipboard ClipCell parity).
final class LauncherResultCell: NSView {
    override var isFlipped: Bool { true }
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private var onActivate: (() -> Void)?
    private var didLayout = false
    private var titleColor: NSColor = .white
    private var subtitleColor: NSColor = .white
    private var selectionTextWhite = false

    /// Click must act even while the app is inactive (panel is key).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Bounds-guarded whole-cell target — the title/subtitle labels would
    /// swallow mouseDown otherwise (see FolderChipView.hitTest).
    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden || !frame.contains(point) ? nil : self
    }
    override func mouseDown(with event: NSEvent) { onActivate?() }


    override func draw(_ dirtyRect: NSRect) {
        let selected = enclosingRowIsSelected
        if selected != selectionTextWhite {
            selectionTextWhite = selected
            titleLabel.textColor = selected ? .white : titleColor
            subtitleLabel.textColor = selected ? .white : subtitleColor
        }
        super.draw(dirtyRect)
    }

    func configure(
        item: LauncherPanelController.ResultItem,
        theme: CardTheme,
        _ handler: @escaping () -> Void
    ) {
        onActivate = handler
        if !didLayout {
            didLayout = true
            iconView.frame = NSRect(x: 16, y: 10, width: 24, height: 24)
            addSubview(iconView)
            titleLabel.font = .systemFont(ofSize: 13)
            titleLabel.frame = NSRect(x: 50, y: 7, width: 560, height: 16)
            addSubview(titleLabel)
            subtitleLabel.font = .systemFont(ofSize: 11)
            subtitleLabel.textColor = theme.secondaryText
            // Head truncation keeps the path's distinct tail (…/Utilities).
            subtitleLabel.lineBreakMode = .byTruncatingHead
            subtitleLabel.cell?.usesSingleLineMode = true
            subtitleLabel.frame = NSRect(x: 50, y: 24, width: 560, height: 14)
            addSubview(subtitleLabel)
        }
        switch item.kind {
        case .folder:
            // VS Code semantics: every folder shares one glyph; files
            // carry their type icon.
            iconView.image = panelIcon(for: "folder", title: item.title, color: theme.secondaryText)
        case .file(let url):
            // The file's real type icon (Finder's own — PDF, image, code…),
            // cached like the app icons.
            iconView.image = LauncherAppIndex.shared.icon(forPath: url.path)
        case .app(let app):
            iconView.image = LauncherAppIndex.shared.icon(forPath: app.path)
        }
        titleLabel.stringValue = item.title
        subtitleLabel.stringValue = item.subtitle
        titleColor = theme.foreground
        subtitleColor = theme.secondaryText
        titleLabel.textColor = selectionTextWhite ? .white : titleColor
        subtitleLabel.textColor = selectionTextWhite ? .white : subtitleColor
    }
}

/// Calculator answer row (the leading result): the expression as typed
/// on the left, the answer semibold and right-aligned. Enter (or click)
/// copies the answer and folds the panel.
final class LauncherCalcCell: NSView {
    override var isFlipped: Bool { true }
    private let exprLabel = NSTextField(labelWithString: "")
    private let answerLabel = NSTextField(labelWithString: "")
    private var onActivate: (() -> Void)?
    private var didLayout = false
    private var exprColor: NSColor = .white
    private var answerColor: NSColor = .white
    private var selectionTextWhite = false

    /// Click must act even while the app is inactive (panel is key).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Bounds-guarded whole-cell target (see FolderChipView.hitTest).
    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden || !frame.contains(point) ? nil : self
    }
    override func mouseDown(with event: NSEvent) { onActivate?() }


    override func draw(_ dirtyRect: NSRect) {
        let selected = enclosingRowIsSelected
        if selected != selectionTextWhite {
            selectionTextWhite = selected
            exprLabel.textColor = selected ? .white : exprColor
            answerLabel.textColor = selected ? .white : answerColor
        }
        super.draw(dirtyRect)
    }

    func configure(
        expression: String, value: Double, theme: CardTheme,
        _ handler: @escaping () -> Void
    ) {
        onActivate = handler
        if !didLayout {
            didLayout = true
            exprLabel.font = .systemFont(ofSize: 13)
            exprLabel.lineBreakMode = .byTruncatingTail
            exprLabel.cell?.usesSingleLineMode = true
            exprLabel.frame = NSRect(x: 16, y: 14, width: 300, height: 16)
            addSubview(exprLabel)
            answerLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
            answerLabel.alignment = .right
            answerLabel.frame = NSRect(x: 330, y: 12, width: 294, height: 20)
            addSubview(answerLabel)
        }
        exprLabel.stringValue = expression
        answerLabel.stringValue = "= " + CalcEngine.display(value)
        exprColor = theme.secondaryText
        answerColor = theme.foreground
        exprLabel.textColor = selectionTextWhite ? .white : exprColor
        answerLabel.textColor = selectionTextWhite ? .white : answerColor
    }
}

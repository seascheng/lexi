import AppKit



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

    /// Inset(7) + dot(8) + gap(5) + label + trailing(7) = 27pt overhead,
    /// plus 8pt label slack: the text cell insets its content a few
    /// points, so less than that truncates the last character (the
    /// historic "Clipboar" bug). The ＋ chip is a small 20pt circle.
    override var fittingSize: NSSize {
        NSSize(width: min(label.intrinsicContentSize.width + 35, 127),
               height: PanelDesign.pillHeight)
    }

    /// The stack sizes arranged views from intrinsic content — this IS the
    /// chip's slot, kept in sync whenever the title changes.
    override var intrinsicContentSize: NSSize { fittingSize }

    func configure(title: String, color: NSColor, onActivate: @escaping () -> Void) {
        self.onActivate = onActivate
        chipColor = color
        if !didLayout {
            didLayout = true
            wantsLayer = true
            layer?.cornerRadius = PanelDesign.pillCornerRadius
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 4
            dot.frame = NSRect(x: 7, y: 10, width: 8, height: 8)
            addSubview(dot)

            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.lineBreakMode = .byTruncatingTail
            label.cell?.usesSingleLineMode = true
            addSubview(label)
        }
        dot.isHidden = false
        label.stringValue = title
        invalidateIntrinsicContentSize() // the stack reflows to the new width
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

    /// Right-click menu for this chip (tab management); nil would fall
    /// through to the system menu — always return something.
    var onMenu: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        onMenu?() ?? NSMenu()
    }

    override func layout() {
        super.layout()
        // Everything centers within the pill's real height — fixed offsets
        // went stale when the pill height token changed (28pt).
        // Dot(8, round) + 5pt gap + label, tight trailing slack.
        label.frame = NSRect(x: 20, y: (bounds.height - 16) / 2, width: bounds.width - 27, height: 16)
        dot.frame = NSRect(x: 7, y: (bounds.height - 8) / 2, width: 8, height: 8)
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

    /// Chip drags reorder tabs — the window must never follow the same
    /// gesture (isMovableByWindowBackground would otherwise drag the
    /// panel under every chip drag).
    override var mouseDownCanMoveWindow: Bool { false }

    private func applyBackground() {
        wantsLayer = true
        layer?.cornerRadius = PanelDesign.pillCornerRadius
        // Fill only: unselected tabs are bare dot + label on the glass (no
        // capsule border); hover and selection wash over with their fills.
        layer?.backgroundColor = selected
            ? theme.selectedFill.cgColor
            : (hovering ? theme.hoverFill.cgColor : NSColor.clear.cgColor)
        layer?.borderWidth = 0
        dot.layer?.backgroundColor = chipColor.cgColor
    }
}

/// The ＋ at the end of the chip row: an icon-only button — AppKit centers
/// a button's image natively; the disc is the layer (radius = half height).
final class AddTagButton: NSButton {
    private var hoverArea: NSTrackingArea?
    private var hovering = false
    private var theme: CardTheme = .dark
    init() {
        super.init(frame: .zero)
        let symbol = NSImage(systemSymbolName: "plus", accessibilityDescription: "新分类")
            ?? NSImage()
        let icon = symbol.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        image = icon ?? symbol
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        isBordered = false
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 20, height: 20)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    /// Chip drags reorder tabs — the window must never follow the same
    /// gesture.
    override var mouseDownCanMoveWindow: Bool { false }

    func applyTheme(_ theme: CardTheme) {
        self.theme = theme
        contentTintColor = theme.foreground
        paint()
    }

    private func paint() {
        // A faint disc at rest so it reads as a button, hover deepens it.
        let rest = theme.isDark
            ? NSColor.white.withAlphaComponent(0.10)
            : NSColor.black.withAlphaComponent(0.08)
        layer?.backgroundColor = (hovering ? theme.hoverFill : rest).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshHoverTracking(&hoverArea)
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        paint()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        paint()
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

    /// The stack sizes arranged views from intrinsic content.
    override var intrinsicContentSize: NSSize { fittingSize }

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

            // Auto Layout with BASELINE alignment: the ＋ glyph and the
            // field's typed text share one baseline — centerY pinning
            // centers the views' frames, which drifts for real text.
            plus.font = .systemFont(ofSize: 14, weight: .medium)
            plus.translatesAutoresizingMaskIntoConstraints = false
            addSubview(plus)

            field.font = .systemFont(ofSize: 13)
            field.isBordered = false
            field.isEditable = true
            field.isSelectable = true
            field.drawsBackground = false
            field.focusRingType = .none
            field.placeholderString = "新分类"
            field.delegate = delegate
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)

            NSLayoutConstraint.activate([
                plus.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
                plus.firstBaselineAnchor.constraint(
                    equalTo: field.firstBaselineAnchor),
                field.leadingAnchor.constraint(equalTo: plus.trailingAnchor, constant: 5),
                field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                // The field pins the pill's vertical middle; the ＋ rides
                // the shared baseline.
                field.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
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

/// The chips stack: gaps between tabs are not window-drag surface — the
/// tab row is for tabs, panel dragging stays on the panel body.
final class ChipsStackView: NSStackView {
    override var mouseDownCanMoveWindow: Bool { false }
}

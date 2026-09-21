import AppKit

/// GEOMETRY tokens for the native panels (LauncherPanel, ClipboardPanel):
/// widths, insets, pill/row metrics. Surface APPEARANCE (material, scrim,
/// border, corner-radius role) lives in PanelStyle — the two namespaces
/// never overlap.
///
/// One source of truth per concern — panels never hand-pick spacing
/// numbers again. Values are in points; every panel renders at the same
/// width so the metrics transfer exactly.
enum PanelDesign {
    // MARK: panel chrome

    static let panelWidth: CGFloat = 520
    /// Panel-level horizontal margin: search field, filter/tab pill row,
    /// footer text — one shared left line down every panel.
    static let sideInset: CGFloat = 12
    static let searchHeight: CGFloat = 38

    // MARK: pills (filters/tabs) vs chips (inline content)

    static let pillHeight: CGFloat = 28
    /// Filter/tab pills read as capsules at their full height.
    static let pillCornerRadius: CGFloat = 14
    /// Inline content chips (folder grid) stay squarer.
    static let chipCornerRadius: CGFloat = 7

    // MARK: row selection capsule

    static let rowCapsuleInsetX: CGFloat = 6
    static let rowCapsuleInsetY: CGFloat = 3

    // MARK: row content geometry
    //
    // icon pinned to rowContentLeading; text starts after rowIconToText;
    // text trailing never passes rowContentTrailing. Inside the capsule
    // (inset rowCapsuleInsetX) the content is padded symmetrically:
    //   (rowContentLeading - rowCapsuleInsetX) == rowIconToText
    //   == (rowContentTrailing - rowCapsuleInsetX)
    // → 10pt everywhere horizontally; rowPaddingVertical is the single
    // top/bottom pad EVERY row kind uses, so a cell's padding is uniform.
    // Type scale: row primary 13, secondary 12, search field 16, footer 12.

    static let rowContentLeading: CGFloat = 16
    static let rowContentTrailing: CGFloat = 16
    static let rowIconSize: CGFloat = 24
    static let rowIconToText: CGFloat = 10
    /// The one vertical pad for row content — same value on every row kind
    /// and on both the top and the bottom edge.
    static let rowPaddingVertical: CGFloat = 10
}

// MARK: - Shared view helpers (every panel)

extension NSView {
    /// The app's standard hover tracking: full bounds, enter+exit, always
    /// active, inVisibleRect. Call from `updateTrackingAreas()` and pass
    /// the stored area — the previous one is removed first. Sites override
    /// only mouseEntered/mouseExited (the visual wash).
    func refreshHoverTracking(_ stored: inout NSTrackingArea?) {
        if let stored { removeTrackingArea(stored) }
        stored = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        if let stored { addTrackingArea(stored) }
    }

    /// Renders the view to PNG data via own-window caching (no screen
    /// recording permission). Shared by the /debug-* snapshot routes.
    func snapshotPNG() -> Data? {
        let rect = bounds
        guard let rep = bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        cacheDisplay(in: rect, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}

extension String {
    /// Preview text form: every whitespace run collapses to one space.
    var whitespaceCollapsed: String {
        replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}

extension NSView {
    /// True when the enclosing table row is selected. Read statelessly in
    /// draw(_:) so cell reuse, reloads and click/keyboard selection all
    /// stay in sync.
    var enclosingRowIsSelected: Bool {
        (superview as? NSTableRowView)?.isSelected == true
    }
}

/// Centered 13pt empty-state label, hidden until a surface fills it.
/// Every panel's "no content" row shares these metrics.
func makePanelEmptyLabel() -> NSTextField {
    let label = NSTextField(labelWithString: "")
    label.font = .systemFont(ofSize: 13)
    label.alignment = .center
    label.isHidden = true
    return label
}

// MARK: - Shared search strip (every panel)

/// Transparent search strip: leading magnifier + borderless input. The
/// system NSSearchField always paints its capsule on macOS 26 — this owns
/// every pixel: clear background on the glass, a real gap between the
/// icon and the text area, and the panel's own type scale.
final class PanelSearchField: NSView {
    let field = NSTextField()
    private let icon = NSImageView()

    /// NSTextField only draws its placeholder while NOT editing — the
    /// panel always opens with the field focused, so the hint owns its
    /// own label and shows whenever the input is empty.
    private let placeholderLabel = NSTextField(labelWithString: "")

    /// The hint text (panels localize their own).
    var placeholder: String {
        get { placeholderLabel.stringValue }
        set { placeholderLabel.stringValue = newValue }
    }
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        icon.image = NSImage(
            systemSymbolName: "magnifyingglass", accessibilityDescription: "search"
        )?.withSymbolConfiguration(config)
        icon.imageScaling = .scaleNone
        icon.contentTintColor = .systemGray
        addSubview(icon)
        field.font = .systemFont(ofSize: 15)  // one step under the 16pt chrome scale
        field.isBordered = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.cell?.usesSingleLineMode = true
        addSubview(field)

        placeholderLabel.font = .systemFont(ofSize: 15)
        addSubview(placeholderLabel)
        NotificationCenter.default.addObserver(
            forName: NSControl.textDidChangeNotification, object: field, queue: .main
        ) { [weak self] _ in
            self?.updatePlaceholder()
        }
        // IME composition (pinyin typed but not yet committed) lives in
        // the field editor and never touches stringValue — the editor's
        // own didChange is what fires while composing.
        NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, (note.object as AnyObject) === self.field.currentEditor() else { return }
            self.updatePlaceholder()
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var stringValue: String {
        get { field.stringValue }
        set {
            field.stringValue = newValue
            updatePlaceholder()
        }
    }

    func applyTheme(_ theme: CardTheme) {

        icon.contentTintColor = theme.tertiaryText
        field.textColor = theme.foreground
        placeholderLabel.textColor = theme.tertiaryText
    }

    override func layout() {
        super.layout()
        // The strip blends into the panel material — no capsule, no
        // background of its own; the icon keeps its tight chrome inset.
        let iconSide: CGFloat = 15
        icon.frame = NSRect(x: 2, y: (bounds.height - iconSide) / 2, width: iconSide, height: iconSide)
        // Breathing room between the magnifier and the text area.
        let textX = icon.frame.maxX + 8
        field.frame = NSRect(
            x: textX, y: (bounds.height - 20) / 2,
            width: max(0, bounds.width - textX - 4), height: 20)
        placeholderLabel.frame = field.frame
    }

    private func updatePlaceholder() {
        // The live editor text during editing (IME composition included),
        // else the committed value.
        placeholderLabel.isHidden = !(field.currentEditor()?.string ?? field.stringValue).isEmpty
    }

    /// Clicking anywhere on the strip focuses the input.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(field)
    }
}

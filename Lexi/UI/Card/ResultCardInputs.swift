import AppKit

// ---------------------------------------------------------------------------
// Result card input surfaces: the run-tab chip view, the multi-line input
// text view, and the single-line input field.
// ---------------------------------------------------------------------------

/// A run chip in the tabs strip: icon + title + inline dismiss (×),
/// whole-chip click selects the run.
final class RunChipView: NSView {
    var onSelected: (() -> Void)?
    var onDismissed: (() -> Void)?
    let fitWidth: CGFloat
    private let iconView: NSImageView
    private let titleLabel: NSTextField
    private let dismissButton: NSButton
    private var statusDot: NSView!
    var runId = ""
    var statusKey: CardRun.Status = .loading
    var isActiveChip = false

    init(run: CardRun, dark: Bool) {
        runId = run.id
        statusKey = run.status
        let icon = panelIcon(for: run.icon, title: run.title) ?? NSImage()
        let title = run.title
        // Metrics: edgeInset/dot/icon/dismiss are the frame constants
        // below; the two small gaps (5, 4) and titleWidth's built-in 8pt
        // slack reproduce the shipped chip width exactly — the frame x
        // values sit 1pt inside this sum by long-standing behavior.
        let edgeInset: CGFloat = 8, dotWidth: CGFloat = 4
        let iconSize: CGFloat = 13, dismissWidth: CGFloat = 14
        let titleWidth = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width + 8
        fitWidth = edgeInset + dotWidth + 5 + iconSize + 4 + titleWidth + edgeInset + dismissWidth
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
        isActiveChip = active
        layer?.backgroundColor = active
            ? (dark ? NSColor.white.withAlphaComponent(0.14).cgColor : NSColor.black.withAlphaComponent(0.08).cgColor)
            : NSColor.clear.cgColor
        let color: NSColor = active ? .labelColor : .secondaryLabelColor
        titleLabel.textColor = color
        iconView.contentTintColor = color
        statusDot.layer?.backgroundColor = Self.dotColor(for: statusKey).cgColor
    }

    private static func dotColor(for status: CardRun.Status) -> NSColor {
        switch status {
        case .error: return .systemRed.withAlphaComponent(0.85)
        case .ready: return .controlAccentColor.withAlphaComponent(0.65)
        case .loading, .streaming: return .secondaryLabelColor.withAlphaComponent(0.55)
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

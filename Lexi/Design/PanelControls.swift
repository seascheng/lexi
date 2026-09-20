import AppKit
import Foundation

final class ToolbarButton: NSButton {
    var theme: ToolbarTheme = .dark {
        didSet {
            contentTintColor = theme.iconColor
            updateBackground()
            needsDisplay = true
        }
    }
    var trackingAreaRef: NSTrackingArea?
    var isPressed = false {
        didSet {
            updateBackground()
        }
    }
    var isHovering = false {
        didSet {
            updateBackground()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func setup() {
        wantsLayer = true
        // Small-radius highlight: the inset capsule gets a quiet 6pt corner.
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
    }

    func updateBackground() {
        let color: NSColor
        if isPressed {
            color = theme.pressedColor
        } else if isHovering {
            color = theme.hoverColor
        } else {
            color = .clear
        }
        layer?.backgroundColor = color.cgColor
    }

    override func updateTrackingAreas() {
        refreshHoverTracking(&trackingAreaRef)
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        isPressed = false
    }

    // Cursor rects alone own the pointing-hand cursor (the old
    // mouseEntered NSCursor.set() fought them).
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        super.mouseDown(with: event)
        isPressed = false
    }

    override var acceptsFirstResponder: Bool {
        false
    }
}

final class ToolbarDragHandle: NSView {
    var theme: ToolbarTheme = .dark {
        didSet {
            needsDisplay = true
        }
    }
    var onMouseDown: ((NSEvent) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        toolTip = "Move toolbar"
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        toolTip = "Move toolbar"
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let color = theme.iconColor.withAlphaComponent(theme == .dark ? 0.55 : 0.42)
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.25
        path.lineCapStyle = .round
        let top = bounds.midY + 4
        let bottom = bounds.midY - 4
        for x in [bounds.midX - 2, bounds.midX + 2] {
            path.move(to: NSPoint(x: x, y: bottom))
            path.line(to: NSPoint(x: x, y: top))
        }
        path.stroke()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        NSCursor.closedHand.set()
        onMouseDown?(event)
        NSCursor.openHand.set()
    }


/// nonactivatingPanel defaults to canBecomeKey == false, which would leave
/// the input text view unable to ever take keyboard focus. Allow key status:
/// becoming key does NOT activate the app, so the source app keeps its focus
/// while the card accepts typing.
}
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Panels embed their own key-equivalent routing (e.g. the clipboard
    /// panel's ⌘P pin toggle, which the search field's command path never
    /// sees). Return true from the handler to consume the event.
    var keyEquivalentHandler: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let keyEquivalentHandler, keyEquivalentHandler(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
}


/// Borderless icon button with hover/press feedback (system-feel chrome):
/// subtle fill on hover, stronger on press, corner radius to match chips.
final class HoverIconButton: NSButton {
    var hoverArea: NSTrackingArea?
    var baseAlpha: CGFloat = 0.10
    var pressAlpha: CGFloat = 0.16

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshHoverTracking(&hoverArea)
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(baseAlpha).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(pressAlpha).cgColor
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(isMousePoint(event.locationInWindow, in: frame) ? baseAlpha : 0).cgColor
        super.mouseUp(with: event)
    }
}

/// NSScrollView that only scrolls horizontally. Vertical wheel deltas are
/// forwarded to another scroll view (the markdown content) — the strips are
/// one line high, so the default vertical rubber-band made the buttons
/// "scroll up and down" in place.
final class HorizontalOnlyClip: NSScrollView {
    weak var verticalForward: NSScrollView?
    /// Notes list: vertical deltas must reach THIS scroll view's table
    /// (native scrolling) instead of being dropped like the one-line strips.
    var allowsVertical = false

    override var mouseDownCanMoveWindow: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            if allowsVertical {
                super.scrollWheel(with: event)
                return
            }
            if let forward = verticalForward {
                forward.scrollWheel(with: event)
            }
            return // never bounce vertically
        }
        // No horizontal overflow: swallow the gesture entirely — a
        // rubber-banding one-line strip displaces the very buttons the
        // user is trying to click.
        let docW = documentView?.frame.width ?? 0
        if docW <= bounds.width + 1.5 { return }
        super.scrollWheel(with: event)
    }
}

/// Resize surfaces for the borderless card: bottom-right corner, right edge,
/// bottom edge. Dragging anchors the opposite edge (standard window resize
/// semantics) and each zone shows the matching system cursor.
final class CardResizeZone: NSView {
    enum Edge { case corner, right, bottom }
    let edge: Edge
    /// (width, height) deltas — nil means "this zone doesn't change it".
    var onResize: ((_ width: CGFloat?, _ height: CGFloat?) -> Void)?
    var onReset: (() -> Void)?
    var startMouse = NSPoint.zero
    var startSize = NSSize(width: 420, height: 240)
    var isDark = false
    private static let diagonalCursor: NSCursor = {
        if let image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right",
                               accessibilityDescription: "Resize") {
            let configured = image.withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) ?? image
            return NSCursor(image: configured, hotSpot: NSPoint(x: 8, y: 8))
        }
        return .crosshair
    }()

    init(edge: Edge, frame: NSRect) {
        self.edge = edge
        super.init(frame: frame)
        wantsLayer = true
    }

    /// Without this the window's movable-background drag runs IN PARALLEL with
    /// our per-frame resize setFrame: each frame the drag moves the window,
    /// setFrame pulls it back, and the async windowDidMove then bakes the
    /// mangled origin into the anchors — the reported "whole window drifts".
    override var mouseDownCanMoveWindow: Bool { false }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func draw(_ dirtyRect: NSRect) {
        guard edge == .corner else { return }
        let color = (isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.28)
        color.setStroke()
        for i in 0..<3 {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: bounds.width - 3.5 - CGFloat(i) * 4, y: 2.5))
            path.line(to: NSPoint(x: bounds.width - 2.5, y: 3.5 + CGFloat(i) * 4))
            path.lineWidth = 1.2
            path.lineCapStyle = .round
            path.stroke()
        }
    }

    var cursor: NSCursor {
        switch edge {
        case .corner: return Self.diagonalCursor
        case .right: return .resizeLeftRight
        case .bottom: return .resizeUpDown
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    func setDark(_ dark: Bool) {
        isDark = dark
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onReset?()
            return
        }
        startMouse = NSEvent.mouseLocation
        startSize = window?.frame.size ?? NSSize(width: 420, height: 240)
        cursor.set()
    }

    override func mouseDragged(with event: NSEvent) {
        let cur = NSEvent.mouseLocation
        let dx = cur.x - startMouse.x
        let dy = startMouse.y - cur.y // drag down grows (AppKit y-up)
        switch edge {
        case .corner: onResize?(startSize.width + dx, startSize.height + dy)
        case .right: onResize?(startSize.width + dx, nil)
        case .bottom: onResize?(nil, startSize.height + dy)
        }
    }
}

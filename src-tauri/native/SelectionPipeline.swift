import AppKit
import CoreGraphics

// ---------------------------------------------------------------------------
// Selection pipeline, Layer 1 (dual-track with Rust).
//
// A LISTEN-ONLY session tap observes mouse up; after a click (not a drag),
// outside excluded apps, it reads kAXSelectedText from the focused element
// and shows the toolbar in-process. Rust keeps its full pipeline (AX →
// web-area → menu-copy → Cmd+C) — during the overlap both sides fire for
// native apps; showPanel dedupes identical text within 600ms, so the user
// sees exactly one toolbar. If this layer fails, Rust still covers it.
//
// Layer 2 (later): web-area DFS + menu-copy + Cmd+C fallbacks; then the
// Rust tap retires.
// ---------------------------------------------------------------------------

final class SelectionPipeline {
    private var tap: CFMachPort?
    private var downLocation: CGPoint?
    private var excludedApps: [String] = ["com.apple.finder"]
    private var enabled = true

    /// Set by the app controller — presents the toolbar on the main thread.
    var onSelection: ((String, CGPoint) -> Void)?

    /// Frames of the helper's own surfaces — clicks inside them never count
    /// as selections (the Rust side checks PIDs; frame checks are equivalent
    /// for our four known panels).
    var ownFrames: () -> [NSRect] = { [] }

    func start() {
        reload()
        pasteboardBaseline = NSPasteboard.general.changeCount
        installTap()
    }

    func reload() {
        enabled = LexiStore.settingBool("toolbarEnabled", default: true)
        excludedApps = LexiStore.excludedToolbarApps()
    }
    /// The user pressed plain Cmd+C (ShortcutMonitor hook). After the app
    /// processes the shortcut, a changeCount bump means real copied text —
    /// record it with 5s freshness (Rust handle_copy_for_toolbar parity).
    private var pasteboardBaseline: Int = 0
    private var lastCopied: (text: String, at: Date)?

    func noteCopyCommand() {
        workQueue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            let count = NSPasteboard.general.changeCount
            guard count > self.pasteboardBaseline else {
                FileLog.write("SEL1 copy: changeCount not bumped, skipping")
                return
            }
            self.pasteboardBaseline = count
            guard let text = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty
            else {
                FileLog.write("SEL1 copy: pasteboard had no text")
                return
            }
            self.lastCopied = (text, Date())
            FileLog.write("SEL1 copy: recorded len=\(text.count)")
        }
    }
    private let workQueue = DispatchQueue(label: "lexi.selection.ax", qos: .userInitiated)

    private func installTap() {
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            // Same recovery rule as ShortcutMonitor: fromOpaque + take
            // unretained — `.pointee` on the instance's own address reads
            // the object header as a reference (crash).
            guard let userInfo else { return Unmanaged.passRetained(event) }
            let pipeline = Unmanaged<SelectionPipeline>.fromOpaque(userInfo).takeUnretainedValue()
            if type == .tapDisabledByTimeout {
                // A slow callback (AX before the worker hand-off existed)
                // killed taps; re-arm keeps the pipeline alive.
                DispatchQueue.main.async {
                    CGEvent.tapEnable(tap: pipeline.tap!, enable: true)
                }
                return Unmanaged.passRetained(event)
            }
            pipeline.observe(type: type, event: event)
            return Unmanaged.passRetained(event) // never consume clicks
        }
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        guard let machPort = CGEvent.tapCreate(
            tap: CGEventTapLocation(rawValue: 1) ?? .cghidEventTap, // kCGSessionEventTap
            place: .headInsertEventTap,
            options: .listenOnly, // passive: clicks always pass through
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            FileLog.write("SELECTION tap create failed — Rust pipeline remains sole trigger")
            return
        }
        tap = machPort
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, machPort, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: machPort, enable: true)
        FileLog.write("SELECTION tap installed (Layer 1: AX direct read, dual-track)")
    }

    private func observe(type: CGEventType, event: CGEvent) {
        switch type {
        case .leftMouseDown:
            downLocation = event.location
        case .leftMouseUp:
            // Never read AX inside the tap callback: remote apps can take
            // the full messaging timeout, which both freezes this run loop
            // and gets the tap killed by the system. Hand off to a worker.
            let up = event.location
            workQueue.async { [weak self] in
                self?.handleMouseUp(up: up)
            }
        default:
            break
        }
    }

    private func handleMouseUp(up upLocation: CGPoint) {
        guard enabled else { return }
        // Drag detection: a moved mouse is a drag/scroll gesture, not a
        // selection click. (Layer-1 rule: click selections only; Rust's
        // richer drag logic migrates in Layer 2.)
        if let down = downLocation {
            let dx = upLocation.x - down.x, dy = upLocation.y - down.y
            if dx * dx + dy * dy >= 64 {
                FileLog.write("SEL1 skip: drag dx=\(Int(dx)) dy=\(Int(dy))")
                return
            }
        }

        // Cocoa coords (bottom-left origin) for panel placement.
        let maxY = NSScreen.screens.map(\.frame.maxY).max() ?? upLocation.y
        let cocoa = NSPoint(x: upLocation.x, y: maxY - upLocation.y)
        for frame in ownFrames() where frame.contains(cocoa) {
            FileLog.write("SEL1 skip: own frame at \(Int(cocoa.x)),\(Int(cocoa.y))")
            return
        }

        // Excluded apps (bundle ids, e.g. Finder).
        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
        if excludedApps.contains(frontBundle) {
            FileLog.write("SEL1 skip: excluded app \(frontBundle)")
            return
        }

        // Full AX chain (direct → range slice → web-area markers).
        let axText = Self.readSelectedText()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var text = axText
        var source = "ax"
        if text.isEmpty, let copied = lastCopied,
           Date().timeIntervalSince(copied.at) < 5 {
            // Browser flow: AX can't read web selections — the explicit
            // Cmd+C (recorded by noteCopyCommand) is the text source.
            text = copied.text
            source = "copied"
        }
        guard !text.isEmpty else {
            FileLog.write("SEL1 skip: no AX text (front=\(frontBundle))")
            return
        }

        // The screen containing the cursor converts CG (top-left) to Cocoa
        // (bottom-left) coordinates for the panel placement path.
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cocoa) }) else { return }
        let cocoaPoint = NSPoint(x: upLocation.x, y: screen.frame.maxY - upLocation.y)
        FileLog.write("SEL1 fire: len=\(text.count) front=\(frontBundle) via=\(source)")
        DispatchQueue.main.async { [weak self] in
            self?.onSelection?(text, cocoaPoint)
        }
    }

    /// The full read chain: focused AX text → AXValue+range slice → web-area
    /// markers. (The copied fallback lives in handleMouseUp.) Ported from
    /// read_selected_text_via_ax / _ax_range / _web_area.
    static func readSelectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let raw = focusedRef else { return nil }
        // The AX API guarantees the CF type on success; the compiler rejects
        // both `as?` (always-succeeds) and `as` (not convertible) for CF
        // class references — bit-cast is the canonical bridge.
        let focused = unsafeBitCast(raw, to: AXUIElement.self)

        // Self-selection guard: our own editors (rename select-all etc.)
        // are UI, not a user selection in a source app.
        var pid: Int32 = 0
        AXUIElementGetPid(focused, &pid)
        if pid == ProcessInfo.processInfo.processIdentifier {
            return nil
        }
        AXUIElementSetMessagingTimeout(focused, 0.3)

        // Tier 1: direct attribute.
        if let text = axStringAttribute(focused, kAXSelectedTextAttribute as CFString),
           !text.isEmpty {
            return text
        }

        // Tier 2: AXValue sliced by AXSelectedTextRange — terminals expose
        // no AXSelectedText but do expose value + range.
        if let text = readSelectedTextViaAxRange(focused) {
            return text
        }

        // Tier 3: web-area text markers (Chrome/Safari/Edge/Arc/Electron).
        if let text = readSelectedTextViaWebArea() {
            return text
        }
        return nil
    }

    private static func axStringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let string = value as? String else { return nil }
        return string
    }

    /// AXValue + AXSelectedTextRange slice. The range is UTF-16 based —
    /// NSString slicing is exact here (byte slicing would tear multibyte).
    private static func readSelectedTextViaAxRange(_ element: AXUIElement) -> String? {
        guard let full = axStringAttribute(element, kAXValueAttribute as CFString) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &value
        ) == .success, let raw = value else { return nil }
        let axValue = unsafeBitCast(raw, to: AXValue.self)

        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range), range.length > 0 else { return nil }
        if range.location == kCFNotFound { range.location = 0 }
        let text = full as NSString
        let nsRange = NSRange(location: range.location, length: range.length)
        guard nsRange.location < text.length,
              NSMaxRange(nsRange) <= text.length else { return nil }
        return text.substring(with: nsRange)
    }

    /// Web selection via text markers: the focused element's (or the web
    /// area's) AXSelectedTextMarkerRange resolved through the parameterized
    /// AXStringForTextMarkerRange — no Cmd+C, no clipboard.
    private static func readSelectedTextViaWebArea() -> String? {
        let system = AXUIElementCreateSystemWide()
        var appRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedApplicationAttribute as CFString, &appRef
        ) == .success, let raw = appRef else { return nil }
        let app = unsafeBitCast(raw, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(app, 0.5)

        // The focused element comes from the application — the system-wide
        // focused element is a classic stale-read source.
        guard let focused = axCopyElementAttribute(app, kAXFocusedUIElementAttribute as CFString),
              let webArea = findWebAreaAncestor(focused)
                  ?? findWebAreaInFocusedWindow(app)
        else { return nil }

        // Retry briefly: the renderer can lag the selection gesture.
        for attempt in 0..<3 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.05) }
            guard let markerRange = copyMarkerRange(focused) ?? copyMarkerRange(webArea) else { continue }
            var out: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(
                webArea, "AXStringForTextMarkerRange" as CFString, markerRange, &out
            ) == .success, let text = out as? String,
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            return text
        }
        return nil
    }

    private static func axCopyElementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let raw = value else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }

    /// Bounded ancestor walk hunting the AXWebArea (WebKit + Chromium both
    /// render web content under that role).
    private static func findWebAreaAncestor(_ element: AXUIElement) -> AXUIElement? {
        var current = element
        for _ in 0..<25 {
            guard let parent = axCopyElementAttribute(current, kAXParentAttribute as CFString) else { break }
            current = parent
            if axStringAttribute(current, kAXRoleAttribute as CFString) == "AXWebArea" {
                return current
            }
        }
        return nil
    }

    /// Focused window's first AXWebArea descendant, depth-first and bounded
    /// (selecting static page text can leave focus at the window level).
    private static func findWebAreaInFocusedWindow(_ app: AXUIElement) -> AXUIElement? {
        guard let window = axCopyElementAttribute(app, kAXFocusedWindowAttribute as CFString) else { return nil }
        return findWebAreaDescendant(window, depth: 6)
    }

    private static func findWebAreaDescendant(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth > 0 else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return nil }
        for child in children {
            if axStringAttribute(child, kAXRoleAttribute as CFString) == "AXWebArea" {
                return child
            }
            if let deeper = findWebAreaDescendant(child, depth: depth - 1) {
                return deeper
            }
        }
        return nil
    }

    private static func copyMarkerRange(_ element: AXUIElement) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, "AXSelectedTextMarkerRange" as CFString, &value
        ) == .success, let raw = value else { return nil }
        return unsafeBitCast(raw, to: AXValue.self)
    }
}

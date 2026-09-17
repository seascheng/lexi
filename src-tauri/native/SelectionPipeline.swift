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
        installTap()
    }

    func reload() {
        enabled = LexiStore.settingBool("toolbarEnabled", default: true)
        excludedApps = LexiStore.excludedToolbarApps()
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

        let text = Self.readSelectedText()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            FileLog.write("SEL1 skip: no AX text (front=\(frontBundle))")
            return
        }

        // The screen containing the cursor converts CG (top-left) to Cocoa
        // (bottom-left) coordinates for the panel placement path.
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cocoa) }) else { return }
        let cocoaPoint = NSPoint(x: upLocation.x, y: screen.frame.maxY - upLocation.y)
        FileLog.write("SEL1 fire: len=\(text.count) front=\(frontBundle)")
        DispatchQueue.main.async { [weak self] in
            self?.onSelection?(text, cocoaPoint)
        }
    }

    /// Tier-1 read: kAXSelectedText on the focused element of the focused
    /// app (native macOS apps only — web areas and menu-copy are Layer 2 /
    /// Rust's job during dual-track).
    static func readSelectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success, let element = focused else { return nil }

        // Remote apps get a short leash: the default 6s timeout would stall
        // the worker queue on a hung app.
        AXUIElementSetMessagingTimeout(element as! AXUIElement, 0.3)

        // Core Foundation objects are auto-managed in Swift — no CFRelease.
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element as! AXUIElement, kAXSelectedTextAttribute as CFString, &value
        ) == .success, let text = value as? String else { return nil }
        return text
    }
}

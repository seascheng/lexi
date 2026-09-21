import AppKit
import CoreGraphics

// ---------------------------------------------------------------------------
// Selection pipeline — the selection toolbar's trigger layer.
//
// A LISTEN-ONLY session tap observes mouse up; after a click, outside
// excluded apps, it reads the selection from the focused element (direct
// kAXSelectedText → AXValue+range slice → web-area markers) and shows the
// toolbar in-process. Clicks always pass through. Browsers defeat AX
// selection reads, so an explicit Cmd+C within 5s (recorded via
// ShortcutMonitor's hook) feeds the text instead.
// ---------------------------------------------------------------------------

final class SelectionPipeline {
    private var tap: CFMachPort?
    private var excludedApps: [String] = ["com.apple.finder"]
    private var enabled = true
    /// Last mouse-down point (CG coords) — the gesture gate measures the
    /// drag against it. Main-thread only (the tap runs on the main
    /// runloop).
    private var lastDown: CGPoint?

    /// Set by the app controller — presents the toolbar on the main thread.
    var onSelection: ((String, CGPoint) -> Void)?

    /// Frames of the helper's own surfaces — clicks inside them never count
    /// as selections. Evaluated on the main thread only (observe snapshots
    /// it before the AX work queue).
    var ownFrames: () -> [NSRect] = { [] }

    // MARK: gesture qualification (openclip MacSelectionMonitor parity)

    /// A mouse-up only counts as a selection gesture when it was a drag
    /// (moved > 3 pt from the press) or a multi-click (double/triple word
    /// select). Without this gate every plain click re-reads the app's
    /// RETAINED old selection and pops the bar out of nowhere — and the
    /// second press of a double-click killed the bar the first press had
    /// just shown (the 600 ms dedup gate then blocked the re-show).
    static func isDragOrMultiClick(down: CGPoint?, up: CGPoint, clickCount: Int) -> Bool {
        if clickCount >= 2 { return true }
        guard let down else { return true } // no press seen: assume a drag
        let dx = up.x - down.x, dy = up.y - down.y
        return dx * dx + dy * dy > 9.0
    }

    /// Key gestures that mean "a selection just happened": ⌘A / ⌘L select a
    /// whole container; Shift + arrows/Home/End/Page keys extend one. The
    /// whole-container gestures require the exact command set; extend
    /// gestures fire for shift with optional option/command — plain typing
    /// and unrelated shortcuts never match. Device bits (function/
    /// numericPad/help) and capsLock are stripped first: Home/End/Page
    /// carry .function, capsLock rides along while engaged.
    static func isSelectionKeyGesture(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        let gesture = flags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad, .help])
        // contains+disjoint instead of exact equality: synthesized and
        // session-delivered events carry stray high bits (observed
        // 0x20000000 riding along) that break == and isSubset checks.
        if gesture.contains(.command), gesture.isDisjoint(with: [.shift, .option, .control]) {
            return keyCode == 0x00 || keyCode == 0x25 // kVK_ANSI_A / kVK_ANSI_L
        }
        if gesture.contains(.shift), gesture.isDisjoint(with: [.control]) {
            return [0x7B, 0x7C, 0x7D, 0x7E,  // left/right/down/up
                    0x73, 0x77,              // home/end
                    0x74, 0x79].contains(keyCode) // page up/down
        }
        return false
    }
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
        // NSPasteboard is main-thread-only (Apple docs). The delay + read
        // both hop to main; the work queue exists solely to keep the tap
        // callback itself from blocking.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
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

            // The copy IS the browser flow's trigger: apps whose AX reads
            // fail (Chrome marker lag, Electron editors) never produce a
            // qualifying mouse-up AFTER the press — without showing here
            // the bar could never appear there. Show now, anchored at the
            // cursor, through the same presentation path (dedup gate
            // lives in showPanel).
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
            guard self.enabled, !self.excludedApps.contains(front) else { return }
            let location = NSEvent.mouseLocation
            for frame in self.ownFrames() where frame.contains(location) { return }
            FileLog.write("SEL1 fire: len=\(text.count) front=\(front) via=copy-show")
            self.onSelection?(text, location)
        }
    }


    /// True while the synthetic-⌘C dance posts its events. ShortcutMonitor
    /// consults this to let the synthetic Cmd+C pass without firing the
    /// user-copy fallback (no double record, no double toolbar).
    /// Main-thread only — the dance and the shortcut tap both run there.
    static var syntheticCopyInFlight = false

    /// Editors whose selection is unreadable via every AX tier (they draw
    /// their own text). For these the synthetic ⌘C is the only read path.
    /// Comma-joined bundle ids, extendable via the `syntheticCopyApps`
    /// setting without a rebuild.
    static let syntheticCopyApps: Set<String> = {
        let raw = LexiStore.setting("syntheticCopyApps")
            ?? "com.sublimetext.4,com.sublimetext.3"
        return Set(
            raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty })
    }()

    /// Reads the selection by provoking a real Cmd+C and restoring the
    /// pasteboard. The hardening rules (the historical failure modes of
    /// this approach — literal "c"/"^C" typed into editors, clipboard
    /// litter):
    /// - events carry their OWN CGEventSource(.combinedSessionState) with
    ///   .maskCommand on BOTH down and up — a flags/session desync is what
    ///   leaked a bare "c" before;
    /// - down and up post back-to-back within one main-thread turn — no
    ///   runloop turn between them for the user's physical modifiers to
    ///   interleave;
    /// - the pasteboard is snapshotted (every item, every type) first and
    ///   restored after — an originally empty board is cleared again, so
    ///   nothing lingers;
    /// - ClipboardMonitor suppression spans the whole window: neither the
    ///   provoked copy nor the restore enters history;
    /// - bounded 0.6 s wait: no changeCount bump → restore → nil.
    /// MUST run on the main thread (pasteboard + event posting).
    private func readViaSyntheticCopy() -> String? {
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
        ClipboardMonitor.shared.beginCaptureSuppression()
        Self.syntheticCopyInFlight = true
        defer {
            Self.syntheticCopyInFlight = false
            if saved.isEmpty {
                pb.clearContents()
            } else {
                pb.clearContents()
                pb.writeObjects(saved)
            }
            ClipboardMonitor.shared.endCaptureSuppression()
            // noteCopyCommand's baseline must reflect the restored state.
            pasteboardBaseline = pb.changeCount
        }

        let baseline = pb.changeCount
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }

        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            // Service the runloop while waiting: the copy lands through
            // normal app event processing, and the poll timer keeps firing.
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            guard pb.changeCount > baseline else { continue }
            guard let text = pb.string(forType: .string),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            FileLog.write("SEL1 synthetic copy: len=\(text.count)")
            return text
        }
        FileLog.write("SEL1 synthetic copy: no pasteboard bump")
        return nil
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
        let mask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
        guard let machPort = CGEvent.tapCreate(
            tap: CGEventTapLocation(rawValue: 1) ?? .cghidEventTap, // kCGSessionEventTap
            place: .headInsertEventTap,
            options: .listenOnly, // passive: clicks always pass through
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            FileLog.write("SELECTION tap create failed — toolbar trigger disabled this launch")
            return
        }

        tap = machPort
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, machPort, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: machPort, enable: true)
        FileLog.write("SELECTION tap installed (drag/multi-click/keyboard gestures)")
    }

    private func observe(type: CGEventType, event: CGEvent) {
        // Snapshot every main-thread value HERE (the tap runs on the main
        // runloop): the AX work queue below must not touch AppKit state
        // (ownFrames reads NSApp/NSWindow) or race lastCopied.
        switch type {
        case .leftMouseDown:
            lastDown = event.location

        case .leftMouseUp:
            let up = event.location
            let down = lastDown
            lastDown = nil
            let clickCount = Int(event.getIntegerValueField(.mouseEventClickState))
            // Gesture gate: a plain stationary click is caret placement or
            // UI activation, never a selection — skip without touching AX
            // (the app's retained old selection must not re-pop the bar).
            guard Self.isDragOrMultiClick(down: down, up: up, clickCount: clickCount) else {
                FileLog.write("SEL1 skip: click not a selection gesture (count=\(clickCount))")
                return
            }
            let frames = ownFrames()
            let copied = lastCopied
            let isEnabled = enabled
            let excluded = excludedApps
            // Never read AX inside the tap callback: remote apps can take the
            // full messaging timeout, which both freezes this run loop and
            // gets the tap killed by the system. Hand off to a worker.
            workQueue.async { [weak self] in
                self?.handleMouseUp(
                    up: up, ownFrames: frames, lastCopied: copied,
                    enabled: isEnabled, excludedApps: excluded)
            }

        case .keyDown:
            // same retrieval path — keyboard-only selections surface the
            // bar too. Listen-only: the event always passes through.
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            guard Self.isSelectionKeyGesture(keyCode: keyCode, flags: flags) else { return }
            let point = event.location // key events carry the mouse position
            let frames = ownFrames()
            let copied = lastCopied
            let isEnabled = enabled
            let excluded = excludedApps
            workQueue.async { [weak self] in
                self?.handleMouseUp(
                    up: point, ownFrames: frames, lastCopied: copied,
                    enabled: isEnabled, excludedApps: excluded)
            }

        default:
            break
        }
    }


    private func handleMouseUp(
        up upLocation: CGPoint,
        ownFrames: [NSRect],
        lastCopied: (text: String, at: Date)?,
        enabled: Bool,
        excludedApps: [String]
    ) {
        guard enabled else { return }
        // Settle beat: the session tap observes the gesture BEFORE the
        // target app processes it — reading AX immediately races the
        // app's own selection update (the "drag sometimes doesn't fire"
        // flakiness). Give the app one beat first; we're off-main here
        // so this never blocks UI. (openclip's async hop has the same
        // effect implicitly.)
        Thread.sleep(forTimeInterval: 0.04)

        // Drag selections and click selections both land here: the AX read
        // below decides — no selection (window drag, scroll gesture, plain
        // click) simply skips via the empty-text guard.

        // CG global coords (top-left origin of the PRIMARY display) →
        // Cocoa global coords (bottom-left origin of the same display):
        // ONE flip against the primary display's height. The previous
        // tallest-screen max mis-flipped whenever the primary display is
        // not the topmost (e.g. laptop below an external monitor).
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? upLocation.y
        let cocoa = NSPoint(x: upLocation.x, y: primaryMaxY - upLocation.y)
        for frame in ownFrames where frame.contains(cocoa) {
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
        // Tier 4 — Sublime-class editors expose no AX selection at all:
        // provoke a real Cmd+C, peek, restore. Runs on the main thread
        // (pasteboard + event posting); the semaphore hop keeps the
        // workQueue from blocking main.
        if text.isEmpty, Self.syntheticCopyApps.contains(frontBundle) {
            let semaphore = DispatchSemaphore(value: 0)
            var picked: String?
            DispatchQueue.main.async { [weak self] in
                picked = self?.readViaSyntheticCopy()
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 1.0)
            if let viaCopy = picked?.trimmingCharacters(in: .whitespacesAndNewlines),
               !viaCopy.isEmpty {
                text = viaCopy
                source = "synthetic-copy"
            }
        }

        guard !text.isEmpty else {
            FileLog.write("SEL1 skip: no AX text (front=\(frontBundle))")
            return
        }

        // Whole-container gestures can select megabytes (⌘A over a
        // terminal scrollback): the bar and card are for sentence-scale
        // text — refuse the monster (openclip maxTextLength parity).
        guard text.count <= 20_000 else {
            FileLog.write("SEL1 skip: text too large (\(text.count))")
            return
        }

        FileLog.write("SEL1 fire: len=\(text.count) front=\(frontBundle) via=\(source)")
        DispatchQueue.main.async { [weak self] in
            self?.onSelection?(text, cocoa)
        }
    }


    /// The full read chain: focused AX text → AXValue+range slice → web-area
    /// markers. (The copied fallback lives in handleMouseUp.) Ported from
    /// read_selected_text_via_ax / _ax_range / _web_area.
    static func readSelectedText() -> String? {
        guard let app = resolveFocusedApp() else { return nil }
        // Wake Chromium's accessibility tree: without an assistive client
        // setting the manual flag, Chrome never materializes its web AX
        // (focused-element queries fail, no markers) — the standard
        // PopClip-class remedy, idempotent on every engine. Engines have
        // answered either name over the years; set both. Chrome answers
        // an error for the set yet still honors it — materialization is
        // asynchronous (seconds), which the settle-retry loops absorb.
        for flag in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
            AXUIElementSetAttributeValue(app, flag as CFString, kCFBooleanTrue)
        }
        AXUIElementSetMessagingTimeout(app, 0.3)
        // Chromium materializes its tree ASYNCHRONOUSLY after the wake —
        // the first focused-element query can still fail. Retry briefly.
        var focused: AXUIElement?
        for attempt in 0..<6 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.05) }
            focused = axCopyElementAttribute(app, kAXFocusedUIElementAttribute as CFString)
            if focused != nil { break }
        }

        if let focused {
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
        }

        // Tier 3: web-area text markers (Chrome/Safari/Edge/Arc/Electron).
        // Chromium reports kAXFocusedUIElement as noValue while its tree is
        // waking (and sometimes returns a bare AXGroup with no attributes) —
        // the window-descendant web-area path must run regardless.
        if let text = readSelectedTextViaWebArea(app) {
            return text
        }
        return nil
    }

    /// Focused APPLICATION element. The system-wide query is the preferred
    /// source but goes cannotComplete while Chrome's tree is waking
    /// (observed — it killed the whole web tier from resolveWebAreaTargets);
    /// fall back to the frontmost pid, which answers immediately.
    private static func resolveFocusedApp() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var appRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            system, kAXFocusedApplicationAttribute as CFString, &appRef) == .success,
            let appRaw = appRef {
            return unsafeBitCast(appRaw, to: AXUIElement.self)
        }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return nil
        }
        return AXUIElementCreateApplication(pid)
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
    private static func readSelectedTextViaWebArea(_ app: AXUIElement) -> String? {
        // Settle-retry, openclip webAreaSettle parity (6 × 50 ms): web
        // engines update the selection markers ASYNCHRONOUSLY after the
        // gesture (Chrome renderer IPC can exceed 150 ms), and the first
        // element resolution is often wrong (focus still on browser
        // chrome). Poll the cached element; when it yields nothing,
        // RE-RESOLVE the targets fresh instead of retrying stale ones —
        // the old single-resolution loop was why Chrome "never"
        // triggered.
        var targets: (focused: AXUIElement?, webArea: AXUIElement)?
        for attempt in 0..<6 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.05) }
            if attempt % 2 == 0 || targets == nil {
                targets = resolveWebAreaTargets(app)
            }
            guard let current = targets else { continue }
            if let text = pollWebSelection(focused: current.focused, webArea: current.webArea) {
                return text
            }

        }
        return nil
    }

    /// Web area for the app element passed in (resolving through the
    /// system-wide focused application AGAIN here used to fail with
    /// cannotComplete on waking Chrome, killing the whole web tier). The
    /// focused ELEMENT is optional: Chromium reports it as noValue while
    /// its tree materializes, but the focused WINDOW still exposes the
    /// web area — the descendant path must carry the tier alone then.
    private static func resolveWebAreaTargets(_ app: AXUIElement) -> (focused: AXUIElement?, webArea: AXUIElement)? {
        AXUIElementSetMessagingTimeout(app, 0.5)
        let focused = axCopyElementAttribute(app, kAXFocusedUIElementAttribute as CFString)
        guard let webArea = focused.flatMap(findWebAreaAncestor)
            ?? findWebAreaInFocusedWindow(app)
        else { return nil }
        return (focused, webArea)
    }

    private static func pollWebSelection(focused: AXUIElement?, webArea: AXUIElement) -> String? {
        for element in [focused, webArea].compactMap({ $0 }) {
            guard let markerRange = copyMarkerRange(element) else { continue }
            var out: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                webArea, "AXStringForTextMarkerRange" as CFString, markerRange, &out
            ) == .success, let text = out as? String,
                !text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        if let text = axStringAttribute(webArea, kAXSelectedTextAttribute as CFString),
           !text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
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

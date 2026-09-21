import AppKit
import Carbon.HIToolbox
import CoreGraphics

// ---------------------------------------------------------------------------
// Global keyboard shortcuts via one session CGEventTap. (Not Carbon
// hotkeys: the double-modifier triggers and the DROPPABLE Alt+V need event
// observation, which RegisterEventHotKey cannot do.) Routes:
//   launcher shortcut  → launcher panel
//   clipboard shortcut → clipboard panel (Alt+V would otherwise type
//                        "√" into the focused app)
//   popup shortcut     → popup card
//   plain Cmd+C        → selection pipeline's copy fallback
//   raw keyDown        → the settings shortcut recorder (pre-IME keys)
// Every fired keyCombo route DROPS its event: a bound combo belongs to
// Lexi alone (Cmd+Space would otherwise also open Spotlight).

// ---------------------------------------------------------------------------

enum LexiShortcutMode: Equatable {
    case keyCombo(cmd: Bool, shift: Bool, ctrl: Bool, alt: Bool, keyCode: UInt16)
    case doubleModifier(keyCode: UInt16)

    /// Parses the preset space: doubled modifiers ("Shift+Shift") and
    /// modifier+key combos ("Ctrl+V", "Cmd+Space", "Alt+Up"). Case-insensitive.
    static func parse(_ shortcut: String) -> LexiShortcutMode? {
        let parts = shortcut.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard parts.count >= 2 else { return nil }

        if parts.count == 2, parts[0] == parts[1],
           let code = modifierNameToCode(parts[0]) {
            return .doubleModifier(keyCode: code)
        }

        var cmd = false, shift = false, ctrl = false, alt = false
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command": cmd = true
            case "shift": shift = true
            case "ctrl", "control": ctrl = true
            case "alt", "option": alt = true
            default: return nil
            }
        }
        guard cmd || shift || ctrl || alt,
              let keyCode = keyNameToCode(parts.last ?? "")
        else { return nil }
        return .keyCombo(cmd: cmd, shift: shift, ctrl: ctrl, alt: alt, keyCode: keyCode)
    }

    // MARK: name ↔ keycode (HIToolbox constants — no hand-typed hex tables)

    private static let modifiers: [String: UInt16] = [
        "ctrl": UInt16(kVK_Control), "control": UInt16(kVK_Control),
        "shift": UInt16(kVK_Shift),
        "alt": UInt16(kVK_Option), "option": UInt16(kVK_Option),
        "cmd": UInt16(kVK_Command), "command": UInt16(kVK_Command),
    ]

    private static func modifierNameToCode(_ name: String) -> UInt16? {
        modifiers[name]
    }


    /// Shortcut keys: lowercase ANSI letters/digits plus the non-typing
    /// keys launchers live on (Cmd+Space is the classic). Names are the
    /// parse vocabulary; `displayNames` is how they render.
    private static let keys: [String: UInt16] = [
        "a": UInt16(kVK_ANSI_A), "s": UInt16(kVK_ANSI_S), "d": UInt16(kVK_ANSI_D), "f": UInt16(kVK_ANSI_F),
        "h": UInt16(kVK_ANSI_H), "g": UInt16(kVK_ANSI_G), "z": UInt16(kVK_ANSI_Z), "x": UInt16(kVK_ANSI_X),
        "c": UInt16(kVK_ANSI_C), "v": UInt16(kVK_ANSI_V), "b": UInt16(kVK_ANSI_B), "q": UInt16(kVK_ANSI_Q),
        "w": UInt16(kVK_ANSI_W), "e": UInt16(kVK_ANSI_E), "r": UInt16(kVK_ANSI_R), "y": UInt16(kVK_ANSI_Y),
        "t": UInt16(kVK_ANSI_T), "u": UInt16(kVK_ANSI_U), "i": UInt16(kVK_ANSI_I), "o": UInt16(kVK_ANSI_O),
        "p": UInt16(kVK_ANSI_P), "l": UInt16(kVK_ANSI_L), "j": UInt16(kVK_ANSI_J), "k": UInt16(kVK_ANSI_K),
        "n": UInt16(kVK_ANSI_N), "m": UInt16(kVK_ANSI_M),
        "0": UInt16(kVK_ANSI_0), "1": UInt16(kVK_ANSI_1), "2": UInt16(kVK_ANSI_2), "3": UInt16(kVK_ANSI_3),
        "4": UInt16(kVK_ANSI_4), "5": UInt16(kVK_ANSI_5), "6": UInt16(kVK_ANSI_6), "7": UInt16(kVK_ANSI_7),
        "8": UInt16(kVK_ANSI_8), "9": UInt16(kVK_ANSI_9),
        "space": UInt16(kVK_Space),
        "up": UInt16(kVK_UpArrow), "down": UInt16(kVK_DownArrow),
        "left": UInt16(kVK_LeftArrow), "right": UInt16(kVK_RightArrow),
        "return": UInt16(kVK_Return), "enter": UInt16(kVK_ANSI_KeypadEnter),
        "tab": UInt16(kVK_Tab),
        "delete": UInt16(kVK_Delete), "fwddelete": UInt16(kVK_ForwardDelete),
    ]

    private static func keyNameToCode(_ name: String) -> UInt16? {
        keys[name]
    }

    /// Display name for a keycode ("v" → "V", space → "Space") — the
    /// shortcut recorder renders captured keys with names `parse` reads
    /// back (case-insensitively).
    static func keyName(for keyCode: UInt16) -> String? {
        if let display = displayNames[keyCode] { return display }
        for (name, code) in keys where code == keyCode {
            return name.uppercased()
        }
        return nil
    }

    /// Pretty output names for the multi-character keys; single letters
    /// and digits uppercase themselves in `keyName`.
    private static let displayNames: [UInt16: String] = [
        UInt16(kVK_Space): "Space",
        UInt16(kVK_UpArrow): "Up", UInt16(kVK_DownArrow): "Down",
        UInt16(kVK_LeftArrow): "Left", UInt16(kVK_RightArrow): "Right",
        UInt16(kVK_Return): "Return", UInt16(kVK_ANSI_KeypadEnter): "Enter",
        UInt16(kVK_Tab): "Tab",
        UInt16(kVK_Delete): "Delete", UInt16(kVK_ForwardDelete): "FwdDelete",
    ]

    /// Display name for the first modifier held in `flags`
    /// ("Cmd"/"Ctrl"/"Alt"/"Shift"); nil when none.
    static func modifierName(for flags: NSEvent.ModifierFlags) -> String? {
        if flags.contains(.command) { return "Cmd" }
        if flags.contains(.control) { return "Ctrl" }
        if flags.contains(.option) { return "Alt" }
        if flags.contains(.shift) { return "Shift" }
        return nil
    }

    /// The flag bit a modifier keycode maps to (left/right share it).
    static func modifierFlag(forKeyCode code: UInt16) -> CGEventFlags? {
        switch code {
        case UInt16(kVK_Control), UInt16(kVK_RightControl): return .maskControl
        case UInt16(kVK_Shift), UInt16(kVK_RightShift): return .maskShift
        case UInt16(kVK_Option), UInt16(kVK_RightOption): return .maskAlternate
        case UInt16(kVK_Command), UInt16(kVK_RightCommand): return .maskCommand
        default: return nil
        }
    }

    // MARK: menu rendering

    /// Single-character menu glyphs for the multi-character keys
    /// (letters and digits are their own keyEquivalent).
    private static let menuKeyGlyphs: [UInt16: String] = [
        UInt16(kVK_Space): " ",
        UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
        UInt16(kVK_Return): "↩", UInt16(kVK_ANSI_KeypadEnter): "↩",
        UInt16(kVK_Tab): "⇥",
        UInt16(kVK_Delete): "⌫", UInt16(kVK_ForwardDelete): "⌦",
    ]

    /// Double-tap display glyphs ("⌘⌘" reads like the gesture itself).
    private static let modifierGlyphs: [UInt16: String] = [
        UInt16(kVK_Shift): "⇧", UInt16(kVK_Command): "⌘",
        UInt16(kVK_Control): "⌃", UInt16(kVK_Option): "⌥",
    ]

    /// NSMenuItem rendering of the shortcut, in lockstep with the string the
    /// Shortcuts pane shows: a combo becomes a real keyEquivalent — native
    /// right-aligned glyphs, and it performs while its menu is open. A
    /// double-modifier tap has no keystroke form and no honest glyph
    /// (keyEquivalent renders only its first character), so such rows show
    /// nothing; Settings remains the display for them.
    func menuKeyEquivalent() -> (String, NSEvent.ModifierFlags) {
        switch self {
        case .keyCombo(let cmd, let shift, let ctrl, let alt, let keyCode):
            var mask: NSEvent.ModifierFlags = []
            if cmd { mask.insert(.command) }
            if shift { mask.insert(.shift) }
            if ctrl { mask.insert(.control) }
            if alt { mask.insert(.option) }
            guard let name = LexiShortcutMode.keyName(for: keyCode) else { return ("", []) }
            let key = LexiShortcutMode.menuKeyGlyphs[keyCode]
                ?? String(name.prefix(1)).lowercased()
            return (key, mask)
        case .doubleModifier:
            // keyEquivalent renders only its FIRST character — a doubled
            // "⌘⌘" would display as a single ⌘ and read as a real (wrong)
            // shortcut. A double-tap gesture has no keystroke form; the
            // row shows nothing and Settings remains the display.
            return ("", [])
        }
    }
}


/// Double-press detector with typing protection: fires when the second
/// press lands within 300ms and no non-modifier KeyDown happened between
/// the presses. A clean fire resets; a dirty second press re-arms as a new
/// first press. Main-runloop only (the tap's runloop) — no locking.
final class DoublePressDetector {
    private let interval: TimeInterval = 0.3
    private var lastPress: Date?
    private var lastNonModKeyDown: Date?

    func noteNonModKeyDown() {
        lastNonModKeyDown = Date()
    }

    func detect(now: Date = Date()) -> Bool {
        if let prev = lastPress, now.timeIntervalSince(prev) <= interval {
            if let typed = lastNonModKeyDown, typed > prev {
                lastPress = now // typing between presses — dirty
                return false
            }
            lastPress = nil // reset: prevent triple-press
            return true
        }
        lastPress = now
        return false
    }
}

/// Owns the session event tap and the three shortcut routes.
final class ShortcutMonitor {
    /// Pre-IME hardware key events (keyCode, CGEventFlags.rawValue) for the
    /// settings shortcut recorder: input methods rewrite Option+letter
    /// combos at the session level, so the recorder must see the RAW key.
    /// Fired on the main thread.
    nonisolated(unsafe) static var rawKeyHandler: ((UInt16, UInt64) -> Void)?

    private var tap: CFMachPort?
    private let onLauncher: () -> Void
    private let onClipboard: () -> Void
    private let onPopup: () -> Void
    /// Plain Cmd+C (no other modifiers) — the browser fallback trigger,
    /// wired by the app to SelectionPipeline.noteCopyCommand().
    var onCopyCommand: (() -> Void)?

    /// One shortcut route; `mode` re-reads from the DB on reload().
    private struct Route {
        var mode: LexiShortcutMode?
        var detector = DoublePressDetector()
        let settingKey: String
        let fallback: String
        let fire: () -> Void
    }

    private var routes: [Route] = []

    init(onLauncher: @escaping () -> Void, onClipboard: @escaping () -> Void,
         onPopup: @escaping () -> Void = {}) {
        self.onLauncher = onLauncher
        self.onClipboard = onClipboard
        self.onPopup = onPopup
        routes = [
            Route(settingKey: "launcherShortcut", fallback: "Shift+Shift", fire: onLauncher),
            Route(settingKey: "clipboardShortcut", fallback: "Alt+V", fire: onClipboard),
            Route(settingKey: "popupShortcut", fallback: "Ctrl+Ctrl", fire: onPopup),
        ]
        reload()
        installTap()
    }

    func reload() {
        for index in routes.indices {
            routes[index].mode = LexiShortcutMode.parse(
                LexiStore.setting(routes[index].settingKey) ?? routes[index].fallback)
        }
    }

    private func installTap() {
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            // `toOpaque()` yields the instance's OWN address — recover the
            // reference with fromOpaque/takeUnretainedValue. Reading it via
            // `.pointee` reinterprets the object header (isa + refcount)
            // as a reference: a garbage pointer that crashed on first use.
            guard let userInfo else { return Unmanaged.passRetained(event) }
            let monitor = Unmanaged<ShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let machPort = CGEvent.tapCreate(
            tap: CGEventTapLocation(rawValue: 1) ?? .cghidEventTap, // kCGSessionEventTap
            place: .headInsertEventTap,
            options: .defaultTap, // clipboard combo must be droppable
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            // Rapid relaunches (build.sh run) can race the previous
            // instance's tap teardown — retry before giving up.
            FileLog.write("SHORTCUT tap create failed — retrying")
            retryInstallTap()
            return
        }
        tap = machPort
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, machPort, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: machPort, enable: true)
        FileLog.write("SHORTCUT tap installed (launcher + clipboard + popup, in-process)")
    }

    private var installRetries = 0

    private func retryInstallTap() {
        guard installRetries < 10 else {
            FileLog.write("SHORTCUT tap create failed — shortcuts disabled this launch")
            return
        }
        installRetries += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.tap == nil else { return }
            self.installTap()
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            CGEvent.tapEnable(tap: tap!, enable: true)
            return Unmanaged.passRetained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        switch type {
        case .flagsChanged:
            for route in routes {
                if case .doubleModifier(let code) = route.mode,
                   let flag = LexiShortcutMode.modifierFlag(forKeyCode: code),
                   flags.contains(flag),
                   route.detector.detect() {
                    DispatchQueue.main.async { route.fire() }
                }
            }

        case .keyDown:
            // The recorder sees every raw keyDown, pre-IME, on the main
            // thread (replaces a dedicated listen-only tap).
            if let raw = Self.rawKeyHandler {
                DispatchQueue.main.async { raw(keyCode, flags.rawValue) }
            }
            // Every keyDown dirties every double-press detector FIRST —
            // before any early return. The historical bug: the Cmd+C copy
            // path returned early, so the C between two Cmd presses was
            // never noted; ⌘C → ⌘V then read as a clean double-Cmd and
            // the panel stole focus mid-paste.
            for route in routes {
                route.detector.noteNonModKeyDown()
            }
            // Plain Cmd+C — the browser fallback trigger. A synthetic ⌘C
            // (Sublime-class selection read) is NOT a user copy: pass the
            // event through untouched so the pipeline's synthetic path owns
            // the result (no double record, no double toolbar).
            if Self.isCopyCommand(keyCode: keyCode, flags: flags) {
                if !SelectionPipeline.syntheticCopyInFlight {
                    DispatchQueue.main.async { [weak self] in
                        self?.onCopyCommand?()
                    }
                }
                return Unmanaged.passRetained(event)
            }
            // The clipboard combo swallows its event: Alt+V must not type
            // "√" into the focused app.
            if matchesCombo(routes.first { $0.settingKey == "clipboardShortcut" }, keyCode: keyCode, flags: flags) {
                DispatchQueue.main.async { [weak self] in self?.onClipboard() }
                return nil
            }
            // A fired keyCombo owns its event too: system-reserved combos
            // (Cmd+Space → Spotlight) would otherwise trigger BOTH Lexi
            // and the system handler on one press.
            for route in routes {
                if matchesCombo(route, keyCode: keyCode, flags: flags) {
                    DispatchQueue.main.async { route.fire() }
                    return nil
                }
            }

        default:
            break
        }
        return Unmanaged.passRetained(event)
    }

    /// True for a keyCombo route whose key and modifiers all match.
    private func matchesCombo(_ route: Route?, keyCode: UInt16, flags: CGEventFlags) -> Bool {
        guard case .keyCombo(let cmd, let shift, let ctrl, let alt, let code) = route?.mode else {
            return false
        }
        return keyCode == code
            && (!cmd || flags.contains(.maskCommand))
            && (!shift || flags.contains(.maskShift))
            && (!ctrl || flags.contains(.maskControl))
            && (!alt || flags.contains(.maskAlternate))
    }

    /// True for a plain Cmd+C KeyDown (no other modifiers).
    private static func isCopyCommand(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        keyCode == kVK_ANSI_C
            && flags.contains(.maskCommand)
            && !flags.contains(.maskShift)
            && !flags.contains(.maskControl)
            && !flags.contains(.maskAlternate)
    }
}

import AppKit
import CoreGraphics

// ---------------------------------------------------------------------------
// Global keyboard shortcuts — the first slice of the CGEventTap migration.
// The helper hosts the session tap (TCC trust resolves through the parent
// bundle — probed at startup, see probeEventTapAccess) and routes:
//   launcher shortcut  → launcher panel (in-process)
//   clipboard shortcut → clipboard panel (in-process)
// The popup shortcut stays in Rust until the AX selection reader migrates.
// The clipboard arm DROPS matching events: Alt+V would otherwise type "√"
// into the focused app (the one swallowing rule the Rust tap had).
// ---------------------------------------------------------------------------

enum LexiShortcutMode: Equatable {
    case keyCombo(cmd: Bool, shift: Bool, ctrl: Bool, alt: Bool, keyCode: UInt16)
    case doubleModifier(keyCode: UInt16)

    /// Port of ShortcutMode::parse for the preset space: doubled modifiers
    /// ("Shift+Shift") and modifier+letter/digit combos.
    static func parse(_ shortcut: String) -> LexiShortcutMode? {
        let parts = shortcut.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard parts.count >= 2 else { return nil }

        if parts.count == 2, parts[0] == parts[1],
           let code = Self.modifierNameToCode(parts[0]) {
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
              let keyCode = Self.keyNameToCode(parts.last ?? "")
        else { return nil }
        return .keyCombo(cmd: cmd, shift: shift, ctrl: ctrl, alt: alt, keyCode: keyCode)
    }

    private static func modifierNameToCode(_ name: String) -> UInt16? {
        switch name {
        case "ctrl", "control": return 0x3B // kVK_Control
        case "shift": return 0x38 // kVK_Shift
        case "alt", "option": return 0x3A // kVK_Option
        case "cmd", "command": return 0x37 // kVK_Command
        default: return nil
        }
    }

    private static func keyNameToCode(_ name: String) -> UInt16? {
        let letters: [String: UInt16] = [
            "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
            "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
            "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "u": 0x20,
            "i": 0x22, "o": 0x1F, "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28,
            "n": 0x2D, "m": 0x2E,
        ]
        let digits: [String: UInt16] = [
            "0": 0x1D, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15,
            "5": 0x17, "6": 0x16, "7": 0x1A, "8": 0x1C, "9": 0x19,
        ]
        return letters[name] ?? digits[name]
    }

    /// The flag bit a modifier keycode maps to (left/right share it).
    static func modifierFlag(forKeyCode code: UInt16) -> CGEventFlags? {
        switch code {
        case 0x3B, 0x3E: return .maskControl
        case 0x38, 0x3C: return .maskShift
        case 0x3A, 0x3D: return .maskAlternate
        case 0x37, 0x36: return .maskCommand
        default: return nil
        }
    }
}

/// Double-press detector with typing protection (port of
/// detect_double_press): fires when the second press lands within 300ms and
/// no non-modifier KeyDown happened between the presses. A clean fire
/// resets; a dirty second press re-arms as a new first press.
final class DoublePressDetector {
    private let interval: TimeInterval = 0.3
    private var lastPress: Date?
    private var lastNonModKeyDown: Date?
    private let lock = NSLock()

    func noteNonModKeyDown() {
        lock.lock()
        lastNonModKeyDown = Date()
        lock.unlock()
    }

    func detect(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
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

/// Owns the session event tap and the two shortcut routes.
final class ShortcutMonitor {
    private var tap: CFMachPort?
    private var launcherDetector = DoublePressDetector()
    private var launcherMode: LexiShortcutMode?
    private var clipboardDetector = DoublePressDetector()
    private var clipboardMode: LexiShortcutMode?
    private let onLauncher: () -> Void
    private let onClipboard: () -> Void
    /// Plain Cmd+C (no other modifiers) — the browser fallback trigger.
    /// Wired by the app to SelectionPipeline.noteCopyCommand().
    var onCopyCommand: (() -> Void)?

    /// True for a plain Cmd+C KeyDown (port of is_copy_command).
    private static func isCopyCommand(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        keyCode == 0x08 // kVK_ANSI_C
            && flags.contains(.maskCommand)
            && !flags.contains(.maskShift)
            && !flags.contains(.maskControl)
            && !flags.contains(.maskAlternate)
    }

    init(onLauncher: @escaping () -> Void, onClipboard: @escaping () -> Void) {
        self.onLauncher = onLauncher
        self.onClipboard = onClipboard
        reload()
        installTap()
    }

    func reload() {
        launcherMode = LexiShortcutMode.parse(LexiStore.setting("launcherShortcut") ?? "Shift+Shift")
        clipboardMode = LexiShortcutMode.parse(LexiStore.setting("clipboardShortcut") ?? "Alt+V")
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
            FileLog.write("SHORTCUT tap create failed — shortcuts stay on the Rust tap")
            return
        }
        tap = machPort
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, machPort, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: machPort, enable: true)
        FileLog.write("SHORTCUT tap installed (launcher + clipboard, in-process)")
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
            if case .doubleModifier(let code) = launcherMode,
               LexiShortcutMode.modifierFlag(forKeyCode: code).map({ flags.contains($0) }) == true,
               launcherDetector.detect() {
                DispatchQueue.main.async { [weak self] in self?.onLauncher() }
            }
            if case .doubleModifier(let code) = clipboardMode,
               LexiShortcutMode.modifierFlag(forKeyCode: code).map({ flags.contains($0) }) == true,
               clipboardDetector.detect() {
                DispatchQueue.main.async { [weak self] in self?.onClipboard() }
            }

        case .keyDown:
            // Plain Cmd+C — the browser fallback trigger (Layer 2).
            if Self.isCopyCommand(keyCode: keyCode, flags: flags) {
                DispatchQueue.main.async { [weak self] in
                    self?.onCopyCommand?()
                }
                return Unmanaged.passRetained(event)
            }
            if case .keyCombo(let cmd, let shift, let ctrl, let alt, let code) = clipboardMode,
               keyCode == code,
               (!cmd || flags.contains(.maskCommand)),
               (!shift || flags.contains(.maskShift)),
               (!ctrl || flags.contains(.maskControl)),
               (!alt || flags.contains(.maskAlternate)) {
                DispatchQueue.main.async { [weak self] in self?.onClipboard() }
                return nil // the one swallowing arm: Alt+V must not type "√"
            }
            launcherDetector.noteNonModKeyDown()
            clipboardDetector.noteNonModKeyDown()
            if case .keyCombo(let cmd, let shift, let ctrl, let alt, let code) = launcherMode,
               keyCode == code,
               (!cmd || flags.contains(.maskCommand)),
               (!shift || flags.contains(.maskShift)),
               (!ctrl || flags.contains(.maskControl)),
               (!alt || flags.contains(.maskAlternate)) {
                DispatchQueue.main.async { [weak self] in self?.onLauncher() }
            }

        default:
            break
        }
        return Unmanaged.passRetained(event)
    }
}

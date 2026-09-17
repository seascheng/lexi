import AppKit
import Foundation
import Network

private let logURL = URL(fileURLWithPath: "/tmp/lexi-selection-helper.log")

/// goty-style color system: every lift is derived from the theme's own
/// background/foreground pair (no second palette, no accent-blue capsules).
/// Contrast floors are computed like ChromeTheme: 4.5:1 secondary, 3.5:1
/// tertiary; alpha is used only for hairlines, never for text.
struct CardTheme {
    static let dark = CardTheme(
        background: NSColor(red: 28.0 / 255, green: 28.0 / 255, blue: 28.0 / 255, alpha: 1),
        foreground: NSColor(red: 221.0 / 255, green: 238.0 / 255, blue: 221.0 / 255, alpha: 1)
    )
    static let light = CardTheme(
        background: NSColor.white,
        foreground: NSColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1)
    )

    let background: NSColor
    let foreground: NSColor

    var isDark: Bool {
        (background.usingColorSpace(.deviceRGB) ?? background).brightnessComponent < 0.5
    }

    func blend(_ from: NSColor, toward: NSColor, fraction: CGFloat) -> NSColor {
        let a = from.usingColorSpace(.deviceRGB) ?? from
        let b = toward.usingColorSpace(.deviceRGB) ?? toward
        return NSColor(
            red: a.redComponent + (b.redComponent - a.redComponent) * fraction,
            green: a.greenComponent + (b.greenComponent - a.greenComponent) * fraction,
            blue: a.blueComponent + (b.blueComponent - a.blueComponent) * fraction,
            alpha: 1
        )
    }

    private func luminance(_ c: NSColor) -> CGFloat {
        let x = c.usingColorSpace(.deviceRGB) ?? c
        func f(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * f(x.redComponent) + 0.7152 * f(x.greenComponent) + 0.0722 * f(x.blueComponent)
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Foreground stepped back toward the background, never below 4.5:1.
    var secondaryText: NSColor {
        var t: CGFloat = 0.38
        while t >= 0 {
            let mixed = blend(foreground, toward: background, fraction: t)
            if contrast(mixed, background) >= 4.5 { return mixed }
            t -= 0.04
        }
        return foreground
    }

    /// Quietest step (hints, footnotes) — 3.5:1 floor.
    var tertiaryText: NSColor {
        var t: CGFloat = 0.55
        while t >= 0 {
            let mixed = blend(foreground, toward: background, fraction: t)
            if contrast(mixed, background) >= 3.5 { return mixed }
            t -= 0.04
        }
        return secondaryText
    }

    /// Surface fills are translucent overlays, never opaque blends: the
    /// panels float on Liquid Glass (or the legacy frosted material), and
    /// an opaque rectangle reads as a foreign patch on it. Dark themes
    /// lift with white alpha, light themes shade with black alpha — the
    /// same rule the toolbar buttons, tag dropdown and run chips use.
    var hoverFill: NSColor {
        (isDark ? NSColor.white : NSColor.black).withAlphaComponent(isDark ? 0.08 : 0.055)
    }

    /// One step stronger than hover — the input field surface.
    var inputFill: NSColor {
        (isDark ? NSColor.white : NSColor.black).withAlphaComponent(isDark ? 0.10 : 0.06)
    }

    /// Selection capsule: same-hue emphasis, not accent blue (goty style).
    var selectedFill: NSColor {
        (isDark ? NSColor.white : NSColor.black).withAlphaComponent(isDark ? 0.18 : 0.12)
    }

    /// Icon tint sits near the full foreground.
    var iconTint: NSColor { blend(background, toward: foreground, fraction: 0.85) }

    var hairline: NSColor {
        NSColor.black.withAlphaComponent(isDark ? 0.35 : 0.12)
    }

    var dangerFill: NSColor {
        NSColor(calibratedRed: 0.78, green: 0.22, blue: 0.25, alpha: 1)
    }
}

/// Unified design language for every native surface — the ONE place visual
/// constants live (TinyCast's Theme.swift is the model). Surfaces declare a
/// ROLE and consume tokens; nobody hand-tunes values at call sites.
///   划词工具条 = .bar   Notes 面板 = .list
///   结果卡     = .card  Launcher   = .launcher
enum PanelStyle {
    enum Surface {
        case bar, list, card, launcher

        var cornerRadius: CGFloat {
            switch self {
            case .bar: return 10
            case .list: return 16
            case .card: return 20
            case .launcher: return 22
            }
        }
    }

    /// Frost level (Settings → Appearance). Native vibrancy has no
    /// continuous blur radius — the material IS the blur knob.
    enum Blur: String {
        case clear, frosted, solid

        var material: NSVisualEffectView.Material {
            switch self {
            case .clear: return .hudWindow
            case .frosted: return .sheet
            case .solid: return .sidebar
            }
        }
    }

    /// Live, user-configurable surface state pushed over /theme.
    /// `opacity` is the scrim alpha for the dark theme (default 0.40);
    /// light scales it ×1.375 to preserve the shipped look.
    static var opacity: CGFloat = 0.40
    static var blur: Blur = .clear

    /// Every live surface material view (weak) — blur changes retune them
    /// without rebuilding panels.
    private static var materialViews: [WeakMaterialView] = []
    private struct WeakMaterialView { weak var view: NSVisualEffectView? }

    static func register(_ view: NSVisualEffectView) {
        materialViews.append(WeakMaterialView(view: view))
        view.material = blur.material
    }

    static func update(opacity newOpacity: CGFloat?, blur newBlur: Blur?) {
        if let newOpacity { opacity = newOpacity }
        if let newBlur { blur = newBlur }
        materialViews.removeAll { $0.view == nil }
        materialViews.forEach { $0.view?.material = blur.material }
    }

    /// Theme-tinted veil between the glass material and the content
    /// (TinyCast `panelScrim`), at the user's opacity.
    static func scrim(dark: Bool) -> NSColor {
        let base = min(max(opacity, 0.10), 0.90)
        let alpha = dark ? base : min(base * 1.375, 0.95)
        return dark
            ? NSColor.black.withAlphaComponent(alpha)
            : NSColor.white.withAlphaComponent(alpha)
    }
    static func controlBorder(dark: Bool) -> NSColor {
        dark
            ? NSColor.white.withAlphaComponent(0.12)
            : NSColor.black.withAlphaComponent(0.10)
    }
}

/// Shared surface builder for every native panel. macOS 26+: the system
/// renders `.hudWindow` vibrancy AS Liquid Glass with its own contrast
/// adaptation and edge highlight (a raw NSGlassEffectView is a nearly clear
/// sheet that washes out — the original complaint); the theme scrim is
/// painted on `content` between material and content. Older systems: the
/// legacy frosted `.menu` vibrancy with its own hairline stroke.
/// Returns (background, content, isGlass): set the panel's contentView to
/// `background` and add all subviews to `content`.
func makePanelBackground(
    frame: NSRect,
    surface: PanelStyle.Surface
) -> (background: NSView, content: NSView, isGlass: Bool) {
    let cornerRadius = surface.cornerRadius
    if #available(macOS 26.0, *) {
        // The glass material is composited by the WINDOW SERVER and ignores
        // cornerRadius set on the vibrancy view's own layer — the square
        // backdrop behind rounded corners. A real composited mask (what
        // SwiftUI clipShape does under TinyCast) is required: a clipping
        // superview whose layer rounds AND clips the vibrancy child.
        let clip = NSView(frame: frame)
        clip.autoresizingMask = [.width, .height]
        clip.wantsLayer = true
        clip.layer?.cornerRadius = cornerRadius
        clip.layer?.masksToBounds = true
        let vibrancy = NSVisualEffectView(frame: clip.bounds)
        vibrancy.autoresizingMask = [.width, .height]
        vibrancy.material = .hudWindow
        PanelStyle.register(vibrancy)
        vibrancy.blendingMode = .behindWindow
        vibrancy.state = .active
        clip.addSubview(vibrancy)
        let content = NSView(frame: clip.bounds)
        content.autoresizingMask = [.width, .height]
        content.wantsLayer = true
        content.focusRingType = .none
        clip.addSubview(content)
        return (clip, content, true)
    }
    // PopClip-style frosted bar: the material adapts to whatever is behind
    // it; the accent stroke keeps the edge legible over any background.
    let vibrancy = NSVisualEffectView(frame: frame)
    vibrancy.autoresizingMask = [.width, .height]
    vibrancy.material = .menu
    vibrancy.blendingMode = .behindWindow
    vibrancy.state = .active
    vibrancy.wantsLayer = true
    vibrancy.layer?.cornerRadius = cornerRadius
    vibrancy.layer?.borderWidth = 0.5
    vibrancy.layer?.masksToBounds = true
    return (vibrancy, vibrancy, false)
}

/// File logger usable from any class (the controller's log() is private).
enum FileLog {
    static func write(_ message: String) {
        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }
}
private let IPC_HOST = "127.0.0.1"
private let ACTION_PORT: UInt16 = 43876  // legacy fallback; real port comes from --action-port

private let toolbarHandleWidth: CGFloat = 16
private let toolbarSegmentWidth: CGFloat = 30
private let toolbarHeight: CGFloat = 28
private let toolbarIconSize: CGFloat = 14
private let toolbarVerticalGap: CGFloat = 6
private let notesPanelWidth: CGFloat = 380
private let resultCardWidth: CGFloat = 420
private let notesRowHeight: CGFloat = 32
private let notesMaxVisibleRows = 8

private struct ToolbarAction: Decodable {
    let id: String
    let title: String
    let icon: String
}

private func defaultToolbarActions() -> [ToolbarAction] {
    [
        ToolbarAction(id: "translation", title: "Translate", icon: "languages"),
        ToolbarAction(id: "rewrite", title: "Rewrite", icon: "wand"),
        ToolbarAction(id: "speak", title: "Speak", icon: "volume"),
        ToolbarAction(id: "extract", title: "Extract", icon: "sparkles"),
    ]
}

func hexString(_ color: NSColor) -> String {
    let c = color.usingColorSpace(.sRGB) ?? color
    return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
}

func lucideImage(for icon: String, title: String, color: NSColor? = nil) -> NSImage? {
    let stroke = color.map { "stroke=\"\(hexString($0))\"" } ?? "stroke=\"#000000\""
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" \(stroke) stroke-width="2" stroke-linecap="round" stroke-linejoin="round">\(lucideMarkup(for: icon))</svg>
    """
    guard let image = NSImage(data: Data(svg.utf8)) else {
        return NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: title)
    }
    image.isTemplate = color == nil
    image.size = NSSize(width: toolbarIconSize, height: toolbarIconSize)
    image.accessibilityDescription = title
    return image
}

/// Deterministic tag → hue mapping: the same tag always lands on the same
/// traffic-light color in both themes (the row dot and the tag pill share it).
func tagColor(for tag: String, dark: Bool) -> NSColor {
    guard !tag.isEmpty else { return .clear }
    var hash: UInt64 = 5381
    for scalar in tag.unicodeScalars { hash = hash &* 33 &+ UInt64(scalar.value) }
    let hue = CGFloat(hash % 360) / 360.0
    return NSColor(hue: hue, saturation: dark ? 0.62 : 0.72,
                   brightness: dark ? 0.98 : 0.58, alpha: 1)
}

func lucideMarkup(for icon: String) -> String {
    switch icon {
    case "pin":
        return """
        <path d="M12 17v5"/><path d="M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V6h1a2 2 0 0 0 0-4H8a2 2 0 0 0 0 4h1z"/>
        """
    case "pin-off":
        return """
        <path d="M12 17v5"/><path d="M15 9.34V6h1a2 2 0 0 0 0-4H7.7"/><path d="m2 2 20 20"/><path d="M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V6h1a2 2 0 0 0 0-4H8a2 2 0 0 0 0 4h1z"/>
        """
    case "languages":
        return """
        <path d="m5 8 6 6"/><path d="m4 14 6-6 2-3"/><path d="M2 5h12"/><path d="M7 2h1"/><path d="m22 22-5-10-5 10"/><path d="M14 18h6"/>
        """
    case "pen":
        return """
        <path d="M12 20h9"/><path d="M16.376 3.622a1 1 0 0 1 3.002 3.002L7.368 18.635a2 2 0 0 1-.855.506l-2.872.838a.5.5 0 0 1-.62-.62l.838-2.872a2 2 0 0 1 .506-.854z"/>
        """
    case "sparkles":
        return """
        <path d="M9.937 15.5A2 2 0 0 0 8.5 14.063l-6.135-1.582a.5.5 0 0 1 0-.962L8.5 9.936A2 2 0 0 0 9.937 8.5l1.582-6.135a.5.5 0 0 1 .963 0L14.063 8.5A2 2 0 0 0 15.5 9.937l6.135 1.581a.5.5 0 0 1 0 .964L15.5 14.063a2 2 0 0 0-1.437 1.437l-1.582 6.135a.5.5 0 0 1-.963 0z"/><path d="M20 3v4"/><path d="M22 5h-4"/><path d="M4 17v2"/><path d="M5 18H3"/>
        """
    case "book-plus":
        return """
        <path d="M12 7v6"/><path d="M4 19.5v-15A2.5 2.5 0 0 1 6.5 2H19a1 1 0 0 1 1 1v18a1 1 0 0 1-1 1H6.5a1 1 0 0 1 0-5H20"/><path d="M9 10h6"/>
        """
    case "highlighter":
        return """
        <path d="m9 11-6 6v3h9l3-3"/><path d="m22 12-4.6 4.6a2 2 0 0 1-2.8 0l-5.2-5.2a2 2 0 0 1 0-2.8L14 4"/>
        """
    case "file-text":
        return """
        <path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4"/><path d="M10 9H8"/><path d="M16 13H8"/><path d="M16 17H8"/>
        """
    case "message":
        return """
        <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/>
        """
    case "volume":
        return """
        <path d="M11 4.702a.705.705 0 0 0-1.203-.498L6.413 7.587A1.4 1.4 0 0 1 5.416 8H3a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h2.416a1.4 1.4 0 0 1 .997.413l3.383 3.384A.705.705 0 0 0 11 19.298z"/><path d="M16 9a5 5 0 0 1 0 6"/><path d="M19.364 18.364a9 9 0 0 0 0-12.728"/>
        """
    case "clipboard":
        return """
        <rect width="8" height="4" x="8" y="2" rx="1" ry="1"/><path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"/><path d="M12 11h4"/><path d="M12 16h4"/><path d="M8 11h.01"/><path d="M8 16h.01"/>
        """
    case "x":
        return """
        <path d="M18 6 6 18"/><path d="m6 6 12 12"/>
        """
    case "copy":
        return """
        <rect width="14" height="14" x="8" y="8" rx="2" ry="2"/><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/>
        """
    case "search":
        return """
        <circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/>
        """
    case "notebook-pen":
        return """
        <path d="M13.4 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-7.4"/><path d="M2 6h4"/><path d="M2 10h4"/><path d="M2 14h4"/><path d="M2 18h4"/><path d="M21.378 5.626a1 1 0 1 0-3.004-3.004l-5.01 5.012a2 2 0 0 0-.506.854l-.837 2.87a.5.5 0 0 0 .62.62l2.87-.837a2 2 0 0 0 .854-.506z"/>
        """
    case "wand":
        return """
        <path d="M15 4V2"/><path d="M15 16v-2"/><path d="M8 9h2"/><path d="M20 9h2"/><path d="M17.8 11.8 19 13"/><path d="M15 9h.01"/><path d="M17.8 6.2 19 5"/><path d="m3 21 9-9"/><path d="M12.2 6.2 11 5"/>
        """
    case "book-open":
        return """
        <path d="M2 3h6a4 4 0 0 1 4 4v14a3 3 0 0 0-3-3H2z"/><path d="M22 3h-6a4 4 0 0 0-4 4v14a3 3 0 0 1 3-3h7z"/>
        """
    case "send":
        return """
        <path d="M14.536 21.686a.5.5 0 0 0 .937-.024l6.5-19a.496.496 0 0 0-.635-.635l-19 6.5a.5.5 0 0 0-.024.937l7.93 3.18a2 2 0 0 1 1.112 1.11z"/><path d="m21.854 2.147-10.94 10.939"/>
        """
    // ── New Icons ──────────────────────────────────
    case "type":
        return """
        <polyline points="4 7 4 4 20 4 20 7"/><line x1="9" x2="15" y1="20" y2="20"/><line x1="12" x2="12" y1="4" y2="20"/>
        """
    case "heading":
        return """
        <path d="M6 12h12"/><path d="M6 20V4"/><path d="M18 20V4"/>
        """
    case "bookmark":
        return """
        <path d="m19 21-7-4-7 4V5a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2v16z"/>
        """
    case "star":
        return """
        <path d="M11.525 2.295a.53.53 0 0 1 .95 0l2.31 4.679a2.123 2.123 0 0 0 1.595 1.16l5.166.756a.53.53 0 0 1 .294.904l-3.736 3.638a2.123 2.123 0 0 0-.611 1.878l.882 5.14a.53.53 0 0 1-.771.56l-4.618-2.428a2.122 2.122 0 0 0-1.973 0L6.396 21.01a.53.53 0 0 1-.77-.56l.881-5.139a2.122 2.122 0 0 0-.611-1.879L2.16 9.795a.53.53 0 0 1 .294-.906l5.165-.755a2.122 2.122 0 0 0 1.597-1.16z"/>
        """
    case "heart":
        return """
        <path d="M19 14c1.49-1.46 3-3.21 3-5.5A5.5 5.5 0 0 0 16.5 3c-1.76 0-3 .5-4.5 2-1.5-1.5-2.74-2-4.5-2A5.5 5.5 0 0 0 2 8.5c0 2.3 1.5 4.05 3 5.5l7 7Z"/>
        """
    case "flag":
        return """
        <path d="M4 15s1-1 4-1 5 2 8 2 4-1 4-1V3s-1 1-4 1-5-2-8-2-4 1-4 1z"/><line x1="4" x2="4" y1="22" y2="15"/>
        """
    case "tag":
        return """
        <path d="M12.586 2.586A2 2 0 0 0 11.172 2H4a2 2 0 0 0-2 2v7.172a2 2 0 0 0 .586 1.414l8.704 8.704a2.426 2.426 0 0 0 3.42 0l6.58-6.58a2.426 2.426 0 0 0 0-3.42z"/><circle cx="7.5" cy="7.5" r=".5" fill="currentColor"/>
        """
    case "hash":
        return """
        <line x1="4" x2="20" y1="9" y2="9"/><line x1="4" x2="20" y1="15" y2="15"/><line x1="10" x2="8" y1="3" y2="21"/><line x1="16" x2="14" y1="3" y2="21"/>
        """
    case "check-circle":
        return """
        <path d="M21.801 10A10 10 0 1 1 17 3.335"/><path d="m9 11 3 3L22 4"/>
        """
    case "info":
        return """
        <circle cx="12" cy="12" r="10"/><path d="M12 16v-4"/><path d="M12 8h.01"/>
        """
    case "help-circle":
        return """
        <circle cx="12" cy="12" r="10"/><path d="M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3"/><path d="M12 17h.01"/>
        """
    case "shield":
        return """
        <path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"/>
        """
    case "globe":
        return """
        <circle cx="12" cy="12" r="10"/><path d="M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20"/><path d="M2 12h20"/>
        """
    case "compass":
        return """
        <path d="m16.24 7.76-1.804 5.411a2 2 0 0 1-1.265 1.265L7.76 16.24l1.804-5.411a2 2 0 0 1 1.265-1.265z"/><circle cx="12" cy="12" r="10"/>
        """
    case "mail":
        return """
        <rect width="20" height="16" x="2" y="4" rx="2"/><path d="m22 7-8.97 5.7a1.94 1.94 0 0 1-2.06 0L2 7"/>
        """
    case "at-sign":
        return """
        <circle cx="18" cy="5" r="3"/><circle cx="6" cy="12" r="3"/><circle cx="18" cy="19" r="3"/><line x1="8.59" x2="15.42" y1="13.51" y2="17.49"/><line x1="15.41" x2="8.59" y1="6.51" y2="10.49"/>
        """
    case "image":
        return """
        <rect width="18" height="18" x="3" y="3" rx="2" ry="2"/><circle cx="9" cy="9" r="2"/><path d="m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21"/>
        """
    case "mic":
        return """
        <path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3Z"/><path d="M19 10v2a7 7 0 0 1-14 0v-2"/><line x1="12" x2="12" y1="19" y2="22"/>
        """
    case "sun":
        return """
        <circle cx="12" cy="12" r="4"/><path d="M12 2v2"/><path d="M12 20v2"/><path d="m4.93 4.93 1.41 1.41"/><path d="m17.66 17.66 1.41 1.41"/><path d="M2 12h2"/><path d="M20 12h2"/><path d="m6.34 17.66-1.41 1.41"/><path d="m19.07 4.93-1.41 1.41"/>
        """
    case "moon":
        return """
        <path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z"/>
        """
    case "zap":
        return """
        <path d="M4 14a1 1 0 0 1-.78-1.63l9.9-10.2a.5.5 0 0 1 .86.46l-1.92 6.02A1 1 0 0 0 13 10h7a1 1 0 0 1 .78 1.63l-9.9 10.2a.5.5 0 0 1-.86-.46l1.92-6.02A1 1 0 0 0 11 14z"/>
        """
    case "flame":
        return """
        <path d="M8.5 14.5A2.5 2.5 0 0 0 11 12c0-1.38-.5-2-1-3-1.072-2.143-.224-4.054 2-6 .5 2.5 2 4.9 4 6.5 2 1.6 3 3.5 3 5.5a7 7 0 1 1-14 0c0-1.153.433-2.294 1-3a2.5 2.5 0 0 0 2.5 2.5z"/>
        """
    case "user":
        return """
        <path d="M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/>
        """
    case "clock":
        return """
        <circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>
        """
    case "calendar":
        return """
        <path d="M8 2v4"/><path d="M16 2v4"/><rect width="18" height="18" x="3" y="4" rx="2"/><path d="M3 10h18"/>
        """
    case "code":
        return """
        <polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/>
        """
    case "terminal":
        return """
        <polyline points="4 17 10 11 4 5"/><line x1="12" x2="20" y1="19" y2="19"/>
        """
    case "graduation-cap":
        return """
        <path d="M21.42 10.922a1 1 0 0 0-.019-1.838L12.83 5.18a2 2 0 0 0-1.66 0L2.6 9.08a1 1 0 0 0 0 1.832l8.57 3.908a2 2 0 0 0 1.66 0z"/><path d="M22 10v6"/><path d="M6 12.5V16a6 3 0 0 0 12 0v-3.5"/>
        """
    case "brain":
        return """
        <path d="M12 5a3 3 0 1 0-5.997.125 4 4 0 0 0-2.526 5.77 4 4 0 0 0 .556 6.588A4 4 0 1 0 12 18Z"/><path d="M12 5a3 3 0 1 1 5.997.125 4 4 0 0 1 2.526 5.77 4 4 0 0 1-.556 6.588A4 4 0 1 1 12 18Z"/><path d="M15 13a4.5 4.5 0 0 1-3-4 4.5 4.5 0 0 1-3 4"/><path d="M17.599 6.5a3 3 0 0 0 .399-1.375"/><path d="M6.003 5.125A3 3 0 0 0 6.401 6.5"/><path d="M3.477 10.896a4 4 0 0 1 .585-.396"/><path d="M19.938 10.5a4 4 0 0 1 .585.396"/><path d="M6 18a4 4 0 0 1-1.967-.516"/><path d="M19.967 17.484A4 4 0 0 1 18 18"/>
        """
    case "lightbulb":
        return """
        <path d="M15 14c.2-1 .7-1.7 1.5-2.5 1-.9 1.5-2.2 1.5-3.5A6 6 0 0 0 6 8c0 1 .2 2.2 1.5 3.5.7.7 1.3 1.5 1.5 2.5"/><path d="M9 18h6"/><path d="M10 22h4"/>
        """
    case "target":
        return """
        <circle cx="12" cy="12" r="10"/><circle cx="12" cy="12" r="6"/><circle cx="12" cy="12" r="2"/>
        """
    case "trophy":
        return """
        <path d="M6 9H4.5a2.5 2.5 0 0 1 0-5H6"/><path d="M18 9h1.5a2.5 2.5 0 0 0 0-5H18"/><path d="M4 22h16"/><path d="M10 14.66V17c0 .55-.47.98-.97 1.21C7.85 18.75 7 20.24 7 22"/><path d="M14 14.66V17c0 .55.47.98.97 1.21C16.15 18.75 17 20.24 17 22"/><path d="M18 2H6v7a6 6 0 0 0 12 0V2Z"/>
        """
    case "rocket":
        return """
        <path d="M4.5 16.5c-1.5 1.26-2 5-2 5s3.74-.5 5-2c.71-.84.7-2.13-.09-2.91a2.18 2.18 0 0 0-2.91-.09z"/><path d="m12 15-3-3a22 22 0 0 1 2-3.95A12.88 12.88 0 0 1 22 2c0 2.72-.78 7.5-6 11a22.35 22.35 0 0 1-4 2z"/><path d="M9 12H4s.55-3.03 2-4c1.62-1.08 5 0 5 0"/><path d="M12 15v5s3.03-.55 4-2c1.08-1.62 0-5 0-5"/>
        """
    case "palette":
        return """
        <circle cx="13.5" cy="6.5" r=".5" fill="currentColor"/><circle cx="17.5" cy="10.5" r=".5" fill="currentColor"/><circle cx="8.5" cy="7.5" r=".5" fill="currentColor"/><circle cx="6.5" cy="12.5" r=".5" fill="currentColor"/><path d="M12 2C6.5 2 2 6.5 2 12s4.5 10 10 10c.926 0 1.648-.746 1.648-1.688 0-.437-.18-.835-.437-1.125-.29-.289-.438-.652-.438-1.125a1.64 1.64 0 0 1 1.668-1.668h1.996c3.051 0 5.555-2.503 5.555-5.554C21.965 6.012 17.461 2 12 2z"/>
        """
    case "pencil":
        return """
        <path d="M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z"/><path d="m15 5 4 4"/>
        """
    case "refresh-cw":
        return """
        <path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/><path d="M8 16H3v5"/>
        """
    case "download":
        return """
        <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" x2="12" y1="15" y2="3"/>
        """
    case "upload":
        return """
        <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="17 8 12 3 7 8"/><line x1="12" x2="12" y1="3" y2="15"/>
        """
    case "link":
        return """
        <path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>
        """
    case "eye":
        return """
        <path d="M2.062 12.348a1 1 0 0 1 0-.696 10.75 10.75 0 0 1 19.876 0 1 1 0 0 1 0 .696 10.75 10.75 0 0 1-19.876 0"/><circle cx="12" cy="12" r="3"/>
        """
    case "settings":
        return """
        <path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z"/><circle cx="12" cy="12" r="3"/>
        """
    case "wrench":
        return """
        <path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z"/>
        """
    case "plus":
        return """
        <path d="M5 12h14"/><path d="M12 5v14"/>
        """
    case "filter":
        return """
        <polygon points="22 3 2 3 10 12.46 10 19 14 21 14 12.46 22 3"/>
        """
    case "folder":
        return """
        <path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/>
        """
    case "file":
        return """
        <path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4"/>
        """
    case "bold":
        return """
        <path d="M6 12h9a4 4 0 0 1 0 8H7a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1h7a4 4 0 0 1 0 8"/>
        """
    case "italic":
        return """
        <line x1="19" x2="10" y1="4" y2="4"/><line x1="14" x2="5" y1="20" y2="20"/><line x1="15" x2="9" y1="4" y2="20"/>
        """
    case "diamond":
        return """
        <path d="M2.7 10.3a2.41 2.41 0 0 0 0 3.41l7.59 7.59a2.41 2.41 0 0 0 3.41 0l7.59-7.59a2.41 2.41 0 0 0 0-3.41l-7.58-7.59a2.41 2.41 0 0 0-3.41 0Z"/>
        """
    case "check":
        return """
        <path d="M20 6 9 17l-5-5"/>
        """
    default:
        // UNKNOWN ICONS RENDER BLANK. The wand here silently replaced every
        // misspelled/missing glyph (the "x" and "check" bugs) — a missing
        // icon must be invisible, never a different icon.
        return ""
    }
}

private enum ToolbarTheme: String {
    case dark
    case light

    var backgroundColor: NSColor {
        switch self {
        case .dark:
            return NSColor(calibratedWhite: 0.07, alpha: 0.94)
        case .light:
            return NSColor(calibratedWhite: 0.98, alpha: 0.94)
        }
    }

    var iconColor: NSColor {
        switch self {
        case .dark:
            return .white
        case .light:
            return NSColor(calibratedWhite: 0.08, alpha: 1)
        }
    }

    var hoverColor: NSColor {
        switch self {
        case .dark:
            return NSColor(calibratedWhite: 1, alpha: 0.12)
        case .light:
            return NSColor(calibratedWhite: 0, alpha: 0.06)
        }
    }

    var pressedColor: NSColor {
        switch self {
        case .dark:
            return NSColor(calibratedWhite: 1, alpha: 0.18)
        case .light:
            return NSColor(calibratedWhite: 0, alpha: 0.10)
        }
    }
}

private final class ToolbarButton: NSButton {
    var theme: ToolbarTheme = .dark {
        didSet {
            contentTintColor = theme.iconColor
            updateBackground()
            needsDisplay = true
        }
    }
    private var trackingAreaRef: NSTrackingArea?
    private var isPressed = false {
        didSet {
            updateBackground()
        }
    }
    private var isHovering = false {
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

    private func setup() {
        wantsLayer = true
        // Small-radius highlight: the inset capsule gets a quiet 6pt corner.
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
    }

    private func updateBackground() {
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
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        trackingAreaRef = tracking
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        isPressed = false
        NSCursor.arrow.set()
    }

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

private final class ToolbarDragHandle: NSView {
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

    override func mouseEntered(with event: NSEvent) {
        NSCursor.openHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
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
    private var hoverArea: NSTrackingArea?
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
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        if let hoverArea { addTrackingArea(hoverArea) }
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
private final class HorizontalOnlyClip: NSScrollView {
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
private final class CardResizeZone: NSView {
    enum Edge { case corner, right, bottom }
    let edge: Edge
    /// (width, height) deltas — nil means "this zone doesn't change it".
    var onResize: ((_ width: CGFloat?, _ height: CGFloat?) -> Void)?
    var onReset: (() -> Void)?
    private var startMouse = NSPoint.zero
    private var startSize = NSSize(width: 420, height: 240)
    private var isDark = false
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

    private var cursor: NSCursor {
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

final class SelectionToolbarApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var panel: NSPanel!
    private var container: NSView!
    private var dragHandle: ToolbarDragHandle!
    private var buttons: [ToolbarButton] = []
    private var actions = defaultToolbarActions()
    private var theme: ToolbarTheme = .dark
    private var cardTheme: CardTheme { theme == .dark ? CardTheme.dark : CardTheme.light }
    private var selectedText = ""
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localMouseMoveMonitor: Any?
    private var globalMouseMoveMonitor: Any?
    private var globalScrollMonitor: Any?
    private var notesPanel: NSPanel!
    private lazy var launcherController: LauncherPanelController = {
        let controller = LauncherPanelController()
        controller.onHidden = { [weak self] in
            self?.postAction(action: "launcher-hidden", text: "-")
        }
        controller.onOpenSettings = { [weak self] in
            self?.launcherController.hide(notify: false)
            self?.showSettingsWindow()
        }
        return controller
    }()

    private lazy var clipboardController: ClipboardPanelController = {
        let controller = ClipboardPanelController()
        controller.onHidden = { [weak self] in
            self?.postAction(action: "clipboard-hidden", text: "-")
        }
        controller.onAction = { [weak self] action, text in
            self?.postAction(action: action, text: text)
        }
        return controller
    }()
    private var notesContainer: NSView!
    private var notesContent: NSView!
    private var notesScrollView: NSScrollView!
    private var notesRows: [(view: NSView, label: NSTextField, index: Int)] = []
    private var notesCount = 0
    private var notesSelectedIndex = 0
    private var resultPanel: NSPanel!
    private var resultContainer: NSView!
    private var resultTabsView: NSView!
    private var resultTabsClip: HorizontalOnlyClip!
    private var resultTrashButton: NSButton!
    private var resultCloseButton: NSButton!
    private var resultScrollView: NSScrollView!
    private var resultTextView: NSTextView!
    private var resultLoadingIndicator: NSView!
    private var resultLoadingLabel: NSTextField!
    private var translateIdleView: NSView!
    private var resultIdleLabel: NSTextField!
    private var resultIdleHint: NSTextField!
    private var resultIdleIcon: NSImageView!
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var resultActionBar: NSView!
    private var resultEntryBar: NSView!
    private var resultCopyButton: NSButton!
    private var resultSaveButton: NSButton!
    private var inputContainer: NSView!
    private var inputTextView: CardInputTextView!
    private var runsSeparator: NSView!
    private var inputButtonsRow: NSView!
    private var inputButtonsClip: HorizontalOnlyClip!
    private var cardRuns: [CardRun] = []
    private var cardActions: [CardActionsPayload.Item] = []
    private var activeRunId: String?
    private var activePanel = "translate"
    private var panelDefs: [(id: String, name: String, icon: String)] = []
    private var cardPanelTabsView: NSView!
    private var panelTabsControl: NSSegmentedControl!
    private var resultRunsBar: NSView!
    private var cardNotesClip: HorizontalOnlyClip!

    private var notesTableView: NotesTable!
    private var noteSearchContainer: NSView!
    private var noteSearchField: CardInputTextField!
    private var noteTagBar: NSView!
    private var noteTagButtons: [NSButton] = []
    private var noteSearchText = ""
    private var noteActiveTag = "all"
    private var displayedNotes: [CardNotesPayload.Note] = []
    private var cardNotesItems: [CardNotesPayload.Note] = []
    private var reviewCardView: NSView!
    private var reviewWordLabel: NSTextField!
    private var reviewAnswerLabel: NSTextField!
    private var cardPinned = false
    private var reviewRevealButton: NSButton!
    private var reviewGradeButtons: [NSButton] = []
    private var reviewEmptyLabel: NSTextField!
    private var reviewCurrentWordId: Int64 = 0
    private var runChipViews: [RunChipView] = []
    private var runTabsContentWidth: CGFloat = 376
    // Card opens at the user's preferred size (drag-resizable; double-click
    // a resize zone still returns to the auto-size default).
    private var cardUserWidth: CGFloat? = 428
    private var cardUserHeight: CGFloat? = 400
    private var resizeCorner: CardResizeZone!
    private var resizeRight: CardResizeZone!
    private var resizeBottom: CardResizeZone!
    private var entryButtons: [NSButton] = []
    private var listener: NWListener?
    private let listenerQueue = DispatchQueue(label: "lexi.toolbar.display")
    private let connectionQueue = DispatchQueue(label: "lexi.toolbar.connection")
    /// Native settings window (full-Swift migration, phase 1). Created on
    /// first show; the app controller itself is nonisolated, so every touch
    /// hops through `MainActor.assumeIsolated` on the main queue.
    private var settingsWindowController: LexiSettingsWindowController?
    private let actionPort: String
    private let toolbarPort: UInt16

    override init() {
        actionPort = SelectionToolbarApp.argumentValue("--action-port") ?? "43876"
        toolbarPort = UInt16(SelectionToolbarApp.argumentValue("--toolbar-port") ?? "") ?? 43877
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("helper started bundle=\(Bundle.main.bundleIdentifier ?? "none") toolbarPort=\(toolbarPort) actionPort=\(actionPort)")
        NSApp.setActivationPolicy(.accessory)
        installEditMenu()
        terminateOlderHelperInstances()
        buildPanel()
        buildNotesPanel()
        buildResultCard()
        installMouseMonitors()
        startDisplayServer()
        // Clipboard capture: own store + 0.5s poller, started once the TCP
        // server is up so suspend/resume posts can flow both ways.
        if let store = ClipboardStore.open() {
            clipboardController.attach(store: store)
            ClipboardMonitor.shared.start(store: store)
        } else {
            FileLog.write("CLIP store unavailable — capture disabled")
        }
    }

    private static func argumentValue(_ name: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: name),
              arguments.indices.contains(index + 1) else {
            return nil
        }

        return arguments[index + 1]
    }

    private func terminateOlderHelperInstances() {
        let currentPid = ProcessInfo.processInfo.processIdentifier
        let currentBundleId = Bundle.main.bundleIdentifier

        for application in NSWorkspace.shared.runningApplications {
            guard application.bundleIdentifier == currentBundleId,
                  application.processIdentifier != currentPid else {
                continue
            }

            log("terminating stale helper pid=\(application.processIdentifier)")
            application.terminate()
        }
    }

    private func buildPanel() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: toolbarWidth(for: actions.count), height: toolbarHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.alphaValue = 1
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let (background, content, _) = makePanelBackground(
            frame: panel.contentView?.bounds ?? .zero,
            surface: .bar
        )
        panel.contentView = background
        container = content
        dragHandle = ToolbarDragHandle(frame: NSRect(x: 0, y: 0, width: toolbarHandleWidth, height: toolbarHeight))
        dragHandle.autoresizingMask = [.height]
        dragHandle.theme = theme
        dragHandle.onMouseDown = { [weak self] event in
            self?.panel.performDrag(with: event)
        }
        container.addSubview(dragHandle)
        applyTheme(theme.rawValue)
        applyActions(actions)
    }

    private func installMouseMonitors() {
        let downMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: downMask) { [weak self] event in
            self?.hideIfClickOutsidePanel(event)
            return event
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: downMask) { [weak self] event in
            self?.hideIfClickOutsidePanel(event)
        }

        // The cursor leaving the neighborhood dismisses the bar — the user
        // moved on without clicking (distance scales with screen width,
        // 180–280pt, openclip PopupMetrics.dismissalDistance).
        globalMouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.hideIfCursorFarAway()
        }
        localMouseMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.hideIfCursorFarAway()
            return event
        }

        // Scrolling means the user is reading past the selection.
        globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] _ in
            self?.hidePanel(force: true)
        }

        // Escape closes the bar or the result card. Global key monitoring
        // needs the helper's own Accessibility grant; without it this
        // silently never fires and the other dismissal paths still work.
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { // kVK_Escape
                self?.hidePanel(force: true)
                self?.escapeResultCardIfNeeded()
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { // kVK_Escape
                self?.escapeResultCardIfNeeded()
            }
            if event.keyCode == 48, let self, self.resultPanel != nil, self.resultPanel.isVisible {
                // Tab cycles the card's panel tabs — one source of truth for
                // every page/responder (the old per-responder handlers died on
                // the Review page where no text view owns the key).
                self.cyclePanelTab()
                return nil
            }
            return event
        }
    }

    private func escapeResultCardIfNeeded() {
        guard resultPanel?.isVisible == true, !cardPinned else { return }
        resultPanel.orderOut(nil)
        clearAllRuns(quietly: true)
        postAction(action: "card-hidden", text: "-")
    }

    private func dismissalDistance(for location: NSPoint) -> CGFloat {
        let screenWidth = (NSScreen.screens.first { $0.frame.contains(location) } ?? NSScreen.main)?
            .frame.width ?? 1440
        return max(180, min(screenWidth * 0.12, 280))
    }

    private func hideIfCursorFarAway() {
        guard panel.isVisible else { return }
        let location = NSEvent.mouseLocation
        let dx = location.x - panel.frame.midX
        let dy = location.y - panel.frame.midY
        let distance = (dx * dx + dy * dy).squareRoot()
        let radius = max(panel.frame.width, panel.frame.height) / 2
        if distance > dismissalDistance(for: location) + radius {
            hidePanel(force: true)
        }
    }

    private func applyActions(_ nextActions: [ToolbarAction]) {
        let normalized = nextActions.filter { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        actions = normalized
        buttons.forEach { $0.removeFromSuperview() }
        buttons.removeAll()

        if actions.isEmpty {
            hidePanel(force: true)
            return
        }

        let width = toolbarWidth(for: actions.count)
        container.frame = NSRect(x: 0, y: 0, width: width, height: toolbarHeight)
        panel.setContentSize(NSSize(width: width, height: toolbarHeight))
        dragHandle.frame = NSRect(x: 0, y: 0, width: toolbarHandleWidth, height: toolbarHeight)

        for (index, action) in actions.enumerated() {
            addToolbarButton(action: action, index: index)
        }
    }

    private func addToolbarButton(action: ToolbarAction, index: Int) {
        let button = ToolbarButton(
            frame: NSRect(
                x: toolbarHandleWidth + CGFloat(index) * toolbarSegmentWidth,
                // Inset capsule: 3pt of bar breathing room above and below the
                // highlight, so hover/press never touches the bar's edges.
                y: 3,
                width: toolbarSegmentWidth,
                height: toolbarHeight - 6
            )
        )
        button.autoresizingMask = []
        button.identifier = NSUserInterfaceItemIdentifier(action.id)
        button.toolTip = action.title
        button.image = lucideImage(for: action.icon, title: action.title)
        button.imageScaling = .scaleProportionallyDown
        button.theme = theme
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(runToolbarAction(_:))
        buttons.append(button)
        container.addSubview(button)
    }


    // MARK: - Native Notes panel (Hapigo-style: this panel is a stateless
    // renderer; lexi's event tap owns the list, the selection, and the keys)

    private func buildNotesPanel() {
        notesPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: notesPanelWidth, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        notesPanel.isOpaque = false
        notesPanel.backgroundColor = .clear
        notesPanel.hasShadow = true
        notesPanel.level = .popUpMenu
        notesPanel.hidesOnDeactivate = false
        notesPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let (notesBackground, notesBackgroundContent, _) = makePanelBackground(
            frame: NSRect(x: 0, y: 0, width: notesPanelWidth, height: 200),
            surface: .list
        )
        notesPanel.contentView = notesBackground
        notesContainer = notesBackgroundContent

        notesScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: notesPanelWidth, height: 200))
        notesScrollView.drawsBackground = false
        notesScrollView.hasVerticalScroller = false
        notesScrollView.hasHorizontalScroller = false
        notesContainer.addSubview(notesScrollView)

        // Manual layout (toolbar-style): NSStackView's Auto Layout fights
        // hand-set frames and stacks every row at the same spot.
        notesContent = NSView(frame: NSRect(x: 0, y: 0, width: notesPanelWidth, height: 200))
        notesScrollView.documentView = notesContent
    }

    private func showNotesPanel(_ payload: NotesShowPayload) {
        notesRows.forEach { $0.view.removeFromSuperview() }
        notesRows.removeAll()
        notesContent.subviews.forEach { $0.removeFromSuperview() }
        notesCount = payload.notes.count

        let count = payload.notes.count
        // documentView is bottom-left origin: row 0 sits at the TOP.
        let contentHeight = CGFloat(count) * notesRowHeight
        notesContent.frame = NSRect(x: 0, y: 0, width: notesPanelWidth, height: contentHeight)

        for (index, note) in payload.notes.enumerated() {
            let row = makeNotesRow(index: index, note: note)
            let y = contentHeight - CGFloat(index + 1) * notesRowHeight
            row.view.frame = NSRect(x: 0, y: y, width: notesPanelWidth, height: notesRowHeight)
            notesContent.addSubview(row.view)
            notesRows.append((view: row.view, label: row.label, index: index))
        }

        let visible = CGFloat(min(count, notesMaxVisibleRows))
        let listHeight = visible * notesRowHeight
        let footerHeight: CGFloat = 30
        let height = listHeight + footerHeight
        notesScrollView.frame = NSRect(x: 0, y: footerHeight, width: notesPanelWidth, height: listHeight)
        notesContainer.frame = NSRect(x: 0, y: 0, width: notesPanelWidth, height: height)

        // Footer: jump to the card's manual input (AiForm). Rebuilt on every
        // show because notesContent is cleared above.
        let footer = NSView(frame: NSRect(x: 0, y: 0, width: notesPanelWidth, height: footerHeight))
        footer.wantsLayer = true
        let inputButton = NSButton(title: "Type to translate…", target: self, action: #selector(notesInputTapped))
        inputButton.bezelStyle = .regularSquare
        inputButton.isBordered = false
        inputButton.font = .systemFont(ofSize: 12)
        inputButton.contentTintColor = cardTheme.secondaryText
        inputButton.image = lucideImage(for: "pen", title: "Type to translate")
        inputButton.imageScaling = .scaleProportionallyDown
        inputButton.imagePosition = .imageLeading
        inputButton.frame = NSRect(x: 10, y: 5, width: notesPanelWidth - 20, height: 20)
        footer.addSubview(inputButton)
        let separator = NSView(frame: NSRect(x: 0, y: footerHeight - 0.5, width: notesPanelWidth, height: 0.5))
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        footer.addSubview(separator)
        notesContainer.addSubview(footer)

        let origin = clampedNotesOrigin(width: notesPanelWidth, height: height)
        notesPanel.setFrame(
            NSRect(x: origin.x, y: origin.y, width: notesPanelWidth, height: height),
            display: true
        )
        applyNotesTheme()
        selectNoteRow(payload.selected, scroll: true)
        notesPanel.makeKeyAndOrderFront(nil)
        notesPanel.makeFirstResponder(notesTableView)
        log("notes panel shown rows=\(payload.notes.count)")
    }

    @objc private func notesInputTapped() {
        hideNotesPanel(notifyLexi: true)
        postAction(action: "card-input-mode", text: "-")
    }

    private func clampedNotesOrigin(width: CGFloat, height: CGFloat) -> NSPoint {
        let point = NSEvent.mouseLocation
        var origin = NSPoint(x: point.x - width / 2, y: point.y + 12)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            origin.x = min(max(origin.x, frame.minX + 8), frame.maxX - width - 8)
            origin.y = min(max(origin.y, frame.minY + 8), frame.maxY - height - 8)
        }
        return origin
    }
    private func makeNotesRow(index: Int, note: NotesShowPayload.Note) -> (view: NSView, label: NSTextField) {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: notesPanelWidth, height: notesRowHeight))
        row.wantsLayer = true
        let text = note.name.isEmpty ? note.content : "\(note.name): \(note.content)"
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.wraps = false
        label.frame = NSRect(x: 10, y: (notesRowHeight - 16) / 2, width: notesPanelWidth - 20, height: 16)
        row.addSubview(label)
        let click = NSClickGestureRecognizer(target: self, action: #selector(noteRowClicked(_:)))
        row.addGestureRecognizer(click)
        row.identifier = NSUserInterfaceItemIdentifier("note-\(index)")
        return (row, label)
    }

    /// Row click = select + insert: posted back to lexi, which owns Enter.
    @objc private func noteRowClicked(_ sender: NSClickGestureRecognizer) {
        guard let id = sender.view?.identifier?.rawValue,
              let index = Int(id.dropFirst("note-".count)) else { return }
        postAction(action: "notes-click", text: String(index))
    }

    private func selectNoteRow(_ index: Int, scroll: Bool) {
        notesSelectedIndex = index
        for row in notesRows {
            let selected = row.index == index
            row.view.layer?.backgroundColor = selected
                ? cardTheme.selectedFill.cgColor
                : NSColor.clear.cgColor
            row.label.textColor = selected
                ? cardTheme.foreground
                : (theme == .dark ? NSColor.white.withAlphaComponent(0.9) : NSColor.black.withAlphaComponent(0.85))
        }
        if scroll {
            // Non-flipped document view: scroll origin measures from the bottom,
            // so line up the viewport with the selected row's slot from the top.
            let originY = max(0, contentHeight() - CGFloat(index + 1) * notesRowHeight)
            notesScrollView.contentView.scroll(NSPoint(x: 0, y: originY))
        }
    }

    private func contentHeight() -> CGFloat {
        CGFloat(notesCount) * notesRowHeight
    }

    /// All card chrome tints in ONE place — build AND theme switches run it,
    /// so dark/light flips can never leave stale system colors behind.
    private func restateCardChromeTints() {
        resultCloseButton?.contentTintColor = cardPinned ? cardTheme.foreground : cardTheme.secondaryText
        resultTrashButton?.contentTintColor = cardTheme.secondaryText
        resultCopyButton?.contentTintColor = cardTheme.secondaryText
        resultSaveButton?.contentTintColor = cardTheme.background
        resultIdleIcon?.contentTintColor = cardTheme.foreground
        resultLoadingLabel?.textColor = cardTheme.tertiaryText
        reviewAnswerLabel?.textColor = cardTheme.secondaryText
        reviewEmptyLabel?.textColor = cardTheme.tertiaryText
        entryButtons.forEach { $0.contentTintColor = cardTheme.secondaryText }
    }

    private func applyNotesTheme() {
        restateCardChromeTints()
        let controlStroke = PanelStyle.controlBorder(dark: theme == .dark)
        let appearance = theme == .dark
            ? NSAppearance(named: .vibrantDark)
            : NSAppearance(named: .vibrantLight)
        notesPanel.appearance = appearance

        resultPanel?.appearance = appearance
        if !isInputFocused {
            inputContainer?.layer?.borderColor = controlStroke.cgColor
        }
        if resultPanel != nil {
            rebuildRunTabs()
            renderActiveRun()
            layoutResultCard()
        }
    }

    private var isInputFocused = false

    private func setInputFocused(_ focused: Bool) {
        isInputFocused = focused
        styleCardInputs(focused: focused ? .actions : .none)
    }

    /// Both card inputs (Actions bar + Notes search) share ONE surface
    /// definition: same fill, hairline, radius, placeholder tint. Focus
    /// (per field) deepens the border.
    private enum CardInputFocus { case none, actions, search }

    private func styleCardInputs(focused: CardInputFocus = .none) {
        let surface = cardTheme.inputFill.cgColor
        let hairline = cardTheme.hairline.cgColor
        let focusTint = cardTheme.foreground.withAlphaComponent(0.45).cgColor
        let border: (CardInputFocus) -> CGColor = { focus in
            focus == .none ? hairline : focusTint
        }
        for (container, focus) in [(inputContainer, CardInputFocus.actions), (noteSearchContainer, CardInputFocus.search)] {
            container?.layer?.backgroundColor = surface
            container?.layer?.borderColor = border(focus == .none || focus == focused ? focused : .none)
            container?.layer?.cornerRadius = 8
            container?.layer?.borderWidth = 1
        }
        inputTextView?.placeholder = NSAttributedString(
            string: "Enter text",
            attributes: [.foregroundColor: cardTheme.tertiaryText, .font: NSFont.systemFont(ofSize: 13)]
        )
    }
    // MARK: - Native result card (WebView parity): AiForm input bar,
    // multi-run tabs, loading/streaming/ready/error states, EntryTypeTags,
    // Copy/Save — rendered in AppKit, streamed from Rust. The card is never
    // key unless clicked into (typing intent), and drags by its background.

    private func buildResultCard() {
        resultPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: resultCardWidth, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        resultPanel.isOpaque = false
        resultPanel.backgroundColor = .clear
        resultPanel.hasShadow = true
        resultPanel.level = .popUpMenu
        resultPanel.hidesOnDeactivate = false
        resultPanel.isMovableByWindowBackground = true
        resultPanel.acceptsMouseMovedEvents = true
        resultPanel.delegate = self
        resultPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let (resultBackground, resultContent, isGlass) = makePanelBackground(
            frame: NSRect(x: 0, y: 0, width: resultCardWidth, height: 240),
            surface: .card
        )
        resultContainer = resultContent
        if isGlass {
            // Glass draws its own rounded shape — no clip wrapper needed.
            resultPanel.contentView = resultBackground
        } else {
            // Legacy: the vibrancy material draws past manual corner radii —
            // wrap and mask so only the rounded card shows (grey-rounded +
            // white-squared double edge fix).
            let clip = NSView(frame: NSRect(x: 0, y: 0, width: resultCardWidth, height: 240))
            clip.wantsLayer = true
            clip.layer?.cornerRadius = 12
            clip.layer?.masksToBounds = true
            resultPanel.contentView = clip
            clip.addSubview(resultBackground)
        }

        // Panel tab strip (top): panel switcher (Actions/Notes/Review, the
        // Panel Config list) + close. WebView FloatingFrame parity.
        resultTabsView = NSView(frame: NSRect(x: 0, y: 210, width: resultCardWidth, height: 32))
        resultContainer.addSubview(resultTabsView)

        cardPanelTabsView = NSView(frame: NSRect(x: 12, y: 4, width: resultCardWidth - 24 - 28, height: 28))
        resultTabsView.addSubview(cardPanelTabsView)

        panelTabsControl = NSSegmentedControl()
        panelTabsControl.isHidden = true // replaced by the goty tab pills
        cardPanelTabsView.addSubview(panelTabsControl)
        buildPanelTabPills()

        // Pin toggle (WebView FloatingFrame parity): unpinned = dismisses on
        // outside click / Esc; pinned = stays. Replaces the close button —
        // closing happens by unpinning, then clicking away.
        resultCloseButton = NSButton(title: "", target: self, action: #selector(pinToggled))
        resultCloseButton.bezelStyle = .regularSquare
        resultCloseButton.isBordered = false
        resultCloseButton.image = lucideImage(for: "pin-off", title: "Pin")
        resultCloseButton.imageScaling = .scaleProportionallyDown
        resultCloseButton.contentTintColor = cardTheme.secondaryText
        resultCloseButton.toolTip = "Pin"
        resultCloseButton.frame = NSRect(x: resultCardWidth - 30, y: 7, width: 20, height: 20)
        resultTabsView.addSubview(resultCloseButton)
        resultRunsBar = NSView(frame: NSRect(x: 0, y: 180, width: resultCardWidth, height: 28))
        resultContainer.addSubview(resultRunsBar)

        resultTabsClip = HorizontalOnlyClip(frame: NSRect(x: 8, y: 0, width: resultCardWidth - 84, height: 28))
        resultTabsClip.drawsBackground = false
        resultTabsClip.hasVerticalScroller = false
        resultTabsClip.hasHorizontalScroller = false
        resultTabsClip.autohidesScrollers = true
        let runsDoc = NSView(frame: NSRect(x: 0, y: 0, width: resultCardWidth - 84, height: 28))
        resultTabsClip.documentView = runsDoc
        resultTabsClip.verticalForward = resultScrollView
        resultRunsBar.addSubview(resultTabsClip)

        runsSeparator = NSView(frame: .zero)
        runsSeparator.isHidden = true
        resultContainer.addSubview(runsSeparator)

        resultTrashButton = NSButton(title: "", target: self, action: #selector(clearRunsClicked))
        resultTrashButton.bezelStyle = .regularSquare
        resultTrashButton.isBordered = false
        resultTrashButton.image = lucideImage(for: "x", title: "Close all results")
        resultTrashButton.imageScaling = .scaleProportionallyDown
        resultTrashButton.toolTip = "Close all results"
        resultTrashButton.contentTintColor = cardTheme.secondaryText
        resultTrashButton.frame = NSRect(x: resultCardWidth - 34, y: 7, width: 20, height: 20)
        resultContainer.addSubview(resultTrashButton) // top level: can never be overdrawn

        // Content: markdown text + loading spinner + idle hint.
        resultScrollView = NSScrollView(frame: NSRect(x: 0, y: 70, width: resultCardWidth, height: 130))
        resultScrollView.drawsBackground = false
        resultScrollView.hasVerticalScroller = true
        resultScrollView.autohidesScrollers = true
        resultScrollView.scrollerStyle = .overlay
        resultContainer.addSubview(resultScrollView)

        resultTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: resultCardWidth, height: 130))
        resultTextView.isEditable = false
        resultTextView.drawsBackground = false
        resultTextView.textContainerInset = NSSize(width: 14, height: 10)
        resultTextView.isVerticallyResizable = true
        resultTextView.autoresizingMask = [.width]
        resultTextView.textContainer?.lineFragmentPadding = 0
        resultScrollView.documentView = resultTextView

        // Layer spinner: NSProgressIndicator freezes on windows that are not
        // key; a CABasicAnimation rotation is driven by the render server and
        // always spins.
        resultLoadingIndicator = NSProgressIndicator(frame: NSRect(x: 14, y: 100, width: 16, height: 16))
        (resultLoadingIndicator as! NSProgressIndicator).controlSize = .small
        (resultLoadingIndicator as! NSProgressIndicator).style = .spinning
        resultContainer.addSubview(resultLoadingIndicator)

        resultLoadingLabel = NSTextField(labelWithString: "Running...")
        resultLoadingLabel.font = .systemFont(ofSize: 13)
        resultLoadingLabel.textColor = cardTheme.tertiaryText
        resultLoadingLabel.frame = NSRect(x: 36, y: 100, width: 200, height: 18)
        resultContainer.addSubview(resultLoadingLabel)

        // Translate tab's idle placeholder — a content-area view exactly like
        // cardNotesClip (notes) and reviewCardView (review): switching tabs
        // hides it wholesale, no per-control isHidden bookkeeping.
        translateIdleView = NSView(frame: NSRect(x: 0, y: 70, width: resultCardWidth, height: 130))
        translateIdleView.isHidden = true
        resultContainer.addSubview(translateIdleView)

        resultIdleIcon = NSImageView(frame: NSRect(x: resultCardWidth / 2 - 8, y: 32, width: 16, height: 16))
        resultIdleIcon.image = lucideImage(for: "sparkles", title: "Idle")
        resultIdleIcon.contentTintColor = cardTheme.foreground
        resultIdleIcon.imageScaling = .scaleProportionallyDown
        translateIdleView.addSubview(resultIdleIcon)

        resultIdleLabel = NSTextField(labelWithString: "Enter text, then choose an action.")
        resultIdleLabel.font = .systemFont(ofSize: 13)
        resultIdleLabel.textColor = cardTheme.secondaryText
        resultIdleLabel.alignment = .center
        resultIdleLabel.frame = NSRect(x: 10, y: 26, width: resultCardWidth - 20, height: 18)
        translateIdleView.addSubview(resultIdleLabel)

        resultIdleHint = NSTextField(labelWithString: "⏎ Run default")
        resultIdleHint.font = .systemFont(ofSize: 11)
        resultIdleHint.textColor = cardTheme.tertiaryText
        resultIdleHint.alignment = .center

        resultIdleHint.frame = NSRect(x: 10, y: 6, width: resultCardWidth - 20, height: 14)
        translateIdleView.addSubview(resultIdleHint)

        // Action bar: EntryTypeTags + Copy + Save (ready runs).
        resultActionBar = NSView(frame: NSRect(x: 10, y: 36, width: resultCardWidth - 20, height: 32))
        resultContainer.addSubview(resultActionBar)

        resultEntryBar = NSView(frame: NSRect(x: 0, y: 0, width: 170, height: 28))
        resultEntryBar.wantsLayer = true
        resultEntryBar.layer?.cornerRadius = 6
        resultEntryBar.layer?.borderWidth = 0.5
        resultActionBar.addSubview(resultEntryBar)
        for (index, title) in ["Word", "Phrase", "Pattern"].enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(entryTypeClicked(_:)))
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.font = .systemFont(ofSize: 10, weight: .medium)
            button.tag = index
            button.frame = NSRect(x: CGFloat(index) * 56 + 2, y: 2, width: 52, height: 22)
            resultEntryBar.addSubview(button)
            entryButtons.append(button)
        }

        resultCopyButton = NSButton(title: "", target: self, action: #selector(copyResultClicked))
        resultCopyButton.bezelStyle = .regularSquare
        resultCopyButton.isBordered = false
        resultCopyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy result")
        resultCopyButton.imageScaling = .scaleProportionallyDown
        resultCopyButton.contentTintColor = cardTheme.secondaryText
        resultCopyButton.toolTip = "Copy result"
        resultCopyButton.frame = NSRect(x: resultCardWidth - 190, y: 2, width: 26, height: 26)
        resultActionBar.addSubview(resultCopyButton)

        resultSaveButton = NSButton(title: "Save", target: self, action: #selector(saveResultClicked))
        resultSaveButton.bezelStyle = .regularSquare
        resultSaveButton.isBordered = false
        resultSaveButton.font = .systemFont(ofSize: 12, weight: .medium)
        resultSaveButton.wantsLayer = true
        resultSaveButton.layer?.cornerRadius = 6
        resultSaveButton.contentTintColor = cardTheme.background
        resultSaveButton.frame = NSRect(x: resultCardWidth - 158, y: 4, width: 148, height: 24)
        resultActionBar.addSubview(resultSaveButton)

        // Input bar (WebView AiForm parity): single-line keeps the action
        // buttons on the text row; multi-line moves them to a row below and
        // gives the text the full width.
        inputContainer = NSView(frame: NSRect(x: 10, y: 10, width: resultCardWidth - 20, height: 36))
        inputContainer.wantsLayer = true
        inputContainer.layer?.cornerRadius = 8
        inputContainer.layer?.borderWidth = 1
        resultContainer.addSubview(inputContainer)

        inputTextView = CardInputTextView(frame: NSRect(x: 6, y: 4, width: resultCardWidth - 32 - 90, height: 26))
        inputTextView.font = .systemFont(ofSize: 13)
        inputTextView.drawsBackground = false
        inputTextView.isRichText = false
        inputTextView.isAutomaticQuoteSubstitutionEnabled = false
        inputTextView.isAutomaticDashSubstitutionEnabled = false
        inputTextView.delegate = self
        inputTextView.onBecameFocus = { [weak self] in
            self?.postAction(action: "card-key", text: "1")
            self?.setInputFocused(true)
        }
        inputTextView.onLostFocus = { [weak self] in
            self?.setInputFocused(false)
        }
        inputTextView.textContainer?.lineFragmentPadding = 0
        inputTextView.placeholder = NSAttributedString(
            string: "Enter text",
            attributes: [.foregroundColor: cardTheme.tertiaryText, .font: NSFont.systemFont(ofSize: 13)]
        )
        inputContainer.addSubview(inputTextView)

        inputButtonsRow = NSView(frame: NSRect(x: 0, y: 0, width: 90, height: 28))
        inputButtonsClip = HorizontalOnlyClip(frame: NSRect(x: 0, y: 0, width: 90, height: 28))
        inputButtonsClip.drawsBackground = false
        inputButtonsClip.hasVerticalScroller = false
        inputButtonsClip.hasHorizontalScroller = false
        inputButtonsClip.autohidesScrollers = true
        inputButtonsClip.contentView.automaticallyAdjustsContentInsets = false
        inputButtonsClip.documentView = inputButtonsRow
        inputButtonsClip.verticalForward = resultScrollView
        inputContainer.addSubview(inputButtonsClip)

        // Notes tab: browsable note rows (click = copy).
        cardNotesClip = HorizontalOnlyClip(frame: NSRect(x: 0, y: 0, width: resultCardWidth, height: 200))
        cardNotesClip.drawsBackground = false
        cardNotesClip.allowsVertical = true
        cardNotesClip.hasVerticalScroller = true
        cardNotesClip.autohidesScrollers = true
        cardNotesClip.scrollerStyle = .overlay
        notesTableView = NotesTable(frame: NSRect(x: 0, y: 0, width: resultCardWidth, height: 200))
        notesTableView.onDoubleClickRow = { [weak self] row in
            guard let self, row >= 0, row < self.displayedNotes.count else { return }
            if let cell = self.notesTableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NoteRowCell {
                cell.beginRenaming()
            }
        }
        notesTableView.onEnterKey = { [weak self] in
            guard let self, self.notesTableView.selectedRow >= 0 else { return }
            // Injects by note id: the visible list is filtered, so display
            // indexes must never cross into the Rust snapshot.
            let row = self.notesTableView.selectedRow
            guard row >= 0, row < self.displayedNotes.count,
                  let id = self.displayedNotes[row].id else { return }
            self.postAction(action: "notes-click", text: String(id))
        }
        notesTableView.headerView = nil
        notesTableView.rowHeight = 40
        notesTableView.intercellSpacing = .zero
        notesTableView.style = .fullWidth
        notesTableView.selectionHighlightStyle = .none
        notesTableView.backgroundColor = .clear
        notesTableView.usesAutomaticRowHeights = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("note"))
        column.resizingMask = .autoresizingMask
        notesTableView.addTableColumn(column)
        notesTableView.dataSource = self
        notesTableView.delegate = self
        notesTableView.target = self
        notesTableView.doubleAction = nil
        notesTableView.action = #selector(notesTableClicked(_:))
        notesTableView.sizeLastColumnToFit()
        NotificationCenter.default.addObserver(
            self, selector: #selector(notesClipScrolled),
            name: NSView.boundsDidChangeNotification, object: cardNotesClip.contentView
        )
        cardNotesClip.documentView = notesTableView
        resultContainer.addSubview(cardNotesClip)

        // Notes toolbar: live title search + tag filter chips. The search
        // surface IS the Actions input component: container + CardInputTextView
        // + overlay placeholder — identical construction, one language.
        noteSearchContainer = NSView(frame: .zero)
        noteSearchContainer.wantsLayer = true
        noteSearchContainer.layer?.cornerRadius = 8
        noteSearchContainer.layer?.borderWidth = 1
        resultContainer.addSubview(noteSearchContainer)

        noteSearchField = CardInputTextField(frame: .zero)
        let searchCell = VerticallyCenteredTextFieldCell()
        searchCell.stringValue = "" // bare NSTextFieldCell ships titled "Field"
        searchCell.isEditable = true
        searchCell.placeholderString = "Search notes"
        noteSearchField.cell = searchCell
        noteSearchField.font = .systemFont(ofSize: 13)
        noteSearchField.textColor = cardTheme.foreground
        noteSearchField.backgroundColor = .clear
        noteSearchField.drawsBackground = false
        noteSearchField.isBordered = false
        noteSearchField.focusRingType = .none
        noteSearchField.delegate = self
        noteSearchField.onBecameFocus = { [weak self] in
            self?.styleCardInputs(focused: .search)
        }
        noteSearchField.onLostFocus = { [weak self] in
            self?.styleCardInputs(focused: .none)
        }
        noteSearchContainer.addSubview(noteSearchField)

        noteTagBar = NSView(frame: .zero)
        resultContainer.addSubview(noteTagBar)

        // Review tab: word card + reveal + SM-2 grade buttons.
        reviewCardView = NSView(frame: NSRect(x: 0, y: 0, width: resultCardWidth, height: 200))
        resultContainer.addSubview(reviewCardView)

        reviewWordLabel = NSTextField(labelWithString: "")
        reviewWordLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        reviewWordLabel.alignment = .center
        reviewWordLabel.frame = NSRect(x: 10, y: 120, width: resultCardWidth - 20, height: 28)
        reviewCardView.addSubview(reviewWordLabel)

        reviewAnswerLabel = NSTextField(labelWithString: "")
        reviewAnswerLabel.font = .systemFont(ofSize: 14)
        reviewAnswerLabel.textColor = cardTheme.secondaryText
        reviewAnswerLabel.alignment = .center
        reviewAnswerLabel.lineBreakMode = .byTruncatingTail
        reviewAnswerLabel.frame = NSRect(x: 20, y: 88, width: resultCardWidth - 40, height: 18)
        reviewCardView.addSubview(reviewAnswerLabel)

        reviewRevealButton = NSButton(title: "Reveal", target: self, action: #selector(revealReviewClicked))
        reviewRevealButton.bezelStyle = .rounded
        reviewRevealButton.controlSize = .regular
        reviewRevealButton.frame = NSRect(x: resultCardWidth / 2 - 40, y: 48, width: 80, height: 24)
        reviewCardView.addSubview(reviewRevealButton)

        for (index, title) in ["Again", "Hard", "Good", "Easy"].enumerated() {
            let grade = NSButton(title: title, target: self, action: #selector(gradeClicked(_:)))
            grade.bezelStyle = .rounded
            grade.controlSize = .small
            grade.tag = index
            grade.isEnabled = false
            grade.alphaValue = 0.4
            grade.frame = NSRect(x: 20 + CGFloat(index) * 98, y: 12, width: 88, height: 26)
            reviewCardView.addSubview(grade)
            reviewGradeButtons.append(grade)
        }

        let makeZone: (CardResizeZone.Edge, NSRect) -> CardResizeZone = { [weak self] edge, frame in
            let zone = CardResizeZone(edge: edge, frame: frame)
            zone.onResize = { [weak self] width, height in
                guard let self else { return }
                if let width { self.cardUserWidth = (min(max(width, 360), 760)).rounded() }
                if let height { self.cardUserHeight = (min(max(height, 240), 900)).rounded() }
                self.layoutResultCard()
            }
            zone.onReset = { [weak self] in
                self?.cardUserWidth = nil
                self?.cardUserHeight = nil
                self?.layoutResultCard()
            }
            return zone
        }
        resizeCorner = makeZone(.corner, NSRect(x: resultCardWidth - 16, y: 0, width: 16, height: 16))
        resizeRight = makeZone(.right, NSRect(x: resultCardWidth - 4, y: 16, width: 4, height: 180))
        resizeBottom = makeZone(.bottom, NSRect(x: 0, y: 0, width: resultCardWidth - 16, height: 4))
        resultContainer.addSubview(resizeCorner)
        resultContainer.addSubview(resizeRight)
        resultContainer.addSubview(resizeBottom)

        reviewEmptyLabel = NSTextField(labelWithString: "No words due for review.")
        reviewEmptyLabel.font = .systemFont(ofSize: 13)
        reviewEmptyLabel.textColor = cardTheme.tertiaryText
        reviewEmptyLabel.alignment = .center
        reviewEmptyLabel.frame = NSRect(x: 10, y: 90, width: resultCardWidth - 20, height: 18)
        reviewCardView.addSubview(reviewEmptyLabel)
    }

    private var activeRun: CardRun? {
        cardRuns.first { $0.id == activeRunId } ?? cardRuns.last
    }

    func showResultCard(_ payload: ResultShowPayload) {
        // Every run trigger funnels here (Rust surface events, toolbar
        // buttons, the input bar): the card presents and the AI stream
        // starts locally from the shared DB.
        var payload = payload
        var feature: LexiAIFeature?
        if let featureId = payload.featureId, !featureId.isEmpty {
            feature = LexiStore.aiFeature(id: featureId)
            if payload.title?.isEmpty != false, let row = feature {
                payload.title = row.name
                payload.icon = row.icon
            }
        }
        if let runId = payload.runId, !runId.isEmpty {
            let run = CardRun(
                id: runId,
                featureId: payload.featureId ?? "",
                title: payload.title?.isEmpty == false ? payload.title! : "AI",
                icon: payload.icon?.isEmpty == false ? payload.icon! : "wand"
            )
            cardRuns.append(run)
            activeRunId = runId
        } else {
            // Idle invocation: fresh session, no runs.
            cardRuns.removeAll()
            activeRunId = nil
        }
        // New runs always surface on the Actions panel.
        activePanel = "translate"
        if let input = payload.inputText, !input.isEmpty {
            inputTextView.string = input
            rebuildInputButtons()
        }
        log("card shown runs=\(cardRuns.count)")
        layoutResultCard()
        rebuildRunTabs()
        rebuildInputButtons()
        renderActiveRun()
        layoutResultCard()
        if !resultPanel.isVisible {
            placeResultCard()
            if !reduceMotion, let layer = resultPanel.contentView?.layer {
                resultPanel.alphaValue = 0
                let rise = CABasicAnimation(keyPath: "transform.translation.y")
                rise.fromValue = 6
                rise.toValue = 0
                rise.duration = 0.22
                rise.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(rise, forKey: "materialize")
                resultPanel.makeKeyAndOrderFront(nil)
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.22
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    resultPanel.animator().alphaValue = 1
                })
            } else {
                resultPanel.alphaValue = 0
                resultPanel.makeKeyAndOrderFront(nil)
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.15
                    resultPanel.animator().alphaValue = 1
                })
            }
        }
        applyNotesTheme()
        // WebView parity: the selected text lands in the input bar,
        // editable for a follow-up run.
        // The run starts here for every trigger path — Rust only asks for
        // the card; the helper owns the stream.
        if let runId = payload.runId, !runId.isEmpty, let feature {
            Task { [weak self] in
                await self?.streamRun(runId: runId, feature: feature, text: payload.inputText ?? "")
            }
        }
    }

    private func handleCardActions(_ payload: CardActionsPayload) {
        cardActions = payload.actions
        panelDefs = (payload.panels ?? []).map { ($0.id, $0.name, $0.icon) }
        if !panelDefs.isEmpty, panelTabPills != nil {
            buildPanelTabPills()
        }
        if panelDefs.isEmpty {
            panelDefs = [("translate", "Actions", "file-text"), ("review", "Review", "book-open")]
        }
        rebuildInputButtons()
        layoutResultCard()
    }

    @objc private func panelTabClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        showPanelTab(id)
    }

    private func applyNoteFilters() {
        let query = noteSearchText.trimmingCharacters(in: .whitespaces).lowercased()
        displayedNotes = cardNotesItems.filter { note in
            let title = (note.name.isEmpty ? note.content : note.name).lowercased()
            let matchesQuery = query.isEmpty || title.contains(query)
            let matchesTag = noteActiveTag == "all" || (note.tags ?? []).contains(noteActiveTag)
            return matchesQuery && matchesTag
        }
        notesTableView.reloadData()
        if !displayedNotes.isEmpty {
            notesTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        layoutResultCard()
    }

    private func rebuildNoteTagBar() {
        noteTagButtons.forEach { $0.removeFromSuperview() }
        noteTagButtons.removeAll()
        var tags = Set<String>()
        for note in cardNotesItems {
            (note.tags ?? []).forEach { tags.insert($0) }
        }
        for name in ["all"] + tags.sorted() {
            let button = NSButton(title: name.capitalized, target: self, action: #selector(noteTagClicked(_:)))
            button.isBordered = false
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.bezelStyle = .texturedRounded
            button.toolTip = name == "all" ? "All notes" : "Filter: \(name)"
            button.identifier = NSUserInterfaceItemIdentifier(name)
            noteTagBar.addSubview(button)
            noteTagButtons.append(button)
        }
        styleNoteTagButtons()
        layoutResultCard()
    }

    private func layoutNoteTagButtons() {
        var x: CGFloat = 0
        for button in noteTagButtons {
            button.sizeToFit()
            let w = max(button.frame.width + 18, 40)
            button.frame = NSRect(x: x, y: 2, width: w, height: 20)
            x += w + 6
        }
    }

    private func styleNoteTagButtons() {
        for button in noteTagButtons {
            let active = button.identifier?.rawValue == noteActiveTag
            button.contentTintColor = active ? cardTheme.foreground : cardTheme.secondaryText
            button.layer?.backgroundColor = active
                ? cardTheme.selectedFill.cgColor
                : NSColor.clear.cgColor
            button.wantsLayer = true
            button.layer?.cornerRadius = 9
        }
    }

    @objc private func noteTagClicked(_ sender: NSButton) {
        noteActiveTag = sender.identifier?.rawValue ?? "all"
        styleNoteTagButtons()
        applyNoteFilters()
    }

    private var panelTabPills: [NSButton] = []

    /// goty tab language: icon+label pills, active on the same-hue selected
    /// wash with full-radius caps, quiet otherwise.
    private func buildPanelTabPills() {
        panelTabPills.forEach { $0.removeFromSuperview() }
        panelTabPills.removeAll()
        for def in panelDefs {
            let button = NSButton(title: "", target: self, action: #selector(panelTabClicked(_:)))
            button.isBordered = false
            button.toolTip = def.name
            button.identifier = NSUserInterfaceItemIdentifier(def.id)
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.attributedTitle = tabPillTitle(def)
            cardPanelTabsView.addSubview(button)
            panelTabPills.append(button)
        }
        layoutPanelTabPills()
        stylePanelTabPills()
    }

    /// Icon + label as one attributed title: exact padding (8pt leading,
    /// 4pt gap) — NSButton's imageLeading spacing is untamable.
    private func tabPillTitle(_ def: (id: String, name: String, icon: String), active: Bool = false) -> NSAttributedString {
        let title = NSMutableAttributedString(string: " ")
        if let icon = lucideImage(for: def.icon, title: def.name,
                                  color: active ? cardTheme.foreground : cardTheme.secondaryText) {
            icon.size = NSSize(width: 12, height: 12)
            let attachment = NSTextAttachment()
            attachment.image = icon
            // Center the glyph on the label's optical middle (cap height),
            // not on the baseline where attachments sit by default.
            let font = NSFont.systemFont(ofSize: 12, weight: .medium)
            attachment.bounds = NSRect(
                x: 0, y: (font.capHeight - 12) / 2,
                width: 12, height: 12
            )
            title.append(NSAttributedString(attachment: attachment))
        }
        title.append(NSAttributedString(string: "  \(def.name)", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: active ? cardTheme.foreground : cardTheme.secondaryText,
        ]))
        return title
    }

    private func layoutPanelTabPills() {
        panelTabPills.forEach { $0.sizeToFit() }
        // ONE width for every pill — the tab strip reads as a set, not as
        // three differently-sized leftovers.
        let w = max(panelTabPills.map { $0.frame.width + 20 }.max() ?? 60, 60)
        let total = CGFloat(panelTabPills.count) * w + CGFloat(max(panelTabPills.count - 1, 0)) * 6
        var x = max((cardPanelTabsView.bounds.width - total) / 2, 0)
        for pill in panelTabPills {
            pill.frame = NSRect(x: x, y: 2, width: w, height: 26)
            x += w + 6
        }
    }

    private func stylePanelTabPills() {
        for pill in panelTabPills {
            let def = panelDefs.first { $0.id == pill.identifier?.rawValue }
            let active = pill.identifier?.rawValue == activePanel
            // INVERTED active pill: foreground surface, background-colored
            // glyphs — contrast the quiet wash could never deliver.
            pill.attributedTitle = def.map { tabPillTitle($0, active: active) } ?? pill.attributedTitle
            // Template attachments tint through the button; the attributed
            // text carries its own color — both must agree.
            pill.contentTintColor = active ? cardTheme.foreground : cardTheme.secondaryText
            pill.layer?.backgroundColor = active
                ? cardTheme.selectedFill.cgColor
                : NSColor.clear.cgColor
        }
    }

    private func cyclePanelTab() {
        let ids = panelDefs.map { $0.id }
        guard !ids.isEmpty, let current = ids.firstIndex(of: activePanel) else { return }
        showPanelTab(ids[(current + 1) % ids.count])
    }

    private func showPanelTab(_ id: String, notify: Bool = true) {
        activePanel = id
        if panelTabPills != nil {
            stylePanelTabPills()
        }
        rebuildRunTabs()
        renderActiveRun()
        layoutResultCard()
        // Translate page = the input is the point: hand it first responder
        // (webview parity — the AiForm autofocused). Without this, a table
        // that was first responder on the Notes tab leaves the window with
        // no text target and every keystroke beeps.
        DispatchQueue.main.async {
            switch id {
            case "translate":
                self.inputTextView.window?.makeFirstResponder(self.inputTextView)
            case "notes":
                self.notesTableView.window?.makeFirstResponder(self.notesTableView)
            default:
                break
            }
        }
        guard notify else { return }
        if id == "notes" {
            postAction(action: "panel-notes", text: "-")
        } else if id == "review" {
            postAction(action: "panel-review", text: "-")
        }
    }

    private var cardAllTags: [String] = []

    private func handleCardNotes(_ payload: CardNotesPayload) {
        cardAllTags = payload.allTags ?? []
        cardNotesItems = payload.notes
        notesTableView.reloadData()
        notesTableView.sizeLastColumnToFit()
        if !cardNotesItems.isEmpty {
            notesTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            notesTableView.scrollRowToVisible(0)
        }
        rebuildNoteTagBar()
        applyNoteFilters()
        FileLog.write("NOTES loaded count=\(cardNotesItems.count) allTags=\(cardAllTags.count) selected=\(notesTableView.selectedRow) clipHidden=\(cardNotesClip.isHidden)")
        layoutResultCard()
        FileLog.write("NOTES post-layout selected=\(notesTableView.selectedRow) clipHidden=\(cardNotesClip.isHidden) panel=\(activePanel)")
    }

    /// Mouse click on a row: select it (selectionDidChange copies the
    /// content) and arm the card for Enter. Injection happens on Enter only.
    @objc private func notesTableClicked(_ sender: NSTableView) {
        FileLog.write("SEL clicked row=\(sender.clickedRow)")
        postAction(action: "card-key", text: "1")
    }

    @objc private func noteInsertClicked(_ sender: NSButton) {
        guard let content = sender.identifier?.rawValue, !content.isEmpty else { return }
        postAction(action: "note-insert", text: content)
        resultPanel.orderOut(nil)
        postAction(action: "card-hidden", text: "-")
    }

    // MARK: - Tag dropdown (in-card, goty language)
    // The system NSMenu misplaces itself on a nonactivating panel - the tag
    // picker is an in-card dropdown layer instead: same material, opens at
    // the pill, click-outside/Esc closes, picking posts note-tag.

    private var tagDropdown: TagDropdownView?
    private var tagDropdownMonitor: Any?

    private func showTagMenu(noteId: Int64, tag: String?, anchor: NSView) {
        guard noteId != 0,
              let host = resultPanel.contentView else { return }
        closeTagDropdown()

        let allTags = cardAllTags.isEmpty
            ? Array(Set(cardNotesItems.flatMap { $0.tags ?? [] })).sorted()
            : cardAllTags
        let dropdown = TagDropdownView(
            tags: allTags,
            current: tag,
            theme: cardTheme,
            onPick: { [weak self] name in
                self?.closeTagDropdown()
                self?.postAction(action: "note-tag", text: "\(noteId)|\(name ?? "")")
            }
        )
        let pillRect = anchor.convert(anchor.bounds, to: host)
        dropdown.sizeToFit(width: dropdown.naturalWidth)
        var origin = NSPoint(x: min(pillRect.minX, host.bounds.width - dropdown.frame.width - 8), y: pillRect.minY - dropdown.frame.height - 4)
        if origin.y < 8 {
            origin.y = pillRect.maxY + 4
        }
        dropdown.frame.origin = origin
        host.addSubview(dropdown)
        tagDropdown = dropdown

        tagDropdownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.closeTagDropdown()
                return nil
            }
            if event.type != .keyDown {
                let location = event.locationInWindow
                let inDropdown = self.tagDropdown.map {
                    $0.convert($0.bounds, to: nil).contains(location)
                } ?? false
                if !inDropdown {
                    self.closeTagDropdown()
                }
            }
            return event
        }
    }

    private func closeTagDropdown() {
        tagDropdown?.removeFromSuperview()
        tagDropdown = nil
        if let tagDropdownMonitor {
            NSEvent.removeMonitor(tagDropdownMonitor)
            self.tagDropdownMonitor = nil
        }
    }

    private func noteDeleteClickedId(_ id: Int64) {
        postAction(action: "note-delete", text: String(id))
    }

    private func noteRenamed(id: Int64, name: String) {
        let payload: [String: Any] = ["id": id, "name": name]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let body = String(data: data, encoding: .utf8) else { return }
        postAction(action: "note-rename", text: body)
    }

    @objc private func noteDeleteClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        postAction(action: "note-delete", text: id)
    }

    private func handleCardReview(_ payload: CardReviewPayload) {
        guard let word = payload.word else {
            reviewEmptyLabel.isHidden = false
            reviewWordLabel.stringValue = ""
            reviewAnswerLabel.stringValue = ""
            reviewRevealButton.isHidden = true
            reviewGradeButtons.forEach { $0.isEnabled = false; $0.alphaValue = 0.4 }
            reviewCurrentWordId = 0
            layoutResultCard()
            return
        }
        reviewEmptyLabel.isHidden = true
        reviewRevealButton.isHidden = false
        reviewCurrentWordId = word.id
        reviewWordLabel.stringValue = word.word
        reviewAnswerLabel.stringValue = ""
        reviewRevealButton.isEnabled = true
        reviewRevealButton.title = "Reveal"
        reviewGradeButtons.forEach { $0.isEnabled = false; $0.alphaValue = 0.4 }
        reviewAnswerLabel.toolTip = word.translation
        layoutResultCard()
    }

    @objc private func revealReviewClicked() {
        guard reviewCurrentWordId != 0 else { return }
        reviewAnswerLabel.stringValue = reviewAnswerLabel.toolTip ?? ""
        reviewRevealButton.isEnabled = false
        reviewGradeButtons.forEach { $0.isEnabled = true; $0.alphaValue = 1 }
    }

    @objc private func gradeClicked(_ sender: NSButton) {
        let ratings = ["again", "hard", "good", "easy"]
        let payload: [String: Any] = ["id": reviewCurrentWordId, "rating": ratings[sender.tag]]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let body = String(data: data, encoding: .utf8) else { return }
        reviewGradeButtons.forEach { $0.isEnabled = false; $0.alphaValue = 0.4 }
        postAction(action: "review-grade", text: body)
    }

    func handleResultEvent(_ payload: ResultEventPayload) {
        let runId = payload.runId?.isEmpty == false ? payload.runId! : activeRunId
        guard let run = cardRuns.first(where: { $0.id == runId }) ?? activeRun else { return }

        if let error = payload.error {
            run.status = "error"
            run.text = error
        } else if payload.done {
            run.text = payload.chunk ?? run.text
            run.status = "ready"
            if let json = payload.translationJson {
                run.translationJson = json
                run.entryType = inferredEntryType(for: jsonStringField(json, "word") ?? run.title)
            }
            if payload.saved == true {
                run.saved = true
            }
        } else if let chunk = payload.chunk {
            run.text += chunk
            run.status = "streaming"
        }

        // Unconditional: the event mutated a run; re-render active state.
        renderActiveRun()
        layoutResultCard()
    }

    /// Accessory apps ship without a menu bar, which silently kills the
    /// standard text key equivalents (Cmd+C/V/X/A) in every text view. A
    /// minimal Edit submenu restores the system behavior — no per-key
    /// monitors, no custom handling.
    private func installEditMenu() {
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut",
                         action: #selector(NSText.cut(_:)),
                         keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",
                         action: #selector(NSText.copy(_:)),
                         keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",
                         action: #selector(NSText.paste(_:)),
                         keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)),
                         keyEquivalent: "a")
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    private func spinnerStart() {
        resultLoadingIndicator.isHidden = false
        (resultLoadingIndicator as? NSProgressIndicator)?.startAnimation(nil)
    }

    private func spinnerStop() {
        (resultLoadingIndicator as? NSProgressIndicator)?.stopAnimation(nil)
    }

    /// Re-render the active run's content area (loading / streaming / error /
    /// ready) and the action bar state.
    private func renderActiveRun() {
        let run = activeRun
        let status = run?.status

        resultLoadingIndicator.isHidden = status != "loading"
        if status == "loading" {
            spinnerStart()
        } else {
            spinnerStop()
        }
        resultLoadingLabel.isHidden = status != "loading"
        translateIdleView.isHidden = activePanel != "translate" || run != nil
        resultScrollView.isHidden = !(status == "streaming" || status == "ready" || status == "error")
        resultActionBar.isHidden = status != "ready"

        if status == "streaming" || status == "ready" {
            let dark = theme == .dark
            resultTextView.textStorage?.setAttributedString(LightMarkdown.attributed(run?.text ?? "", dark: dark))
            // The text view is the scroll view's documentView: its frame must
            // track the content or everything past the initial height stays
            // clipped (window grows, text doesn't — exactly the reported bug).
            //
            // WIDTH is owned by the scroll view's autoresizing alone — setting
            // it manually here fought the autoresize (392 vs 420 every event,
            // text container flapping ±28pt = the streaming jitter where each
            // line's last glyphs wrapped and unwrapped). The inset already
            // narrows the text column; measurement below matches it.
            let needed = markdownRenderedHeight(run?.text ?? "", atWidth: resultScrollView.frame.width - 28)
            resultTextView.frame = NSRect(
                x: 0,
                y: 0,
                width: resultScrollView.frame.width,
                height: max(needed + resultTextView.textContainerInset.height * 2, resultScrollView.frame.height)
            )
            if status == "streaming" {
                resultTextView.scrollToEndOfDocument(nil)
            }
        } else if status == "error" {
            let error = NSMutableAttributedString()
            error.append(NSAttributedString(string: "⚠︎ Action failed\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.systemRed,
            ]))
            error.append(NSAttributedString(string: run?.text ?? "", attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
            ]))
            resultTextView.textStorage?.setAttributedString(error)
        }

        if status == "ready" {
            updateEntryTypeTags()
            updateSaveButton()
        }
        rebuildRunTabs()
// (diag removed)
    }

    @objc private func pinToggled() {
        cardPinned.toggle()
        resultCloseButton.image = lucideImage(for: cardPinned ? "pin" : "pin-off", title: cardPinned ? "Unpin" : "Pin")
        resultCloseButton.toolTip = cardPinned ? "Unpin" : "Pin"
        resultCloseButton.contentTintColor = cardPinned ? cardTheme.foreground : cardTheme.secondaryText
        log("card pinned=\(cardPinned)")
    }

    private func clearAllRuns(quietly: Bool) {
        cardRuns.removeAll()
        activeRunId = nil
        cardPinned = false
        rebuildRunTabs()
    }

    @objc private func clearRunsClicked() {
        // Close all run tabs but keep the panel: it returns to the idle
        // input state ("Enter text, then choose an action.").
        cardRuns.removeAll()
        activeRunId = nil
        rebuildRunTabs()
        renderActiveRun()
        layoutResultCard()
        postAction(action: "card-cleared", text: "-")
    }

    /// Single unified layout pass: measures content, positions every strip,
    /// sizes the panel (top-anchored so growth pushes down, not up).
    private func layoutResultCard() {
        let width = cardUserWidth ?? resultCardWidth
        let side: CGFloat = 10
        let contentWidth = width - side * 2

        // --- Input bar (AiForm parity) ---
        // Measure the text at ROW-layout width (full width minus the button
        // group) — the same value regardless of current layout, so switching
        // between single- and multi-line never oscillates.
        let buttonGroupWidth: CGFloat = cardActions.isEmpty
            ? 0
            : CGFloat(cardActions.count) * 30 + CGFloat(cardActions.count - 1) * 2 + 4
        let availForButtons = contentWidth - 50 - 10
        let clipW = min(buttonGroupWidth, availForButtons)
        let rowLayoutWidth = contentWidth - 8 - clipW
        // Two-stage measure (WebView parity): judge multi-line at the ROW
        // width, but size the text view at the FULL width it will actually
        // render at — otherwise the two widths disagree and text is clipped
        // or a tall empty frame is left behind.
        let rowMeasured = inputTextHeight(atWidth: rowLayoutWidth - 12)
        let isMultiline = rowMeasured > 18 // one 13pt line ≈ 17.5pt: anything more is a textarea
        let fullMeasured = inputTextHeight(atWidth: contentWidth - 24)
        let textHeight = isMultiline ? min(fullMeasured, 152) : max(min(rowMeasured, 34), 24)
        let inputBarHeight = isMultiline ? textHeight + 12 + 6 + 28 + 8 : textHeight + 8

        if isMultiline {
            inputTextView.textContainerInset = NSSize(width: 6, height: 6)
            inputTextView.frame = NSRect(x: 6, y: 6 + 28, width: contentWidth - 12, height: textHeight + 12)
            inputButtonsRow.frame = NSRect(x: 0, y: 0, width: buttonGroupWidth, height: 28)
            inputButtonsClip.frame = NSRect(x: 6, y: 5, width: min(buttonGroupWidth, contentWidth - 12), height: 26)
            inputButtonsClip.contentView.scroll(to: NSPoint(x: max(0, buttonGroupWidth - inputButtonsClip.frame.width), y: 0))
            inputButtonsClip.reflectScrolledClipView(inputButtonsClip.contentView)
        } else {
            // Fixed single-line row, vertically centered (WebView parity).
            inputTextView.textContainerInset = NSSize(width: 6, height: (max(textHeight, 24) - 17) / 2)
            inputTextView.frame = NSRect(x: 6, y: (inputBarHeight - max(textHeight, 24)) / 2, width: rowLayoutWidth, height: max(textHeight, 24))
            let buttonsHeight: CGFloat = 28
            inputButtonsRow.frame = NSRect(x: 0, y: 0, width: buttonGroupWidth, height: 28)
            inputButtonsClip.frame = NSRect(
                x: 6 + rowLayoutWidth + 4,
                y: (inputBarHeight - buttonsHeight) / 2,
                width: clipW,
                height: buttonsHeight
            )
            inputButtonsClip.contentView.scroll(to: NSPoint(x: max(0, buttonGroupWidth - clipW), y: 0))
            inputButtonsClip.reflectScrolledClipView(inputButtonsClip.contentView)
        }

        // --- Strip sizes (screen order top→bottom: tabs / input / runs /
        // content / actionBar). Notes & Review replace everything below tabs.
        let isTranslate = activePanel == "translate"
        let tabsH: CGFloat = 36
        let runsH: CGFloat = (isTranslate && !cardRuns.isEmpty) ? 28 : 0
        let inputH = isTranslate ? inputBarHeight : 0
        let status = activeRun?.status
        var contentH: CGFloat = 76 // idle
        if activePanel == "notes" {
            let listH = min(CGFloat(max(displayedNotes.count, 1)) * 40 + 12, 420)
            contentH = 28 + 8 + 24 + 6 + listH // search + gap + chips + gap + list
        } else if activePanel == "review" {
            contentH = 200
        } else if status == "loading" {
            contentH = 48
        } else if status == "streaming" || status == "ready" || status == "error" {
            contentH = min(max(markdownRenderedHeight(activeRun?.text ?? "", atWidth: width - 28) + 24, 64), 440)
        }

        let actionH: CGFloat = (isTranslate && status == "ready") ? 34 : 0

        // Total-height cap = min(640, on-screen room below the top anchor).
        // Overflow is absorbed by the content strip (internal scrolling), so
        // the window NEVER has to be re-anchored upward mid-stream — the
        // previous clamp-to-screen behavior made the card "jump upward" as
        // every streamed chunk grew the window past the screen bottom.
        var maxTotal: CGFloat = 640
        if resultPanel.isVisible,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(resultPanel.frame.origin) }) ?? NSScreen.main {
            maxTotal = min(maxTotal, max(240, resultPanel.frame.maxY - screen.visibleFrame.minY - 8))
        }
        let overflow = max(0, tabsH + 6 + inputH + 4 + runsH + contentH + actionH + side - maxTotal)
        var contentFinal = max(60, contentH - overflow)
        // --- Frames, AppKit y-up, derived strictly bottom-up so adjacent
        // strips can never overlap or drift: action → content → runs →
        // input → tabs. contentFinal absorbs clamping (min 60).
        let actionY: CGFloat = 10
        let contentY = actionY + actionH
        var runsY = contentY + contentFinal
        var inputY = runsY + runsH + 4
        var tabsY = inputY + inputH + 6
        var clampedTotal = tabsY + tabsH
        // User-resized height wins: the content strip absorbs the requested
        // total (overflow scrolls internally), auto sizing stays untouched.
        if let userH = cardUserHeight {
            let cappedH = min(userH, maxTotal)
            let fixed = clampedTotal - contentFinal
            let userH = cappedH
            contentFinal = max(60, userH - fixed)
            runsY = contentY + contentFinal
            inputY = runsY + runsH + 4
            tabsY = inputY + inputH + 6
            clampedTotal = tabsY + tabsH
        }

        resultTabsView.frame = NSRect(x: 0, y: tabsY, width: width, height: tabsH)
        cardPanelTabsView.frame = NSRect(x: 8, y: 2, width: width - 48, height: 28)

        inputContainer.isHidden = !isTranslate
        if isTranslate {
            inputContainer.frame = NSRect(x: side, y: inputY, width: contentWidth, height: inputBarHeight)
        }

        resultRunsBar.isHidden = runsH == 0
        let stripW = width - 48
        resultRunsBar.frame = NSRect(x: 12, y: runsY, width: width - 24, height: runsH)
        resultTabsClip.frame = NSRect(x: 0, y: 0, width: stripW, height: 28)
        resultTabsClip.documentView?.frame = NSRect(x: 0, y: 0, width: max(runTabsContentWidth, stripW), height: 28)

        resultScrollView.isHidden = !isTranslate || !(status == "streaming" || status == "ready" || status == "error")
        resultScrollView.frame = NSRect(x: 0, y: contentY, width: width, height: contentFinal)
        resultLoadingIndicator.isHidden = !isTranslate || status != "loading"
        resultLoadingLabel.isHidden = !isTranslate || status != "loading"
        resultLoadingIndicator.frame.origin = NSPoint(x: 14, y: contentY + contentFinal - 16 - 12)
        resultLoadingLabel.frame.origin = NSPoint(x: 36, y: contentY + contentFinal - 14 - 13)
        translateIdleView.isHidden = !isTranslate || activeRun != nil
        translateIdleView.frame = NSRect(x: 0, y: contentY, width: width, height: contentFinal)
        resultIdleLabel.frame = NSRect(x: 10, y: contentFinal / 2 - 6, width: width - 20, height: 18)
        resultIdleHint.frame = NSRect(x: 10, y: contentFinal / 2 - 26, width: width - 20, height: 14)
        resultIdleIcon.frame = NSRect(x: width / 2 - 8, y: contentFinal / 2 + 18, width: 16, height: 16)

        let notesUIVisible = activePanel == "notes"
        let searchH: CGFloat = 30
        let chipsH: CGFloat = 24
        noteSearchContainer.isHidden = !notesUIVisible
        noteTagBar.isHidden = !notesUIVisible
        cardNotesClip.isHidden = !notesUIVisible
        if notesUIVisible {
            let listTop = contentY + contentFinal
            noteSearchContainer.frame = NSRect(x: 12, y: listTop - searchH, width: width - 24, height: searchH)
            noteSearchField.frame = NSRect(x: 8, y: 3, width: width - 24 - 16, height: searchH - 6)
            noteTagBar.frame = NSRect(x: 12, y: listTop - searchH - 6 - chipsH, width: width - 24, height: chipsH)
            layoutNoteTagButtons()
            cardNotesClip.frame = NSRect(
                x: 0,
                y: contentY,
                width: width,
                height: max(contentFinal - searchH - 8 - chipsH - 6, 64)
            )
        }

        reviewCardView.isHidden = activePanel != "review"
        reviewCardView.frame = NSRect(x: 0, y: contentY, width: width, height: contentFinal)
        relayoutReview(width: width, height: contentFinal)

        resultActionBar.isHidden = actionH == 0
        resultActionBar.frame = NSRect(x: side, y: actionY, width: contentWidth, height: actionH)

        // Top-anchored resize driven by MODEL values (cardX/cardTopY), never
        // by the animating window frame: reading frame.maxY mid-animation made
        // each stream chunk re-anchor to an intermediate position and the
        // card's top edge jittered up and down while text streamed in.
        if resultPanel.isVisible {
            // Anchor directly on the LIVE frame: setFrame is atomic (no
            // animation), so the frame always reflects the user's last drag.
            // The cached cardX/cardTopY model was built for the removed
            // animation and caused snap-back after user drags.
            let live = resultPanel.frame
            var target = NSRect(x: live.minX, y: live.maxY - clampedTotal, width: width, height: clampedTotal)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: live.minX, y: live.maxY)) }) ?? NSScreen.main {
                let visible = screen.visibleFrame
                target.origin.y = max(target.origin.y, visible.minY + 8)
                target.origin.x = min(max(target.minX, visible.minX + 8), visible.maxX - target.width - 8)
            }
            animatePanelFrame(to: target)
        } else {
            animatePanelFrame(to: NSRect(x: 0, y: 0, width: width, height: clampedTotal))
        }
        resultContainer.frame = NSRect(x: 0, y: 0, width: width, height: clampedTotal)
        resizeCorner.frame = NSRect(x: width - 16, y: 0, width: 16, height: 16)
        resizeRight.frame = NSRect(x: width - 4, y: 16, width: 4, height: clampedTotal - 32)
        resizeBottom.frame = NSRect(x: 0, y: 0, width: width - 16, height: 4)
        resizeCorner.setDark(theme == .dark)
        // Right-anchored chrome must ride the window edge (build-time frames
        // pin to the default 420 width and go stale after a user resize).
        let segW = panelTabsControl.fittingSize.width
        panelTabsControl.frame = NSRect(
            x: max(0, (cardPanelTabsView.bounds.width - segW) / 2),
            y: 1,
            width: segW,
            height: 26
        )
        resultCloseButton.frame.origin.x = width - 32
        resultTrashButton.frame = NSRect(x: width - 30, y: runsY + 3, width: 22, height: 22)
        resultTrashButton.isHidden = runsH == 0
        runsSeparator.isHidden = runsH == 0
        runsSeparator.frame = .zero
        resultTrashButton.frame = NSRect(x: width - 30, y: runsY + 3, width: 22, height: 22)
        resultTrashButton.isHidden = runsH == 0
        resultRunsBar.isHidden = runsH == 0
        updateEntryTypeTags()
    }

    private func markdownRenderedHeight(_ markdown: String, atWidth width: CGFloat) -> CGFloat {
        // Measured with a real NSLayoutManager: NSAttributedString.boundingRect
        // drifts on CJK line heights/paragraph spacing, which cut text off at
        // the bottom of the card.
        let storage = NSTextStorage(attributedString: LightMarkdown.attributed(markdown, dark: theme == .dark))
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        _ = manager.glyphRange(for: container)
        return ceil(manager.usedRect(for: container).height)
    }

    private func inputTextHeight(atWidth width: CGFloat) -> CGFloat {
        // NSLayoutManager measurement — boundingRect drifts on CJK and on
        // the exact wrap count this height decision depends on.
        let storage = NSTextStorage(
            attributedString: NSAttributedString(
                string: inputTextView.string.isEmpty ? " " : inputTextView.string,
                attributes: [.font: NSFont.systemFont(ofSize: 13)]
            )
        )
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        _ = manager.glyphRange(for: container)
        return ceil(manager.usedRect(for: container).height)
    }

    /// Review card: word block vertically centered in the content area,
    /// everything tracks the live width/height.
    private func relayoutReview(width: CGFloat, height: CGFloat) {
        let mid = height / 2
        reviewWordLabel.font = .systemFont(ofSize: min(28, max(20, height / 7)), weight: .semibold)
        reviewWordLabel.frame = NSRect(x: 10, y: mid + 16, width: width - 20, height: 34)
        reviewAnswerLabel.frame = NSRect(x: 20, y: mid - 8, width: width - 40, height: 18)
        reviewRevealButton.frame = NSRect(x: width / 2 - 40, y: mid - 44, width: 80, height: 24)
        for (index, grade) in reviewGradeButtons.enumerated() {
            grade.frame = NSRect(x: 20 + CGFloat(index) * 98, y: 16, width: 88, height: 26)
        }
        reviewEmptyLabel.frame = NSRect(x: 10, y: mid - 9, width: width - 20, height: 18)
    }

    /// Height changes apply in ONE atomic setFrame: subview geometry is set
    /// to the new layout in the same pass, so animating the window frame left
    /// a torn intermediate (new subview positions inside the old window) and
    /// tab switches / state changes visibly jittered. The top-anchored target
    /// means an atomic frame change never moves the top edge.
    private func animatePanelFrame(to target: NSRect) {
        resultPanel.setFrame(target, display: true)
    }

    private func placeResultCard() {
        let cardSize = resultPanel.frame.size
        let origin: NSPoint
        if panel.isVisible {
            // Card unfolds from the toolbar: left-aligned with it, 8pt below
            // its bottom edge, growing DOWNWARD. Flips above only when the
            // screen has no room below the toolbar.
            let tb = panel.frame
            var p = NSPoint(x: tb.minX, y: tb.minY - cardSize.height - 8)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: tb.midX, y: tb.midY)) }) ?? NSScreen.main {
                let visible = screen.visibleFrame
                if p.y < visible.minY + 8 {
                    p.y = tb.maxY + 8
                }
                p.x = min(max(p.x, visible.minX + 8), visible.maxX - cardSize.width - 8)
            }
            origin = p
        } else {
            // Toolbar gone: the card TOP sits just below the cursor and the
            // card grows downward — the old bottom-anchor put a 400pt card
            // far above the cursor.
            let point = NSEvent.mouseLocation
            var p = NSPoint(x: point.x + 16, y: point.y - 8 - cardSize.height)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
                let frame = screen.visibleFrame
                p.x = min(max(p.x, frame.minX + 8), frame.maxX - cardSize.width - 8)
                if p.y < frame.minY + 8 {
                    p.y = min(point.y + 24, frame.maxY - cardSize.height - 8)
                }
            }
            origin = p
        }
        resultPanel.setFrameOrigin(origin)
    }

    // MARK: - HTTP request routing (helper's display server)

    private func handleRequestData(_ data: Data) {
        let request = String(data: data, encoding: .utf8) ?? ""



        if request.hasPrefix("POST /notes-hide ") {
            DispatchQueue.main.async {
                self.hideNotesPanel(notifyLexi: false)
            }
            return
        }

        if request.hasPrefix("POST /launcher-show ") {
            DispatchQueue.main.async {
                self.launcherController.show()
            }
            return
        }

        if request.hasPrefix("POST /launcher-hide ") {
            DispatchQueue.main.async {
                self.launcherController.hide(notify: false)
            }
            return
        }

        if request.hasPrefix("POST /clipboard-show ") {
            DispatchQueue.main.async {
                self.clipboardController.show()
            }
            return
        }

        if request.hasPrefix("POST /clipboard-hide ") {
            DispatchQueue.main.async {
                self.clipboardController.hide(notify: false)
            }
            return
        }

        if request.hasPrefix("POST /clipboard-suspend "),
           let body = request.components(separatedBy: "\r\n\r\n").last,
           let bodyData = body.data(using: .utf8),
           let payload = try? JSONDecoder().decode(ClipboardLeasePayload.self, from: bodyData) {
            ClipboardMonitor.shared.suspend(changeCount: payload.changeCount)
            return
        }

        if request.hasPrefix("POST /clipboard-resume "),
           let body = request.components(separatedBy: "\r\n\r\n").last,
           let bodyData = body.data(using: .utf8),
           let payload = try? JSONDecoder().decode(ClipboardLeasePayload.self, from: bodyData) {
            ClipboardMonitor.shared.resume(changeCount: payload.changeCount)
            return
        }

        if request.hasPrefix("POST /theme "),
           let body = request.components(separatedBy: "\r\n\r\n").last,
           let bodyData = body.data(using: .utf8),
           let payload = try? JSONDecoder().decode(ThemePayload.self, from: bodyData) {
            DispatchQueue.main.async {
                PanelStyle.update(
                    opacity: payload.panelOpacity.map { CGFloat($0 / 100.0) },
                    blur: payload.panelBlur.flatMap(PanelStyle.Blur.init(rawValue:))
                )
                self.applyTheme(payload.theme)
            }
            return
        }
        if request.hasPrefix("POST /open-settings ") {
            DispatchQueue.main.async {
                self.showSettingsWindow()
            }
            return
        }

        if request.hasPrefix("GET /debug-state ") || request.hasPrefix("POST /debug-state ") {
            DispatchQueue.main.async {
                let runs = self.cardRuns.map { "\($0.id)|\($0.status)|len=\($0.text.count)" }.joined(separator: "; ")
                let notesVis = NSStringFromRect(self.cardNotesClip.contentView.visibleRect)
                let notesDoc = NSStringFromRect(self.cardNotesClip.documentView?.frame ?? .zero)

                let state = "notesSel=\(self.notesTableView?.selectedRow ?? -99) notesCount=\(self.cardNotesItems.count) notesVis=\(notesVis) notesDoc=\(notesDoc) runsBar=\(NSStringFromRect(self.resultRunsBar.frame)) tabsClip=\(NSStringFromRect(self.resultTabsClip.frame)) doc=\(NSStringFromRect(self.resultTabsClip.documentView?.frame ?? .zero)) trash=\(NSStringFromRect(self.resultTrashButton.frame)) chips=\(self.runChipViews.count) activeRunId=\(self.activeRunId ?? "-") panel=\(self.activePanel) pinned=\(self.cardPinned) runs=[\(runs)] tvLen=\(self.resultTextView.textStorage?.length ?? 0) scrollHidden=\(self.resultScrollView.isHidden) scroll=\(NSStringFromRect(self.resultScrollView.frame)) tv=\(NSStringFromRect(self.resultTextView.frame)) container=\(NSStringFromRect(self.resultContainer.frame)) panelFrame=\(NSStringFromRect(self.resultPanel.frame)) input=\(NSStringFromRect(self.inputContainer.frame)) tvInset=\(self.inputTextView.textContainerInset) tvFrame=\(self.inputTextView.frame) actions=\(self.cardActions.count)"
                self.log("STATE \(state)")
                self.log("DEBUG \(state)")
            }
            return
        }


        if request.hasPrefix("POST /result-show "),
           let body = request.components(separatedBy: "\r\n\r\n").last,
           let bodyData = body.data(using: .utf8),
           let payload = try? JSONDecoder().decode(ResultShowPayload.self, from: bodyData) {
            DispatchQueue.main.async {
                self.showResultCard(payload)
            }
            return
        }

        if request.hasPrefix("POST /result-event "),
           let body = request.components(separatedBy: "\r\n\r\n").last,
           let bodyData = body.data(using: .utf8),
           let payload = try? JSONDecoder().decode(ResultEventPayload.self, from: bodyData) {
            DispatchQueue.main.async {
                self.handleResultEvent(payload)
            }
            return
        }


        if request.hasPrefix("POST /card-hide ") {
            DispatchQueue.main.async {
                guard !self.cardPinned else { return }
                self.resultPanel.orderOut(nil)
                self.postAction(action: "card-hidden", text: "-")
            }
            return
        }
        if request.hasPrefix("POST /card-hide ") {
            DispatchQueue.main.async {
                self.resultPanel.orderOut(nil)
                self.postAction(action: "card-hidden", text: "-")
            }
        }


        if request.hasPrefix("POST /focus-test ") {
            DispatchQueue.main.async {
                self.showPanelTab("notes")
                self.resultPanel.makeKeyAndOrderFront(nil)
                let ok = self.resultPanel.makeFirstResponder(self.noteSearchField)
                FileLog.write("FOCUS-TEST ok=\(ok) isKey=\(self.resultPanel.isKeyWindow) responder=\(String(describing: self.resultPanel.firstResponder).prefix(140))")
            }
            return
        }

        if request.hasPrefix("POST /card-notes "),
           let body = request.components(separatedBy: "\r\n\r\n").last,
           let bodyData = body.data(using: .utf8),
           let payload = try? JSONDecoder().decode(CardNotesPayload.self, from: bodyData) {
            DispatchQueue.main.async {
                self.handleCardNotes(payload)
                // The clipboard panel's tag tabs read the same snapshot.
                self.clipboardController.updateNotes(
                    notes: payload.notes.map {
                        ClipboardNote(
                            id: $0.id ?? 0, name: $0.name, content: $0.content,
                            tags: $0.tags ?? [])
                    },
                    tags: payload.allTags ?? [])
            }
            return
        }

        if request.hasPrefix("POST /card-review "),
           let body = request.components(separatedBy: "\r\n\r\n").last,
           let bodyData = body.data(using: .utf8),
           let payload = try? JSONDecoder().decode(CardReviewPayload.self, from: bodyData) {
            DispatchQueue.main.async {
                self.handleCardReview(payload)
            }
            return
        }

        if request.hasPrefix("POST /card-actions "),
           let body = request.components(separatedBy: "\r\n\r\n").last,
           let bodyData = body.data(using: .utf8),
           let payload = try? JSONDecoder().decode(CardActionsPayload.self, from: bodyData) {
            DispatchQueue.main.async {
                self.handleCardActions(payload)
            }
            return
        }

        guard request.hasPrefix("POST /show "),
              let body = request.components(separatedBy: "\r\n\r\n").last,
              let bodyData = body.data(using: .utf8),
              let payload = try? JSONDecoder().decode(ShowPayload.self, from: bodyData) else {
            log("invalid request \(request.prefix(80))")
            return
        }

        DispatchQueue.main.async {
            self.showPanel(payload)
        }
    }

    private func writeResponse(_ connection: NWConnection) {
        let response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func showPanel(_ payload: ShowPayload) {
        let text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let point = currentMouseLocation(fallback: payload)
        let width = toolbarWidth(for: payload.actions?.count ?? actions.count)
        let origin = clampedPanelOrigin(near: point, width: width, payload: payload)
        let frame = NSRect(x: origin.x, y: origin.y, width: width, height: toolbarHeight)
        if let next = payload.actions {
            applyActions(next)
        }
        log("show panel textLength=\(text.count) mouse=\(Int(point.x)),\(Int(point.y)) payload=\(payload.x),\(payload.y) frame=\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))")
        selectedText = text
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    /// Opens (or focuses) the native settings window. Style changes flow
    /// both ways: applied in-process here, and mirrored into the Rust
    /// caches so a helper restart preserves them.
    func showSettingsWindow(tab: SettingsTab = .general) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let controller: LexiSettingsWindowController
                if let existing = self.settingsWindowController {
                    controller = existing
                } else {
                    controller = LexiSettingsWindowController()
                    self.settingsWindowController = controller
                }
                controller.onPanelStyleChange = { [weak self] theme, opacity, blur in
                    PanelStyle.update(
                        opacity: opacity.map { CGFloat($0) / 100.0 },
                        blur: blur.flatMap(PanelStyle.Blur.init(rawValue:))
                    )
                    if let theme {
                        self?.applyTheme(theme)
                    }
                    var payload: [String: Any] = [:]
                    if let theme { payload["theme"] = theme }
                    if let opacity { payload["panelOpacity"] = opacity }
                    if let blur { payload["panelBlur"] = blur }
                    if let data = try? JSONSerialization.data(withJSONObject: payload),
                       let text = String(data: data, encoding: .utf8) {
                        self?.postAction(action: "panel-style", text: text)
                    }
                }
                controller.onNativeSettingsReload = { [weak self] in
                    self?.postAction(action: "reload-native-settings", text: "")
                }
                controller.show(tab: tab)
            }
        }
    }

    private func applyTheme(_ themeName: String) {
        theme = ToolbarTheme(rawValue: themeName) ?? .dark
        // With the vibrancy material the panel background comes from the
        // system; the theme only pins the appearance (so a forced light/dark
        // choice still applies) and the accent stroke color.
        panel.appearance = theme == .dark
            ? NSAppearance(named: .vibrantDark)
            : NSAppearance(named: .vibrantLight)
        // Contrast scrim: raw glass washes out on dark wallpapers — a
        // theme-tinted veil under the content keeps panels legible anywhere.
        let scrim = PanelStyle.scrim(dark: theme == .dark).cgColor
        container.layer?.backgroundColor = scrim
        dragHandle.theme = theme
        buttons.forEach { $0.theme = theme }
        // The result card follows the same theme: appearance, hairlines, and
        // every themed subview rebuilt (tinted icons, chips, markdown).
        if resultPanel != nil {
            let cardAppearance = theme == .dark
                ? NSAppearance(named: .vibrantDark)
                : NSAppearance(named: .vibrantLight)
            resultPanel.appearance = cardAppearance
            resultContainer.layer?.backgroundColor = scrim
            notesContainer.layer?.backgroundColor = scrim
            // chips: force a rebuild (the diff skips identical id/status/active)
            runChipViews.forEach { $0.removeFromSuperview() }
            runChipViews.removeAll()
            rebuildRunTabs()
                rebuildInputButtons()
            applyNotesTheme()
            renderActiveRun()
            layoutResultCard()
        }
        launcherController.applyTheme(dark: theme == .dark)
        clipboardController.applyTheme(dark: theme == .dark)
        log("theme applied \(theme.rawValue)")
    }

    private func currentMouseLocation(fallback: ShowPayload) -> NSPoint {
        // Rust sends the live cursor location in the same Cocoa coordinate
        // space NSScreen uses. Prefer it: NSEvent.mouseLocation freezes on the
        // display where the panel last lived when the selection happens in
        // another app on another display.
        if fallback.x != 0 || fallback.y != 0 {
            let payload = NSPoint(x: CGFloat(fallback.x), y: CGFloat(fallback.y))
            if NSScreen.screens.contains(where: { $0.frame.contains(payload) }) {
                return payload
            }
        }
        return NSEvent.mouseLocation
    }

    private func clampedPanelOrigin(near point: NSPoint, width: CGFloat, payload: ShowPayload) -> NSPoint {
        // Direction-aware placement (openclip PopupPositioner): a top-to-bottom
        // drag (release more than 10pt below the press) leaves the selected
        // text ABOVE the cursor — place the bar BELOW it so the selection stays
        // visible. Every other gesture keeps the bar above the cursor.
        let belowCursor = (payload.downY ?? payload.y) < payload.y - 10
        var origin = NSPoint(
            x: point.x,
            y: belowCursor
                ? point.y - toolbarHeight - toolbarVerticalGap
                : point.y + toolbarVerticalGap
        )
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            origin.x = min(max(origin.x, frame.minX + 6), frame.maxX - width - 6)
            origin.y = min(max(origin.y, frame.minY + 6), frame.maxY - toolbarHeight - 6)
        }
        return origin
    }

    private func hidePanel(force: Bool = false) {
        selectedText = ""
        panel.orderOut(nil)
        postAction(action: "card-hidden", text: "-")
    }

    private func hideIfClickOutsidePanel(_ event: NSEvent) {
        let screenPoint = NSEvent.mouseLocation
        FileLog.write("DOWN point=\(screenPoint) win=\(event.window.map { "\($0)" } ?? "nil") cardFrame=\(NSStringFromRect(resultPanel.frame)) tvFrame=\(NSStringFromRect(notesTableView.frame)) tvVisible=\(NSStringFromRect(notesTableView.visibleRect))")

        // Card interaction focus: a click inside the card arms the notes
        // Enter; any click elsewhere disarms it. (Nonactivating panels can
        // never become key windows — windowDidBecomeKey never fires.)
        if resultPanel.isVisible {
            let inside = event.window === resultPanel
                || resultPanel.frame.contains(screenPoint)
            postAction(action: "card-key", text: inside ? "1" : "0")
        }

        // Native notes panel: hide + tell lexi so its tap flag never goes stale.
        if notesPanel.isVisible,
           event.window !== notesPanel,
           !notesPanel.frame.contains(screenPoint) {
            hideNotesPanel(notifyLexi: true)
        }

        // Result card: pinned cards stay until unpinned (pin button again).
        // Unpinned: hide (runs stay in memory) + tell lexi so CARD_UP never
        // goes stale and swallows later stream events.
        if resultPanel.isVisible,
           !cardPinned,
           event.window !== resultPanel,
           !resultPanel.frame.contains(screenPoint) {
            resultPanel.orderOut(nil)
            clearAllRuns(quietly: true)
            postAction(action: "card-hidden", text: "-")
        }

        guard panel.isVisible else {
            return
        }

        if event.window === panel {
            return
        }

        if panel.frame.contains(screenPoint) {
            return
        }

        log("hide outside click x=\(Int(screenPoint.x)) y=\(Int(screenPoint.y))")
        hidePanel(force: true)
    }

    @objc private func runToolbarAction(_ sender: NSButton) {
        guard let action = sender.identifier?.rawValue, !selectedText.isEmpty else {
            return
        }
        // Phase 2: AI features and speech run in-process; the remaining
        // built-in tools (copy/search/note/handoff) still route through
        // Rust until Phase 3.
        if action == "read" || action == "speak" {
            LexiSpeech.shared.speak(text: selectedText)
        } else if action == "copy" || action == "search" || action == "note" || action == "handoff" {
            postAction(action: action, text: selectedText)
        } else {
            runFeatureLocally(featureId: action, text: selectedText)
        }
        hidePanel(force: true)
    }

    private func postAction(action: String, text: String) {
        let payload: [String: String] = ["action": action, "text": text]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let body = String(data: data, encoding: .utf8) else { return }
        let connection = NWConnection(
            host: NWEndpoint.Host(IPC_HOST),
            port: (NWEndpoint.Port(rawValue: UInt16(actionPort) ?? ACTION_PORT))!,
            using: .tcp
        )
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                let request = "POST /action HTTP/1.1\r\nHost: \(IPC_HOST)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: request.data(using: .utf8), completion: .contentProcessed { _ in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { _, _, _, _ in
                        connection.cancel()
                    }
                })
            }
        }
        connection.start(queue: connectionQueue)
    }

    private func log(_ message: String) {
        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else {
            return
        }

        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }


    private func startDisplayServer() {
        guard let port = NWEndpoint.Port(rawValue: toolbarPort) else {
            log("invalid toolbar port \(toolbarPort)")
            return
        }

        do {
            listener = try NWListener(using: .tcp, on: port)
        } catch {
            log("toolbar listener failed \(error)")
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            self?.log("toolbar listener state \(state)")
        }
        listener?.newConnectionHandler = { [weak self] connection in
            self?.receive(connection)
        }
        listener?.start(queue: listenerQueue)
        log("toolbar listener start requested")
    }

    private func receive(_ connection: NWConnection, accumulated: Data = Data()) {
        // Connections from NWListener must be started explicitly.
        connection.start(queue: listenerQueue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self else { return }
            var buffer = accumulated
            if let data, !data.isEmpty {
                buffer.append(data)
            }
            if buffer.isEmpty || error != nil {
                self.writeResponse(connection)
                return
            }
            // A receive() may return half a TCP segment. Wait until the full
            // header + Content-Length body has arrived — processing a truncated
            // request corrupts multi-byte UTF-8 (the reported \u{FFFD} mojibake)
            // and silently drops large streamed payloads.
            guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                self.receive(connection, accumulated: buffer)
                return
            }
            let header = String(decoding: buffer[..<headerRange.lowerBound], as: UTF8.self)
            let declaredLength = header.lowercased()
                .split(separator: "\r\n")
                .first(where: { $0.contains("content-length") })
                .flatMap { Int($0.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
            if buffer.count - headerRange.upperBound >= declaredLength {
                self.handleRequestData(buffer)
                self.writeResponse(connection)
            } else {
                self.receive(connection, accumulated: buffer)
            }
        }
    }


    private func toolbarWidth(for actionCount: Int) -> CGFloat {
        toolbarHandleWidth + CGFloat(max(actionCount, 1)) * toolbarSegmentWidth
    }


    private func hideNotesPanel(notifyLexi: Bool) {
        notesPanel.orderOut(nil)
        if notifyLexi {
            postAction(action: "notes-hidden", text: "-")
        }
    }

    private func rebuildRunTabs() {
        let dark = theme == .dark
        let doc = resultTabsClip.documentView ?? NSView()
        if runChipViews.count == cardRuns.count {
            var unchanged = true
            for (chip, run) in zip(runChipViews, cardRuns) {
                let activeNow = run.id == activeRunId
                if chip.runId != run.id || chip.statusKey != run.status || chip.isActiveChip != activeNow {
                    unchanged = false
                    break
                }
            }
            if unchanged { return }
        }
        runChipViews.forEach { $0.removeFromSuperview() }
        runChipViews.removeAll()

        var x: CGFloat = 0
        for run in cardRuns {
            let chip = RunChipView(run: run, dark: dark)
            chip.onSelected = { [weak self] in
                self?.activeRunId = run.id
                self?.renderActiveRun()
                self?.layoutResultCard()
            }
            chip.onDismissed = { [weak self] in
                self?.dismissRun(run.id)
            }
            chip.setActive(run.id == activeRunId, dark: dark)
            doc.addSubview(chip)
            runChipViews.append(chip)
            chip.frame = NSRect(x: x, y: 3, width: chip.fitWidth, height: 24)
            x += chip.fitWidth + 4
        }
        // Horizontal scroll: document view grows with the chips; keep the
        // newest run visible. The strip caps at width-44; layoutResultCard
        // sizes it to the content when the chips fit.
        runTabsContentWidth = max(x - 4, 0)
        let visible = resultTabsClip.frame.width
        let contentW = max(x - 4, visible)
        doc.frame = NSRect(x: 0, y: 0, width: contentW, height: 28)
        resultTabsClip.contentView.scroll(to: NSPoint(x: contentW - visible, y: 0))
        resultTabsClip.reflectScrolledClipView(resultTabsClip.contentView)
    }

    private func rebuildInputButtons() {
        inputButtonsRow.subviews.forEach { $0.removeFromSuperview() }
        let hasInput = !inputTextView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        for (index, item) in cardActions.enumerated() {
            let button = HoverIconButton(frame: .zero)
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.target = self
            button.action = #selector(inputActionClicked(_:))
            button.identifier = NSUserInterfaceItemIdentifier(item.id)
            button.image = lucideImage(for: item.icon, title: item.name)
            button.imageScaling = .scaleProportionallyDown
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = "\(item.name) input text"
            button.isEnabled = hasInput
            button.alphaValue = hasInput ? 1 : 0.4
            button.frame = NSRect(x: CGFloat(index) * 30, y: 0, width: 28, height: 28)
            inputButtonsRow.addSubview(button)
        }
    }

    private func updateEntryTypeTags() {
        let run = activeRun
        let hasEntry = run?.translationJson != nil
        resultEntryBar.isHidden = !hasEntry
        let types = ["word", "phrase", "pattern"]
        for (index, button) in entryButtons.enumerated() {
            let active = run?.entryType == types[index]
            let saved = run?.saved == true
            button.isEnabled = !saved && hasEntry
            button.alphaValue = saved ? 0.4 : 1
            button.layer?.backgroundColor = active
                ? cardTheme.selectedFill.cgColor
                : NSColor.clear.cgColor
        }
        if hasEntry {
            var width: CGFloat = 6
            for button in entryButtons {
                width += button.attributedTitle.size().width + 16
            }
            resultEntryBar.frame.size.width = max(width, 150)
            var x: CGFloat = 2
            for button in entryButtons {
                button.frame.origin.x = x
                x += button.attributedTitle.size().width + 16
            }
        }
    }

    private func updateSaveButton() {
        let run = activeRun
        let canSave = run?.translationJson != nil
        resultSaveButton.isHidden = !canSave
        // Bar-local coordinates (the bar is inset by `side` from the card and
        // sized contentWidth): anchor to its right edge so Copy/Save ride the
        // card edge at any user width.
        let barW = resultActionBar.bounds.width
        resultSaveButton.frame.origin.x = barW - 148 - 10
        resultCopyButton.frame.origin.x = canSave ? barW - 148 - 10 - 26 - 8 : barW - 26 - 10
        if canSave {
            let saved = run?.saved == true
            resultSaveButton.isEnabled = !saved
            resultSaveButton.title = saved ? "Saved" : "Save"
            resultSaveButton.layer?.backgroundColor = saved
                ? NSColor.disabledControlTextColor.withAlphaComponent(0.3).cgColor
                : NSColor.controlAccentColor.cgColor
            resultSaveButton.alphaValue = saved ? 0.6 : 1
        }
    }

    @objc private func entryTypeClicked(_ sender: NSButton) {
        let types = ["word", "phrase", "pattern"]
        guard let index = entryButtons.firstIndex(of: sender) else { return }
        activeRun?.entryType = types[index]
        updateEntryTypeTags()
    }
    @objc private func inputActionClicked(_ sender: NSButton) {
        let id = sender.identifier?.rawValue ?? ""
        let isTool = ["copy", "search", "read", "speak", "note", "handoff"].contains(id)
        submitInput(kind: isTool ? "tool" : "feature", id: id)
    }

    private func submitInput(kind: String, id: String) {
        let text = inputTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Phase 2: features and speech run in-process; built-in tools
        // still route through Rust until Phase 3.
        if id == "read" || id == "speak" {
            LexiSpeech.shared.speak(text: text)
            return
        }
        if kind == "feature" {
            runFeatureLocally(featureId: id, text: text)
            inputTextView.string = ""
            layoutResultCard()
            rebuildInputButtons()
            return
        }
        let payload = ["kind": kind, "id": id, "text": text]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let body = String(data: data, encoding: .utf8) else { return }
        postAction(action: "card-input", text: body)
    }

    @objc private func copyResultClicked() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(activeRun?.text ?? "", forType: .string)
        resultCopyButton.title = "Copied"
        resultCopyButton.image = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.resultCopyButton.title = ""
            self?.resultCopyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy result")
        }
    }

    @objc private func saveResultClicked() {
        guard let run = activeRun, let json = run.translationJson else { return }
        var payload: [String: String] = [
            "word": jsonStringField(json, "word") ?? run.title,
            "translation": jsonStringField(json, "translation") ?? "",
            "pos": jsonStringField(json, "pos") ?? "",
            "definition": jsonStringField(json, "definition") ?? "",
            "example": jsonStringField(json, "example") ?? "",
            "entryType": run.entryType,
        ]
        if payload["translation"]?.isEmpty == true {
            payload["translation"] = String(run.text.prefix(200))
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let body = String(data: data, encoding: .utf8) else { return }
        postAction(action: "save-vocab", text: body)
        run.saved = true
        updateEntryTypeTags()
        updateSaveButton()
    }

    private func dismissRun(_ id: String) {
        cardRuns.removeAll { $0.id == id }
        if activeRunId == id {
            activeRunId = cardRuns.last?.id
        }
        if cardRuns.isEmpty {
            resultPanel.orderOut(nil)
            postAction(action: "card-cleared", text: "-")
            return
        }
        rebuildRunTabs()
        renderActiveRun()
        layoutResultCard()
    }

    private func jsonStringField(_ json: String, _ field: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object[field] as? String
    }

    private func inferredEntryType(for word: String) -> String {
        let text = word.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("...") || text.contains("{{") { return "pattern" }
        if text.hasSuffix(".") || text.hasSuffix("!") || text.hasSuffix("?") { return "pattern" }
        if text.contains(" ") { return "phrase" }
        return "word"
    }
}

private struct ShowPayload: Decodable {
    let text: String
    let x: Int
    let y: Int
    let downX: Int?
    let downY: Int?
    let pending: Bool?
    let actions: [ToolbarAction]?

}
struct ResultShowPayload: Decodable {
    let runId: String?
    let featureId: String?
    var title: String?
    var icon: String?
    var autoSave: Bool?
    let inputText: String?

    init(runId: String? = nil, featureId: String? = nil, title: String? = nil,
         icon: String? = nil, autoSave: Bool? = nil, inputText: String? = nil) {
        self.runId = runId
        self.featureId = featureId
        self.title = title
        self.icon = icon
        self.autoSave = autoSave
        self.inputText = inputText
    }
}

struct ResultEventPayload: Decodable {
    let runId: String?
    let chunk: String?
    let done: Bool
    let error: String?
    let translationJson: String?
    let saved: Bool?

    init(runId: String? = nil, chunk: String? = nil, done: Bool = false,
         error: String? = nil, translationJson: String? = nil, saved: Bool? = nil) {
        self.runId = runId
        self.chunk = chunk
        self.done = done
        self.error = error
        self.translationJson = translationJson
        self.saved = saved
    }
}

private struct CardActionsPayload: Decodable {
    struct Item: Decodable {
        let id: String
        let name: String
        let icon: String
        let kind: String?
    }
    struct PanelDef: Decodable {
        let id: String
        let name: String
        let icon: String
    }
    let actions: [Item]
    let panels: [PanelDef]?
}

/// One notes-table row (view-based NSTableView cell). The system provides
/// selection (accent capsule), row height, scrolling, and width tracking;
/// this cell only lays out its subviews and retints on selection/hover.
/// A borderless NSTextField draws its text top-aligned while its label
/// counterpart centers vertically — and the field EDITOR uses yet another
/// rect. Route draw/edit/select through one centered rect so the renamed
/// title sits exactly where the label was, mid-line, in both states.
private final class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        var r = super.titleRect(forBounds: rect)
        let lineHeight = (font?.boundingRectForFont.height ?? 16).rounded()
        r.origin.y = rect.minY + ((rect.height - lineHeight) / 2).rounded()
        r.size.height = lineHeight
        return r
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                       delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: titleRect(forBounds: rect), in: controlView,
                   editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                         delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: titleRect(forBounds: rect), in: controlView,
                     editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: titleRect(forBounds: cellFrame), in: controlView)
    }
}

private final class NoteRowCell: NSTableCellView, NSTextFieldDelegate {
    /// Traffic-light dot tinted by the note's tag hue (replaces the old
    /// per-row file glyph — same icon on every row carried no information).
    private let tagDot = NSView()
    private var tagName = ""
    let titleLabel = NSTextField(labelWithString: "")
    let contentLabel = NSTextField(labelWithString: "")
    private var tagLabel: NSTextField?
    private var tagButton: TagPillButton?
    private var onTagPicked: ((Int64, NSView) -> Void)?

    private func fireTagClick() {
        if let noteId { onTagPicked?(noteId, tagButton ?? (self as NSView)) }
    }
    private var tagWidth: CGFloat = 40
    /// Inline rename editor: hidden until a double-click swaps it in.
    let titleEditor = NSTextField()
    var deleteButton: NSButton?
    private var onDelete: ((Int64) -> Void)?
    private var onRename: ((Int64, String) -> Void)?
    private var noteId: Int64?
    private var renameCancelled = false
    private var titleBeforeRename = ""
    private var caretToEndOnBegin = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        tagDot.wantsLayer = true
        tagDot.layer?.cornerRadius = 4
        addSubview(tagDot)
        addSubview(titleLabel)
        addSubview(contentLabel)

        let centeredCell = VerticallyCenteredTextFieldCell()
        centeredCell.stringValue = "" // bare cells ship titled "Field"
        centeredCell.isEditable = true
        centeredCell.isBordered = false
        centeredCell.font = .systemFont(ofSize: 13, weight: .medium)
        centeredCell.lineBreakMode = .byTruncatingTail
        centeredCell.usesSingleLineMode = true
        titleEditor.cell = centeredCell
        titleEditor.drawsBackground = false
        // SAME input surface as the Actions bar and search field:
        // inputFill + hairline + radius 8; focus border comes with the edit.
        titleEditor.wantsLayer = true
        titleEditor.layer?.cornerRadius = 8
        titleEditor.layer?.borderWidth = 1
        titleEditor.layer?.masksToBounds = true
        titleEditor.focusRingType = .none
        titleEditor.isHidden = true
        titleEditor.delegate = self
        addSubview(titleEditor)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Labels are the deepest hit-test targets and reject the first mouse by
    /// default — claim every non-button hit so the table gets the click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let hit = super.hitTest(point), hit is NSButton || hit === titleEditor {
            return hit
        }
        return self
    }

    var themeColors: CardTheme = .dark {
        didSet { applyThemeColors() }
    }
    private var inverted = false

    func setInverted(_ value: Bool) {
        guard value != inverted else { return }
        inverted = value
        applyThemeColors()
    }

    private func applyThemeColors() {
        titleEditor.textColor = themeColors.foreground
        titleEditor.layer?.backgroundColor = themeColors.inputFill.cgColor
        titleEditor.layer?.borderColor = themeColors.hairline.cgColor
        titleLabel.textColor = inverted ? themeColors.background : themeColors.foreground
        contentLabel.textColor = inverted ? themeColors.background.withAlphaComponent(0.8) : themeColors.secondaryText
        deleteButton?.contentTintColor = inverted ? themeColors.background : themeColors.tertiaryText
        refreshTagColors()
        if let tagButton {
            tagButton.contentTintColor = inverted ? themeColors.background : themeColors.secondaryText
            tagButton.layer?.backgroundColor = inverted
                ? NSColor.black.withAlphaComponent(0.18).cgColor
                : NSColor.labelColor.withAlphaComponent(themeColors.isDark ? 0.10 : 0.06).cgColor
        }

        // Rename editor: always its own surface (inputFill + foreground) —
        // following the capsule's white-on-accent made white-on-white text
        // on the light theme.
        titleEditor.textColor = themeColors.foreground
        titleEditor.backgroundColor = themeColors.inputFill
        titleEditor.layer?.borderColor = themeColors.hairline.cgColor
        titleEditor.layer?.borderWidth = 1
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyThemeColors() }
    }

    func configure(note: CardNotesPayload.Note, dark: Bool,
                   onDelete: ((Int64) -> Void)?,
                   onRename: ((Int64, String) -> Void)? = nil,
                   onTagPicked: ((Int64, NSView) -> Void)? = nil) {

        noteId = note.id
        self.onRename = onRename
        tagName = (note.tags ?? []).first ?? ""
        let titleText = note.name.isEmpty ? String(note.content.prefix(40)) : note.name
        titleLabel.stringValue = titleText
        if titleEditor.isHidden {
            titleEditor.stringValue = titleText
        }
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.cell?.wraps = false
        titleLabel.toolTip = note.content

        contentLabel.stringValue = note.content
        contentLabel.font = .systemFont(ofSize: 12)
        contentLabel.maximumNumberOfLines = 1
        contentLabel.cell?.truncatesLastVisibleLine = true
        contentLabel.cell?.wraps = false

        // Trailing tag pill (one tag per note in this data model). It is a
        // BUTTON: click opens the tag picker (system NSMenu) for this note.
        tagLabel?.removeFromSuperview()
        tagLabel = nil
        tagButton?.removeFromSuperview()
        tagButton = nil
        if let tag = (note.tags ?? []).first {
            let button = TagPillButton()
            button.title = tag
            button.isBordered = false
            button.font = .systemFont(ofSize: 10, weight: .medium)
            button.alignment = .center
            button.lineBreakMode = .byTruncatingTail
            button.toolTip = "Change tag"
            tagWidth = max((tag as NSString).size(withAttributes: [.font: button.font!]).width + 14, 34)
            button.wantsLayer = true
            button.layer?.cornerRadius = 8
            button.onTagClicked = { [weak self] in
                self?.fireTagClick()
            }
            addSubview(button)
            tagButton = button
        }

        if let deleteButton {
            deleteButton.removeFromSuperview()
        }
        if let id = note.id, let onDelete {
            let button = NSButton(image: lucideImage(for: "x", title: "Delete note") ?? NSImage(),
                                  target: self,
                                  action: #selector(deleteTapped))
            button.isBordered = false
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = "Delete note"
            button.identifier = NSUserInterfaceItemIdentifier(String(id))
            self.onDelete = onDelete
            deleteButton = button
            addSubview(button)
        }
        needsLayout = true
        refreshTagColors()
    }

    /// One hue per tag: the leading dot AND the pill text/fill share it, so
    /// tags are tellable apart pre-attentively (traffic-light language).
    private func refreshTagColors() {
        let dark = themeColors.isDark
        if tagName.isEmpty {
            tagDot.isHidden = true
        } else {
            tagDot.isHidden = false
            tagDot.layer?.backgroundColor = tagColor(for: tagName, dark: dark).cgColor
        }
        if let tagButton, !tagName.isEmpty {
            let color = tagColor(for: tagName, dark: dark)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            tagButton.attributedTitle = NSAttributedString(
                string: tagName,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: color,
                    .paragraphStyle: paragraph,
                ]
            )
            tagButton.layer?.backgroundColor = color.withAlphaComponent(dark ? 0.16 : 0.12).cgColor
        }
    }

    @objc private func deleteTapped(_ sender: NSButton) {
        if let raw = sender.identifier?.rawValue, let id = Int64(raw) {
            onDelete?(id)
        }
    }

    /// Double-click → the title becomes an input; Enter or losing focus
    /// commits, Esc cancels.
    func beginRenaming() {
        guard noteId != nil else { return }
        titleBeforeRename = titleLabel.stringValue
        renameCancelled = false
        titleEditor.stringValue = titleBeforeRename
        titleLabel.isHidden = true
        titleEditor.isHidden = false
        caretToEndOnBegin = true
        titleEditor.layer?.borderColor = themeColors.foreground.withAlphaComponent(0.45).cgColor
        window?.makeFirstResponder(titleEditor)
        DispatchQueue.main.async { [weak self] in
            self?.placeCaretAtEndOnce()
        }
    }

    private func placeCaretAtEndOnce() {
        guard caretToEndOnBegin, let editor = titleEditor.currentEditor() else { return }
        caretToEndOnBegin = false
        // Finder semantics: entering rename PRE-SELECTS everything, so
        // typing replaces and arrow keys/home reveal the caret as needed.
        editor.selectAll(nil)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard obj.object as? NSTextField === titleEditor else { return }
        placeCaretAtEndOnce()
    }

    private func endRenaming() {
        titleEditor.layer?.borderColor = themeColors.hairline.cgColor
        titleEditor.isHidden = true
        titleLabel.isHidden = false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard obj.object as? NSTextField === titleEditor else { return }
        let committed = !renameCancelled
        endRenaming()
        guard committed, let id = noteId else { return }
        let newValue = titleEditor.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !newValue.isEmpty, newValue != titleBeforeRename {
            onRename?(id, newValue)
        } else {
            titleEditor.stringValue = titleBeforeRename
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === titleEditor else { return false }
        if commandSelector == NSSelectorFromString("cancelOperation:") {
            renameCancelled = true
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        // Content-first rows (Notes/Mail language): the tag-colored dot
        // rides the title line at the pill's own 14pt inset, the two-line
        // text block follows; the trailing column (tag pill + delete)
        // shares one right margin.
        tagDot.frame = NSRect(x: 14, y: 24, width: 8, height: 8)
        deleteButton?.frame = NSRect(x: w - 28, y: bounds.midY - 9, width: 18, height: 18)
        let hasTag = tagButton != nil
        if hasTag {
            tagButton!.frame = NSRect(x: w - 28 - 6 - tagWidth, y: bounds.midY - 8, width: tagWidth, height: 16)
        }
        let textX: CGFloat = 30
        let trailingX: CGFloat = (hasTag ? (w - 28 - 6 - tagWidth) : w - 28) - 6
        titleLabel.frame = NSRect(x: textX, y: 20, width: max(trailingX - textX, 24), height: 16)
        contentLabel.frame = NSRect(x: textX, y: 4, width: max(trailingX - textX, 24), height: 15)
        // Rename editor: same text origin as the title label, grown downward.
        titleEditor.frame = NSRect(
            x: titleLabel.frame.minX - 2,
            y: titleLabel.frame.minY - 4,
            width: trailingX - titleLabel.frame.minX + 2,
            height: 23
        )
    }
}

/// Row view: paints ONLY the hover (the system has none), mimicking the
/// system capsule's inset/radius so the two geometries read as one.
private final class NotesTable: NSTableView {
    override var mouseDownCanMoveWindow: Bool { false }

    /// Responder-chain keyboard: the panel is key (OS-normal model), so
    /// Enter inserts the highlighted note and Tab cycles panel tabs — no
    /// global event tap involved.
    var onEnterKey: (() -> Void)?
    var onDoubleClickRow: ((Int) -> Void)?
    private var lastClickRow = -1
    private var lastClickTime = TimeInterval(0)

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 52: // Enter / keypad Enter
            onEnterKey?()
        default:
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // While a row's title editor is live, a click INSIDE that row belongs
        // to the edit (caret moves, selection clears) — running the table's
        // tracking would resign the editor and snap back to the label.
        // The event still belongs to the FIELD EDITOR: forward it, otherwise
        // double-click-to-select-word and drag-select die inside the editor.
        if let editor = window?.firstResponder as? NSText,
           editor.isFieldEditor,
           let host = editor.delegate as? NSTextField,
           host === (view(atColumn: 0, row: row(at: convert(event.locationInWindow, from: nil)), makeIfNecessary: false) as? NoteRowCell)?.titleEditor {
            editor.mouseDown(with: event)
            return
        }
        // The panel is nonactivating: NSTableView's own tracking silently
        // bails before the app is active. Select the clicked row
        // PROGRAMMATICALLY — works without key status.
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = self.row(at: point)
        if clickedRow >= 0 {
            // Double-click is ours to detect: the system's doubleAction dispatch
            // ran a longer event chain that beeped. Same row inside the
            // double-click interval = rename, nothing else.
            let now = event.timestamp
            if clickedRow == lastClickRow,
               now - lastClickTime < NSEvent.doubleClickInterval,
               let onDoubleClickRow {
                lastClickRow = -1
                onDoubleClickRow(clickedRow)
                return
            }
            lastClickRow = clickedRow
            lastClickTime = now
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
        super.mouseDown(with: event)
    }
}

/// In-card tag picker: flipped layer list pinned at the pill. One row per
/// known tag (check on the current), divider, clear row. System menus
/// misplace themselves on nonactivating panels - this stays in the card.
private final class TagDropdownView: NSView {
    private let onPick: (String?) -> Void
    private let theme: CardTheme
    private var rows: [NSView] = []
    private(set) var naturalWidth: CGFloat = 120

    init(tags: [String], current: String?, theme: CardTheme, onPick: @escaping (String?) -> Void) {
        self.onPick = onPick
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        shadow = NSShadow()
        shadow?.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow?.shadowBlurRadius = 14
        shadow?.shadowOffset = NSSize(width: 0, height: -3)

        var y: CGFloat = 4
        func addRow(_ title: String, value: String?, checked: Bool) {
            let button = RowPickButton(title: title)
            button.font = .systemFont(ofSize: 12, weight: checked ? .medium : .regular)
            button.alignment = .left
            button.lineBreakMode = .byTruncatingTail
            if checked, let check = lucideImage(for: "check", title: title, color: theme.foreground) {
                check.size = NSSize(width: 12, height: 12)
                let attachment = NSTextAttachment()
                attachment.image = check
                attachment.bounds = NSRect(x: 0, y: (button.font!.capHeight - 12) / 2, width: 12, height: 12)
                let title = NSMutableAttributedString(string: title, attributes: [
                    .font: button.font!,
                    .foregroundColor: theme.foreground,
                ])
                title.append(NSAttributedString(string: "  "))
                title.append(NSAttributedString(attachment: attachment))
                button.attributedTitle = title
            } else {
                button.attributedTitle = NSAttributedString(string: title, attributes: [
                    .font: button.font!,
                    .foregroundColor: value == nil ? theme.secondaryText : theme.foreground,
                ])
            }
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.onPickRow = { [weak self] in self?.onPick(value) }
            rows.append(button)
            addSubview(button)
            y += 26
        }
        for tag in tags {
            addRow(tag, value: tag, checked: tag == current)
        }
        // Width hugs the longest label (+check mark slot); never the old
        // blanket 150+.
        let longest = (["No tag"] + tags).map {
            ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
        }.max() ?? 60
        naturalWidth = min(max(longest + 46, 96), 190)
        if !tags.isEmpty {
            let divider = NSView()
            divider.wantsLayer = true
            divider.layer?.backgroundColor = theme.hairline.cgColor
            rows.append(divider)
            addSubview(divider)
            y += 5
        }
        addRow("No tag", value: nil, checked: current == nil)
        frame.size = NSSize(width: 150, height: y)
        sizeToFit(width: 150)
    }

    func sizeToFit(width: CGFloat) {
        frame.size.width = width
        var y: CGFloat = 3
        for view in rows {
            if view is RowPickButton {
                view.frame = NSRect(x: 6, y: y, width: width - 12, height: 24)
                y += 26
            } else {
                view.frame = NSRect(x: 8, y: y + 2, width: width - 16, height: 1)
                y += 5
            }
        }
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // OPAQUE card-colored panel + hairline. Layer backgrounds never
        // composited here; painting does (same as the notes row pills).
        theme.background.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        theme.hairline.setStroke()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 8,
            yRadius: 8
        ).stroke()
        FileLog.write("TAGDROP drew bg=\(theme.background) bounds=\(bounds)")
    }

    required init?(coder: NSCoder) {
        fatalError("programmatic only")
    }
}

/// A dropdown row: whole-row click, goty quiet-wash hover.
private final class RowPickButton: NSButton {
    var onPickRow: (() -> Void)?
    private var hoverArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        target = self
        action = #selector(rowPicked)
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    override var title: String {
        didSet {}
    }

    /// Text sits 10pt from the row's left edge, not flush against it.
    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 8, dy: 0)
        attributedTitle.draw(in: NSRect(
            x: inset.minX + 2,
            y: (bounds.height - attributedTitle.size().height) / 2,
            width: inset.width,
            height: attributedTitle.size().height
        ))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        if let hoverArea { addTrackingArea(hoverArea) }
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
        super.mouseDown(with: event)
        onPickRow?()
    }

    @objc private func rowPicked() {}

    required init?(coder: NSCoder) {
        fatalError("programmatic only")
    }
}


/// Tag pill: a borderless button that fires on ANY click inside its bounds.
private final class TagPillButton: NSButton {
    var onTagClicked: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init() {
        super.init(frame: .zero)
        target = self
        action = #selector(pillClicked)
    }

    @objc private func pillClicked() {
        onTagClicked?()
    }

    required init?(coder: NSCoder) {
        fatalError("programmatic only")
    }
}

private final class NoteRowView: NSTableRowView {
    private var hoverArea: NSTrackingArea?
    private var hovering = false
    var pillColor: NSColor = .clear { didSet { needsDisplay = true } }
    // With selectionHighlightStyle = .none the table does NOT redraw on
    // selection change — without this the deselected row keeps its stale
    // pill and two rows read as selected at once.
    override var isSelected: Bool {
        didSet { needsDisplay = true }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        if let hoverArea { addTrackingArea(hoverArea) }
    }

    override func mouseEntered(with event: NSEvent) {
        // Tracking areas ignore occlusion by sibling layers (the tag
        // dropdown floats above the list): only hover when THIS row is the
        // top-most view under the cursor.
        if let top = window?.contentView?.hitTest(event.locationInWindow),
           top === self || top.isDescendant(of: self) {
            hovering = true
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    func clearHover() {
        hovering = false
        needsDisplay = true
    }

    var hoverColor: NSColor = NSColor.labelColor.withAlphaComponent(0.06) {
        didSet { needsDisplay = true }
    }

    // goty tty7 pill: hugging the row's edge by the same inset on both
    // sides, full-radius caps. Selection is a quiet same-hue wash (text
    // keeps its color); hover is one step lighter.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let pill = bounds.insetBy(dx: 3, dy: 2)
        let path = NSBezierPath(
            roundedRect: pill,
            xRadius: 8,
            yRadius: 8
        )
        if isSelected {
            // Selection = the wash capsule; glyphs keep their own color.
            pillColor.setFill()
            path.fill()
        } else if hovering {
            hoverColor.setFill()
            path.fill()
        }
    }
}

private struct CardNotesPayload: Decodable {
    var allTags: [String]?
    struct Note: Decodable {
        let id: Int64?
        let name: String
        let tags: [String]?
        let content: String
    }
    let notes: [Note]
}

private struct CardReviewPayload: Decodable {
    struct ReviewWord: Decodable {
        let id: Int64
        let word: String
        let translation: String?
        let pos: String?
        let entryType: String?
    }
    let word: ReviewWord?
}

/// Whole-row click target (notes rows: click = select + inject). Hover gives
/// unselected rows a whisper of background so the target is discoverable.
private final class ClickableRow: NSView {
    var onClicked: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        if let hoverArea { addTrackingArea(hoverArea) }
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func mouseDown(with event: NSEvent) {
        onClicked?()
    }
}

/// Top-down document view for the notes list (row 0 = the top edge).
private final class FlippedNotesDoc: NSView {
    override var isFlipped: Bool { true }
}

/// NSTextField that reports clicks (notes rows: click = copy).
private final class ClickableTextField: NSTextField {
    var onClicked: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        onClicked?()
    }
}

/// One AI run shown in the card (WebView WorkspaceRun parity).
struct CardNotesSelectPayload: Codable {
    let index: Int
}

private final class CardRun {
    let id: String
    let featureId: String
    let title: String
    let icon: String
    var status: String = "loading" // loading | streaming | ready | error
    var text: String = ""
    var translationJson: String?
    var entryType: String = "word"
    var saved = false
    init(id: String, featureId: String, title: String, icon: String) {
        self.id = id
        self.featureId = featureId
        self.title = title
        self.icon = icon
    }
}

/// A run chip in the tabs strip: icon + title + inline dismiss (×),
/// whole-chip click selects the run.
private final class RunChipView: NSView {
    var onSelected: (() -> Void)?
    var onDismissed: (() -> Void)?
    let fitWidth: CGFloat
    private let iconView: NSImageView
    private let titleLabel: NSTextField
    private let dismissButton: NSButton
    private var isActive = false
    private var isDark = false
    private var statusDot: NSView!
    var runId = ""
    var statusKey = ""
    var isActiveChip = false

    init(run: CardRun, dark: Bool) {
        isDark = dark
        runId = run.id
        statusKey = run.status
        let icon = lucideImage(for: run.icon, title: run.title) ?? NSImage()
        let title = run.title
        let titleWidth = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width + 8
        fitWidth = 8 + 4 + 5 + 13 + 4 + titleWidth + 8 + 14
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
        isActive = active
        isActiveChip = active
        isDark = dark
        layer?.backgroundColor = active
            ? (dark ? NSColor.white.withAlphaComponent(0.14).cgColor : NSColor.black.withAlphaComponent(0.08).cgColor)
            : NSColor.clear.cgColor
        let color: NSColor = active ? .labelColor : .secondaryLabelColor
        titleLabel.textColor = color
        iconView.contentTintColor = color
        statusDot.layer?.backgroundColor = Self.dotColor(for: statusKey).cgColor
    }

    private static func dotColor(for status: String) -> NSColor {
        switch status {
        case "error": return .systemRed.withAlphaComponent(0.85)
        case "ready": return .controlAccentColor.withAlphaComponent(0.65)
        default: return .secondaryLabelColor.withAlphaComponent(0.55)
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
private final class CardInputTextView: NSTextView {
    var onBecameFocus: (() -> Void)?
    var onLostFocus: (() -> Void)?
    /// Multiline text views have no native placeholder; this one paints the
    /// hint INSIDE draw() at textContainerOrigin with the same font — the
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

/// Single-line card input: native NSTextField with the placeholder STRING
/// drawn by the cell itself — caret and placeholder share one layout, so
/// they cannot drift apart. Vertically centered via the same cell used by
/// the inline rename editor.
class CardInputTextField: NSTextField {
    var onBecameFocus: (() -> Void)?
    var onLostFocus: (() -> Void)?
    var onCommit: (() -> Void)?

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

/// Lightweight Markdown → NSAttributedString for the result card.
/// Supports headings, lists, quotes, fenced code, bold/italic/inline code —
/// enough to mirror the WebView renderer's output shapes. Zero dependencies.
private enum LightMarkdown {
    static func attributed(_ markdown: String, dark: Bool) -> NSAttributedString {
        let body = dark
            ? NSColor.white.withAlphaComponent(0.9)
            : NSColor.black.withAlphaComponent(0.85)
        let muted = dark
            ? NSColor.white.withAlphaComponent(0.55)
            : NSColor.black.withAlphaComponent(0.55)
        let codeBackground = dark
            ? NSColor.white.withAlphaComponent(0.08)
            : NSColor.black.withAlphaComponent(0.06)
        let bodyFont = NSFont.systemFont(ofSize: 13)
        let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        paragraphStyle.paragraphSpacing = 8
        let listStyle = NSMutableParagraphStyle()
        listStyle.lineSpacing = 3
        listStyle.headIndent = 18

        let out = NSMutableAttributedString()
        var inCode = false
        var codeLines: [String] = []
        var paragraphLines: [String] = []

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            let paragraph = NSMutableAttributedString(
                string: paragraphLines.joined(separator: "\n"),
                attributes: [.font: bodyFont, .foregroundColor: body, .paragraphStyle: paragraphStyle]
            )
            applyInline(paragraph, bodyFont: bodyFont, body: body, mono: monoFont, codeBg: codeBackground)
            out.append(paragraph)
            paragraphLines.removeAll()
        }

        func flushCode() {
            guard !codeLines.isEmpty else { return }
            let text = codeLines.joined(separator: "\n")
            let block = NSMutableAttributedString(
                string: text + "\n",
                attributes: [
                    .font: monoFont,
                    .foregroundColor: body,
                    .backgroundColor: codeBackground,
                    .paragraphStyle: paragraphStyle,
                ]
            )
            out.append(block)
            codeLines.removeAll()
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCode {
                    flushCode()
                } else {
                    flushParagraph()
                    inCode = true
                }
                continue
            }
            if inCode {
                codeLines.append(rawLine)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if trimmed.hasPrefix("#") {
                flushParagraph()
                let level = trimmed.prefix(while: { $0 == "#" }).count
                let heading = trimmed.drop(while: { $0 == "#" })
                    .trimmingCharacters(in: .whitespaces)
                let size: CGFloat = level <= 1 ? 17 : (level == 2 ? 15 : 14)
                out.append(NSAttributedString(string: heading + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                    .foregroundColor: body,
                ]))
                continue
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                flushParagraph()
                let item = NSMutableAttributedString(
                    string: "•  " + trimmed.dropFirst(2) + "\n",
                    attributes: [.font: bodyFont, .foregroundColor: body, .paragraphStyle: listStyle]
                )
                applyInline(item, bodyFont: bodyFont, body: body, mono: monoFont, codeBg: codeBackground)
                out.append(item)
                continue
            }

            if trimmed.hasPrefix("> ") {
                flushParagraph()
                out.append(NSAttributedString(
                    string: "▎" + trimmed.dropFirst(2) + "\n",
                    attributes: [.font: bodyFont, .foregroundColor: muted, .paragraphStyle: listStyle]
                ))
                continue
            }

            paragraphLines.append(rawLine)
        }

        if inCode { flushCode() }
        flushParagraph()
        return out
    }

    /// Inline `code`, **bold**, *italic*. Each pass recomputes its NSRange
    /// against the current string — a stale range from an earlier
    /// replacement is out of bounds and NSRegularExpression throws
    /// NSRangeException, which is fatal in Swift (no ObjC catch).
    private static func applyInline(
        _ text: NSMutableAttributedString,
        bodyFont: NSFont,
        body: NSColor,
        mono: NSFont,
        codeBg: NSColor
    ) {
        let bold = NSFontManager.shared.convert(bodyFont, toHaveTrait: .boldFontMask)
        let italic = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)

        replaceInline(text, pattern: "`([^`]+)`", attributes: [
            .font: mono, .foregroundColor: body, .backgroundColor: codeBg,
        ])
        replaceInline(text, pattern: "\\*\\*([^*]+)\\*\\*", attributes: [.font: bold])
        replaceInline(text, pattern: "\\*([^*]+)\\*", attributes: [.font: italic])
    }

    /// Replace `pattern` matches with their capture group, applying
    /// `attributes` over the replacement. Matches are applied back-to-front
    /// so earlier offsets survive each replacement.
    private static func replaceInline(
        _ text: NSMutableAttributedString,
        pattern: String,
        attributes: [NSAttributedString.Key: Any]
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let current = text.string
        let full = NSRange(location: 0, length: (current as NSString).length)
        for match in regex.matches(in: current, range: full).reversed() {
            guard let inner = Range(match.range(at: 1), in: current) else { continue }
            let innerText = String(current[inner])
            text.replaceCharacters(in: match.range, with: innerText)
            text.addAttributes(
                attributes,
                range: NSRange(location: match.range.location, length: (innerText as NSString).length)
            )
        }
    }
}


extension SelectionToolbarApp: NSTextViewDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSTextField === noteSearchField else { return }
        noteSearchText = noteSearchField.stringValue
        applyNoteFilters()
    }

    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === inputTextView else { return }
        // AiForm parity: re-measure and re-flow single- vs multi-line on
        // every edit, and re-enable the action buttons when text exists.
        layoutResultCard()
        rebuildInputButtons()
    }

    func textDidBeginEditing(_ notification: Notification) {
        guard notification.object as? NSTextView === inputTextView else { return }
        setInputFocused(true)
    }

    func textDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextView === inputTextView else { return }
        setInputFocused(false)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === inputTextView else { return false }
        let newline = NSSelectorFromString("insertNewline:")
        let cancel = NSSelectorFromString("cancelOperation:")
        if commandSelector == newline {
            // Enter runs the default feature; Shift+Enter keeps a newline
            // (WebView AiForm keydown parity).
            if !NSEvent.modifierFlags.contains(.shift) {
                submitInput(kind: "feature", id: "")
                return true
            }
            return false
        }
        if commandSelector == cancel {
            escapeResultCardIfNeeded()
            return true
        }
        return false
    }
}



private struct NotesShowPayload: Decodable {
    struct Note: Decodable {
        let name: String
        let content: String
    }
    let notes: [Note]
    let selected: Int
}

extension SelectionToolbarApp {
    /// Hovers are the only self-drawn effect; scrolling invalidates them.
    @objc func notesClipScrolled() {
        let range = notesTableView.rows(in: notesTableView.visibleRect)
        for row in range.location..<max(range.location, range.location + range.length) {
            if let rowView = notesTableView.rowView(atRow: row, makeIfNecessary: false) as? NoteRowView {
                rowView.clearHover()
            }
        }
    }
}

extension SelectionToolbarApp: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === noteSearchField else { return false }
        if commandSelector == NSSelectorFromString("cancelOperation:") {
            if !noteSearchField.stringValue.isEmpty {
                noteSearchField.stringValue = ""
                noteSearchText = ""
                applyNoteFilters()
            } else {
                notesTableView.window?.makeFirstResponder(notesTableView)
            }
            return true
        }
        return false
    }
}

extension SelectionToolbarApp: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        displayedNotes.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < displayedNotes.count else { return nil }
        let cell = tableView.makeView(
            withIdentifier: NSUserInterfaceItemIdentifier("NoteRow"),
            owner: self
        ) as? NoteRowCell ?? NoteRowCell(frame: .zero)
        cell.identifier = NSUserInterfaceItemIdentifier("NoteRow")
        let note = displayedNotes[row]
        cell.configure(note: note, dark: theme == .dark,
                       onDelete: { [weak self] id in
                           self?.noteDeleteClickedId(id)
                       },
                       onRename: { [weak self] id, name in
                           self?.noteRenamed(id: id, name: name)
                       },
                       onTagPicked: { [weak self] id, anchor in
                           self?.showTagMenu(noteId: id, tag: note.tags?.first, anchor: anchor)
                       })
        cell.themeColors = cardTheme
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if let reused = tableView.makeView(
            withIdentifier: NSUserInterfaceItemIdentifier("NoteRowView"),
            owner: self
        ) as? NoteRowView {
            return reused
        }
        let view = NoteRowView(frame: .zero)
        view.identifier = NSUserInterfaceItemIdentifier("NoteRowView")
        view.hoverColor = cardTheme.hoverFill
        view.pillColor = cardTheme.selectedFill
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        FileLog.write("SEL didChange row=\(notesTableView.selectedRow)")
        let selected = notesTableView.selectedRow
        if selected >= 0, selected < displayedNotes.count {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(displayedNotes[selected].content, forType: .string)
        }
    }
}

private struct ThemePayload: Decodable {
    let theme: String
    var panelOpacity: Double?
    var panelBlur: String?
}


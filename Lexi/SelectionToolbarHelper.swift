import AppKit
import Foundation
import Network

let logURL = URL(fileURLWithPath: "/tmp/lexi-selection-helper.log")

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

    func luminance(_ c: NSColor) -> CGFloat {
        let x = c.usingColorSpace(.deviceRGB) ?? c
        func f(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * f(x.redComponent) + 0.7152 * f(x.greenComponent) + 0.0722 * f(x.blueComponent)
    }

    func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
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

let toolbarHandleWidth: CGFloat = 16
let toolbarSegmentWidth: CGFloat = 30
let toolbarHeight: CGFloat = 28
let toolbarIconSize: CGFloat = 14
let toolbarVerticalGap: CGFloat = 6
let resultCardWidth: CGFloat = 420

struct ToolbarAction: Decodable {
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

enum ToolbarTheme: String {
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

final class SelectionToolbarApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var panel: NSPanel!
    var container: NSView!
    var dragHandle: ToolbarDragHandle!
    var buttons: [ToolbarButton] = []
    var actions = defaultToolbarActions()
    var theme: ToolbarTheme = .dark
    var cardTheme: CardTheme { theme == .dark ? CardTheme.dark : CardTheme.light }
    var selectedText = ""
    var localKeyMonitor: Any?
    var globalKeyMonitor: Any?
    var localMouseMonitor: Any?
    var globalMouseMonitor: Any?
    var localMouseMoveMonitor: Any?
    var globalMouseMoveMonitor: Any?
    var globalScrollMonitor: Any?
    var notesPanel: NSPanel!
    lazy var launcherController: LauncherPanelController = {
        let controller = LauncherPanelController()
        controller.onHidden = { [weak self] in
            self?.panels.dismissed(.launcher)
        }
        controller.onOpenSettings = { [weak self] in
            // The coordinator retires the launcher (and any other overlay).
            self?.showSettingsWindow()
        }
        return controller
    }()

    lazy var clipboardController: ClipboardPanelController = {
        let controller = ClipboardPanelController()
        controller.onHidden = { [weak self] in
            self?.panels.dismissed(.clipboard)
        }
        controller.onAction = { [weak self] action, text in
            self?.handleAction(action: action, text: text)
        }
        return controller
    }()
    var panelTabPills: [NSButton] = []
    var cardCategories: [String] = []
    var tagDropdown: TagDropdownView?
    var tagDropdownMonitor: Any?
    var resultPanel: NSPanel!
    var resultContainer: NSView!
    var resultTabsView: NSView!
    var resultTabsClip: HorizontalOnlyClip!
    var resultTrashButton: NSButton!
    var resultCloseButton: NSButton!
    var resultScrollView: NSScrollView!
    var resultTextView: NSTextView!
    var resultLoadingIndicator: NSView!
    var resultLoadingLabel: NSTextField!
    var translateIdleView: NSView!
    var resultIdleLabel: NSTextField!
    var resultIdleHint: NSTextField!
    var resultIdleIcon: NSImageView!
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var resultActionBar: NSView!
    var resultEntryBar: NSView!
    var resultCopyButton: NSButton!
    var resultSaveButton: NSButton!
    var inputContainer: NSView!
    var inputTextView: CardInputTextView!
    var runsSeparator: NSView!
    var inputButtonsRow: NSView!
    var inputButtonsClip: HorizontalOnlyClip!
    var cardRuns: [CardRun] = []
    var cardActions: [CardActionsPayload.Item] = []
    var activeRunId: String?
    var activePanel = "translate"
    var panelDefs: [(id: String, name: String, icon: String)] = []
    var cardPanelTabsView: NSView!
    var panelTabsControl: NSSegmentedControl!
    var resultRunsBar: NSView!
    var cardNotesClip: HorizontalOnlyClip!

    var notesTableView: NotesTable!
    var noteSearchContainer: NSView!
    var noteSearchField: CardInputTextField!
    var noteTagBar: NSView!
    var noteTagButtons: [NSButton] = []
    var noteSearchText = ""
    var noteActiveCategory = "all"
    var displayedNotes: [CardNotesPayload.Note] = []
    var cardNotesItems: [CardNotesPayload.Note] = []
    var reviewCardView: NSView!
    var reviewWordLabel: NSTextField!
    var reviewAnswerLabel: NSTextField!
    var cardPinned = false
    /// The app that was frontmost when the card/toolbar opened — the target
    /// for note-insert's paste-at-caret and handoff-style flows.
    var sourceApp: NSRunningApplication?
    var reviewRevealButton: NSButton!
    var reviewGradeButtons: [NSButton] = []
    var reviewEmptyLabel: NSTextField!
    var reviewCurrentWordId: Int64 = 0
    var runChipViews: [RunChipView] = []
    var runTabsContentWidth: CGFloat = 376
    // Card opens at the user's preferred size (drag-resizable; double-click
    // a resize zone still returns to the auto-size default).
    var cardUserWidth: CGFloat? = 428
    var cardUserHeight: CGFloat? = 400
    var resizeCorner: CardResizeZone!
    var resizeRight: CardResizeZone!
    var resizeBottom: CardResizeZone!
    var entryButtons: [NSButton] = []
    var listener: NWListener?
    let listenerQueue = DispatchQueue(label: "lexi.toolbar.display")
    /// Native settings window (full-Swift migration, phase 1). Created on
    /// first show; the app controller itself is nonisolated, so every touch
    /// hops through `MainActor.assumeIsolated` on the main queue.
    var settingsWindowController: LexiSettingsWindowController?
    let toolbarPort: UInt16

    override init() {
        toolbarPort = UInt16(SelectionToolbarApp.argumentValue("--toolbar-port") ?? "") ?? 43877
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("helper started bundle=\(Bundle.main.bundleIdentifier ?? "none") toolbarPort=\(toolbarPort)")
        LexiStore.ensureSchema()
        NSApp.setActivationPolicy(.accessory)
        installEditMenu()
        terminateOlderHelperInstances()
        buildPanel()
        buildResultCard()
        installMouseMonitors()
        installStatusItem()
        // Persisted panel style — previously pushed by the Rust /theme route,
        // which died with it. Must run AFTER the views exist: applyTheme
        // relayouts the card. Applies to toolbar, card, launcher, clipboard.
        PanelStyle.update(
            opacity: CGFloat(LexiStore.settingInt("panelOpacity", in: 10...90, default: 40)) / 100.0,
            blur: LexiStore.setting("panelBlur").flatMap(PanelStyle.Blur.init(rawValue:))
        )
        applyTheme(LexiStore.setting("theme") ?? "dark")
        refreshCardActions()
        startDisplayServer()
        shortcutMonitor = ShortcutMonitor(
            onLauncher: { [weak self] in
                self?.panels.present(.launcher)
                self?.launcherController.show()
            },
            onClipboard: { [weak self] in self?.showClipboardPanel() },
            onPopup: { [weak self] in self?.showPopupCard() }
        )
        shortcutMonitor?.onCopyCommand = { [weak self] in
            self?.selectionPipeline?.noteCopyCommand()
        }
        // Clipboard capture: own store + 0.5s poller.
        if let store = ClipboardStore.open() {
            clipboardController.attach(store: store)
            ClipboardMonitor.shared.start(store: store)
        } else {
            FileLog.write("CLIP store unavailable — capture disabled")
        }
        selectionPipeline = SelectionPipeline()
        selectionPipeline?.onSelection = { [weak self] text, point in
            self?.showToolbarFromSwift(text: text, at: point)
        }
        selectionPipeline?.ownFrames = {
            NSApp.windows.filter { $0.isVisible }.map(\.frame)
        }
        selectionPipeline?.start()
    }

    /// Audit trail for which surface the user last interacted with.
    /// Panels are independent — no hide callbacks, no cross-panel policy.
    lazy var panels: PanelCoordinator = PanelCoordinator()

    /// Global keyboard shortcuts (launcher + clipboard), in-process.
    var shortcutMonitor: ShortcutMonitor?
    var selectionPipeline: SelectionPipeline?
    var lastToolbarShow: (text: String, at: Date)?

    /// Dedup gate: identical selection text within 600ms shows once
    /// (selection drag and Cmd+C fallback can both fire for one gesture).
    func selectionShowGate(_ rawText: String) -> Bool {
        let key = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        if let last = lastToolbarShow, last.text == key, now.timeIntervalSince(last.at) < 0.6 {
            return false
        }
        lastToolbarShow = (key, now)
        return true
    }


    private static func argumentValue(_ name: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: name),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    /// Fresh notes snapshot from the DB — the card Notes tab and the
    /// clipboard panel's category tabs both render from it.
    static func cardNotesPayload() -> CardNotesPayload {
        let rows = LexiStore.notes(limit: 50)
        return CardNotesPayload(
            notes: rows.map {
                CardNotesPayload.Note(id: $0.id, name: $0.name, category: $0.categoryName, content: $0.content)
            },
            categories: LexiStore.noteCategories().map(\.name)
        )
    }

    /// The clipboard shortcut's local path: refresh the notes snapshot from
    /// the shared DB (the category tabs read it) and present the panel
    /// through the coordinator gate (retires toolbar/launcher first).
    func showClipboardPanel() {
        let payload = Self.cardNotesPayload()
        clipboardController.updateNotes(
            notes: payload.notes.map {
                ClipboardNote(
                    id: $0.id ?? 0, name: $0.name, content: $0.content,
                    category: $0.category)
            },
            categories: payload.categories ?? [])
        panels.present(.clipboard)
        clipboardController.show()
    }

    /// Layer-1 selection trigger from the helper's own tap.
    func showToolbarFromSwift(text: String, at point: NSPoint) {
        // NO gate here — showPanel has the only gate (dedup vs Rust's
        // /show). Gating in both places makes the second call self-reject.
        panels.present(.toolbar)
        showPanel(ShowPayload(text: text, x: Int(point.x), y: Int(point.y)))
    }

    /// The popup shortcut's action: open the idle card (Actions tab, no
    /// run yet) with the current selection pre-filled if available.
    /// Replaces Rust's trigger_popup_with_selection.
    func showPopupCard() {
        // The action bar must reflect the current enable/order config at
        // popup time, not whatever snapshot the last refresh left.
        refreshCardActions()
        // Try to read the current selection; empty = idle card with no input.
        let selection = SelectionPipeline.readSelectedText()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        showResultCard(ResultShowPayload(inputText: selection))
    }

    func terminateOlderHelperInstances() {
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

    /// The card's input-area button group: AI features only (the copy/
    /// search/read/note/handoff tools are toolbar-only). Also rebuilds the
    /// toolbar buttons and card tabs from one config snapshot, refreshed at
    /// launch and on every settings change.
    func refreshCardActions() {
        struct Entry {
            var order: Int
            var item: CardActionsPayload.Item
        }
        var entries: [Entry] = []
        for feature in LexiStore.features() where feature.enabled && !feature.id.isEmpty {
            entries.append(Entry(order: feature.sortOrder, item: .init(
                id: feature.id, name: feature.name.isEmpty ? "AI" : feature.name,
                icon: feature.icon.isEmpty ? "wand" : feature.icon, kind: "feature")))
        }

        // Toolbar scope: same registry, toolbar columns.
        var toolbar: [(order: Int, action: ToolbarAction)] = []
        for tool in LexiStore.toolbarTools() where tool.enabled && !tool.id.isEmpty {
            toolbar.append((tool.sortOrder, ToolbarAction(
                id: tool.id, title: tool.displayName,
                icon: tool.icon.isEmpty ? "wand" : tool.icon)))
        }
        for feature in LexiStore.features() where feature.enabled && !feature.id.isEmpty {
            toolbar.append((feature.sortOrder, ToolbarAction(
                id: feature.id, title: feature.name, icon: feature.icon)))
        }
        applyActions(toolbar.sorted { $0.order < $1.order }.map(\.action))

        // Panel tabs: DB rows + the built-ins appended when missing, then
        // canonical order (Actions, Review first).
        var panels = LexiStore.customPanels().map {
            CardActionsPayload.PanelDef(id: $0.id, name: $0.name, icon: $0.icon)
        }
        for (id, name, icon) in [("translate", "Actions", "file-text"), ("review", "Review", "book-open")]
        where !panels.contains(where: { $0.id == id }) {
            panels.append(CardActionsPayload.PanelDef(id: id, name: name, icon: icon))
        }
        let canonical = ["translate", "review"]
        var ordered: [CardActionsPayload.PanelDef] = []
        for id in canonical {
            if let index = panels.firstIndex(where: { $0.id == id }) {
                ordered.append(panels.remove(at: index))
            }
        }
        ordered.append(contentsOf: panels)

        FileLog.write("CARD actions refreshed tools+features=\(entries.count) panels=\(ordered.count)")
        handleCardActions(CardActionsPayload(
            actions: entries.map(\.item),
            panels: ordered
        ))
    }

    var statusItem: NSStatusItem?

    /// Menu-bar presence: the native successor to the tauri tray.
    func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Lexi")
        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(statusSettingsClicked), keyEquivalent: ",")
        let launcherItem = NSMenuItem(title: "Open Launcher", action: #selector(statusLauncherClicked), keyEquivalent: "l")
        let quitItem = NSMenuItem(title: "Quit Lexi", action: #selector(statusQuitClicked), keyEquivalent: "q")
        for entry in [settingsItem, launcherItem, quitItem] { entry.target = self }
        menu.addItem(settingsItem)
        menu.addItem(launcherItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
    }

    @objc func statusSettingsClicked() {
        showSettingsWindow()
    }

    @objc func statusLauncherClicked() {
        launcherController.show()
    }

    @objc func statusQuitClicked() {
        NSApp.terminate(nil)
    }
    func installMouseMonitors() {
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
            if event.keyCode == 53, let self { // kVK_Escape
                self.escapeResultCardIfNeeded()
            }
            if event.keyCode == 48, let self, self.resultPanel != nil {
                // Tab goes to whoever owns the keyboard — panels are
                // independent surfaces (a pinned card stays visible while
                // the clipboard panel is key and must not steal its Tab).
                if self.resultPanel.isKeyWindow {
                    self.cyclePanelTab()
                    return nil
                }
                if self.clipboardController.isKeyWindow {
                    self.clipboardController.cycleChipTabs()
                    return nil
                }
            }
            return event
        }
    }

    func escapeResultCardIfNeeded() {
        guard resultPanel?.isVisible == true, !cardPinned else { return }
        resultPanel.orderOut(nil)
        clearAllRuns(quietly: true)
    }

    func dismissalDistance(for location: NSPoint) -> CGFloat {
        let screenWidth = (NSScreen.screens.first { $0.frame.contains(location) } ?? NSScreen.main)?
            .frame.width ?? 1440
        return max(180, min(screenWidth * 0.12, 280))
    }

    func hideIfCursorFarAway() {
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

    func restateCardChromeTints() {
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

    func applyCardTheme() {
        restateCardChromeTints()
        let controlStroke = PanelStyle.controlBorder(dark: theme == .dark)
        let appearance = theme == .dark
            ? NSAppearance(named: .vibrantDark)
            : NSAppearance(named: .vibrantLight)

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

    var isInputFocused = false

    func setInputFocused(_ focused: Bool) {
        isInputFocused = focused
        styleCardInputs(focused: focused ? .actions : .none)
    }

    /// Both card inputs (Actions bar + Notes search) share ONE surface
    /// definition: same fill, hairline, radius, placeholder tint. Focus
    /// (per field) deepens the border.
    enum CardInputFocus { case none, actions, search }

    func styleCardInputs(focused: CardInputFocus = .none) {
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

    func showSettingsWindow(tab: SettingsTab = .general) {
        panels.present(.settings)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
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
                    // Opacity/blur changes must repaint the live scrims too —
                    // PanelStyle.update only retunes materials. Reapplying the
                    // current theme re-derives every scrim from the new values.
                    self?.applyTheme(theme ?? (self?.theme ?? .dark).rawValue)
                    // The settings window itself follows the app theme so the
                    // Appearance controls have a visible effect in place.
                    controller.applyWindowAppearance(dark: (self?.theme ?? .dark) == .dark)
                }
                controller.onNativeSettingsReload = { [weak self] in
                    self?.shortcutMonitor?.reload()
                    self?.selectionPipeline?.reload()
                    self?.refreshCardActions()
                }
                controller.show(tab: tab)
                // Match the window chrome to the persisted theme immediately —
                // onPanelStyleChange only fires on the next change.
                controller.applyWindowAppearance(dark: self.theme == .dark)
            }
        }
    }

    func hideIfClickOutsidePanel(_ event: NSEvent) {
        let screenPoint = NSEvent.mouseLocation
        FileLog.write("DOWN point=\(screenPoint) win=\(event.window.map { "\($0)" } ?? "nil") cardFrame=\(NSStringFromRect(resultPanel.frame)) tvFrame=\(NSStringFromRect(notesTableView.frame)) tvVisible=\(NSStringFromRect(notesTableView.visibleRect))")

        // Result card: pinned cards stay until unpinned (pin button again).
        // Unpinned: hide; the runs stay in memory for the tabs bar.
        if resultPanel.isVisible,
           !cardPinned,
           event.window !== resultPanel,
           !resultPanel.frame.contains(screenPoint) {
            resultPanel.orderOut(nil)
            clearAllRuns(quietly: true)
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
    }
    @objc func runToolbarAction(_ sender: NSButton) {
        guard let action = sender.identifier?.rawValue, !selectedText.isEmpty else {
            return
        }
        // Speech + builtin tools (incl. handoff) run in-process.
        if action == "read" || action == "speak" {
            LexiSpeech.shared.speak(text: selectedText)
        } else if action == "copy" {
            LexiTools.copy(text: selectedText)
        } else if action == "search" {
            LexiTools.search(text: selectedText)
        } else if action == "note" {
            LexiTools.note(text: selectedText)
        } else if action == "handoff" {
            LexiTools.handoff(text: selectedText)
        } else {
            runFeatureLocally(featureId: action, text: selectedText)
        }
        hidePanel(force: true)
    }

    /// Local handling for every former Rust round-trip action. Rust is
    /// gone: DB writes, tool execution, and quit all happen here.
    func handleAction(action: String, text: String) {
        switch action {
        case "quit-lexi":
            NSApp.terminate(nil)
        case "save-vocab":
            saveVocabAction(text)
        case "note-delete":
            if let id = Int64(text.trimmingCharacters(in: .whitespaces)) {
                LexiStore.deleteNote(id: id)
                reloadCardNotes()
            }
        case "note-rename":
            if let data = text.data(using: .utf8),
               let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = value["id"] as? Int64,
               let name = value["name"] as? String {
                LexiStore.updateNoteName(id: id, name: name)
                reloadCardNotes()
            }
        case "note-tag-create":
            LexiStore.createNoteCategory(name: text)
            reloadCardNotes()
        case "note-tag":
            // Move a note to a category ("id|Category Name").
            let parts = text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            if let id = Int64(parts.first ?? ""), let name = parts.last, !name.isEmpty {
                LexiStore.setNoteCategory(
                    id: id,
                    categoryId: LexiStore.noteCategoryIdOrCreate(named: String(name))
                )
                reloadCardNotes()
            }
        case "note-create":
            if let data = text.data(using: .utf8),
               let value = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                LexiStore.insertNote(
                    name: value["name"] ?? "", content: value["content"] ?? "",
                    category: value["tag"] ?? ""
                )
                reloadCardNotes()
            }
        case "note-tag-reorder":
            if let data = text.data(using: .utf8),
               let names = try? JSONSerialization.jsonObject(with: data) as? [String] {
                LexiStore.reorderNoteCategories(byNames: names)
                reloadCardNotes()
            }
        case "note-insert":
            ClipboardPaster.pasteString(text, previousApp: sourceApp)
        case "handoff":
            LexiTools.handoff(text: text)
        default:
            FileLog.write("ACTION dropped \(action) (no local handler)")
        }
    }

    func splitTagPayload(_ text: String) -> (Int64, String)? {
        let parts = text.components(separatedBy: "|")
        guard parts.count == 2, let id = Int64(parts[0].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return (id, parts[1])
    }

    /// Save button on the card: persist the run's translation JSON with the
    /// entry type the user picked (Rust save_vocab_action parity).
    func saveVocabAction(_ text: String) {
        guard let data = text.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let word = payload["word"] as? String,
              !word.trimmingCharacters(in: .whitespaces).isEmpty else {
            return
        }
        let field = { (key: String) -> String in payload[key] as? String ?? "" }
        let entryType = field("entryType").isEmpty ? "word" : field("entryType")
        LexiStore.insertWord(
            word: word, translation: field("translation"), pos: field("pos"),
            definition: field("definition"), example: field("example"),
            entryType: entryType, sourceText: field("sourceText")
        )
    }

    /// Refresh the card's notes tab from the DB after a local write.
    func reloadCardNotes() {
        handleCardNotes(Self.cardNotesPayload())
    }

    func log(_ message: String) {
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


    func startDisplayServer() {
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

    func receive(_ connection: NWConnection, accumulated: Data = Data()) {
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


    func toolbarWidth(for actionCount: Int) -> CGFloat {
        toolbarHandleWidth + CGFloat(max(actionCount, 1)) * toolbarSegmentWidth
    }
}

import AppKit
import Foundation


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
    var hairline: NSColor {
        NSColor.black.withAlphaComponent(isDark ? 0.35 : 0.12)
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
            case .list: return 20
            case .card: return 22
            case .launcher: return 24
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
    /// Off the caller's thread — the launcher logs per keystroke, and a
    /// synchronous open/seek/write/close there is measurable jank.
    private static let queue = DispatchQueue(label: "lexi.filelog", qos: .utility)

    static func write(_ message: String) {
        let line = "\(Date()) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.closeFile() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logURL)
            }
        }
    }
}

let toolbarHandleWidth: CGFloat = 16
let toolbarSegmentWidth: CGFloat = 30
let toolbarHeight: CGFloat = 28
let toolbarIconSize: CGFloat = 14
let toolbarVerticalGap: CGFloat = 6
let resultCardWidth: CGFloat = 420

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

/// Vivid variant for tab chips, glyphs and section headers: the
/// deterministic tag hue pushed to full saturation/brightness — calm
/// `tagColor` stays the source where text contrast matters on light
/// surfaces.
func vividTagColor(for tag: String, dark: Bool) -> NSColor {
    let base = tagColor(for: tag, dark: dark)
    guard let rgb = base.usingColorSpace(.deviceRGB) else { return base }
    return NSColor(
        hue: rgb.hueComponent,
        saturation: min(1, rgb.saturationComponent + 0.25),
        brightness: 1,
        alpha: 1)
}

/// Finder's seven fixed tag color slots, by the index stored on disk in
/// `com.apple.metadata:_kMDItemUserTags` ("Name\nN"). Same swatches in
/// both appearances — Finder does not vary them. 0 / unknown → nil (the
/// caller falls back to the deterministic tag hue).
func finderTagColor(_ index: Int) -> NSColor? {
    switch index {
    case 1: return NSColor(red: 1.000, green: 0.231, blue: 0.188, alpha: 1)  // red    #FF3B30
    case 2: return NSColor(red: 1.000, green: 0.584, blue: 0.000, alpha: 1)  // orange #FF9500
    case 3: return NSColor(red: 1.000, green: 0.800, blue: 0.000, alpha: 1)  // yellow #FFCC00
    case 4: return NSColor(red: 0.204, green: 0.780, blue: 0.349, alpha: 1)  // green  #34C759
    case 5: return NSColor(red: 0.000, green: 0.478, blue: 1.000, alpha: 1)  // blue   #007AFF
    case 6: return NSColor(red: 0.686, green: 0.322, blue: 0.871, alpha: 1)  // purple #AF52DE
    case 7: return NSColor(red: 0.557, green: 0.557, blue: 0.576, alpha: 1)  // gray   #8E8E93
    default: return nil
    }
}


enum ToolbarTheme: String {
    case dark
    case light


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

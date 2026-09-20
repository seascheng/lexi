import AppKit

/// Lexi 品牌标记（卡片叠层 L）——加载 bundle 资源 LexiLogo.svg，
/// 栅格化为模板位图：跟随系统明暗自动反色。源文件见
/// `artwork/lexi-logo-c-cards.svg`，由 build.sh 拷入两个 bundle。
enum LexiLogo {
    /// 菜单栏状态图标（约 16pt，2x 栅格化保证清晰）。
    static let menuBarImage: NSImage? = templateImage(pointSize: 16)
    /// Dock/Cmd+Tab 图标：直接加载 bundle 内的 AppIcon.icns。LSUIElement
    /// 应用开窗进 Dock 时 tile 取 NSApplication.applicationIconImage——
    /// 不设就是白板。
    static let appIcon: NSImage? = Bundle.main
        .url(forResource: "AppIcon", withExtension: "icns")
        .flatMap { NSImage(contentsOfFile: $0.path) }

    static func templateImage(pointSize: CGFloat) -> NSImage? {
        guard let url = Bundle.main.url(forResource: "LexiLogo", withExtension: "svg"),
              let svg = NSImage(contentsOfFile: url.path) else { return nil }
        let size = NSSize(width: pointSize, height: pointSize)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * 2,
            pixelsHigh: Int(size.height) * 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        svg.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }
}

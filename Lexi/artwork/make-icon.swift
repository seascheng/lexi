import AppKit

// 生成 Dock/App 图标 AppIcon.icns 的源 PNG 集。
// 设计：墨色 #2c2c2c 圆角方形底 + 白色卡片叠层 L（黑色原稿反转，
// 深浅 Dock 皆可读）。输出 AppIcon.iconset/ 到指定目录。
//
// 用法: swift make-icon.swift <输出目录>

let arguments = CommandLine.arguments
let outDir = arguments.count > 1
    ? URL(fileURLWithPath: arguments[1])
    : URL(fileURLWithPath: "AppIcon.iconset")

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let source = here.appendingPathComponent("lexi-logo-c-cards.svg")

guard let svgText = try? String(contentsOf: source, encoding: .utf8) else {
    FileHandle.standardError.write("cannot read \(source.path)\n".data(using: .utf8)!)
    exit(1)
}
// 白色变体：图标用白剪影，负形透出底色。按裸色值替换，
// 兼容属性式 fill="#000000" 与 CSS 式两种写法。
let whiteSVG = svgText.replacingOccurrences(of: "#000000", with: "#FFFFFF")
let whiteURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("lexi-logo-white.svg")
try? whiteSVG.write(to: whiteURL, atomically: true, encoding: .utf8)

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func render(size: Int) -> Data? {
    guard let glyph = NSImage(contentsOfFile: whiteURL.path) else { return nil }
    let f = CGFloat(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: f, height: f)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // Apple 图标栅格：squircle 底占画布 824/1024（四周 ~10% 透明边），
    // Dock 不做遮罩按画布原样渲染——满幅会比邻居大一圈。
    // 圆角 ~22.37%（连续曲率 squircle 的近似）。
    let margin = f * (100.0 / 1024.0)
    let background = NSColor(red: 0x2c/255, green: 0x2c/255, blue: 0x2c/255, alpha: 1)
    background.setFill()
    NSBezierPath(roundedRect: NSRect(
        x: margin, y: margin, width: f - 2 * margin, height: f - 2 * margin),
        xRadius: (f - 2 * margin) * 0.2237,
        yRadius: (f - 2 * margin) * 0.2237).fill()
    // 字形高度按 squircle 内高的 60% 居中。
    let glyphHeight = (f - 2 * margin) * 0.60
    let glyphWidth = glyphHeight * 44.0 / 52.0
    let glyphRect = NSRect(
        x: (f - glyphWidth) / 2, y: (f - glyphHeight) / 2,
        width: glyphWidth, height: glyphHeight)
    glyph.draw(in: glyphRect)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let entries: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
var written = 0
// 同尺寸只栅格化一次。
var cache: [Int: Data?] = [:]
for (name, size) in entries {
    let data: Data?
    if let cached = cache[size] { data = cached }
    else { data = render(size: size); cache[size] = data }
    if let data {
        try? data.write(to: outDir.appendingPathComponent(name))
        written += 1
    }
}
print("wrote \(written)/10 pngs to \(outDir.path)")
exit(written == 10 ? 0 : 1)

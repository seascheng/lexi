import AppKit

// 确定性校验：栅格化 SVG，输出每行黑像素范围。
// 用法: swift render-check.swift <svg>...
for path in CommandLine.arguments.dropFirst() {
    guard let image = NSImage(contentsOfFile: path) else {
        print("\(path): LOAD FAILED"); continue
    }
    let size = 128
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
        print("\(path): REP FAILED"); continue
    }
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()

    var minX = size, maxX = 0, minY = size, maxY = 0, dark = 0
    var rowExtents: [(Int, Int, Int)] = []  // y, minX, maxX (top-down)
    for y in 0..<size {
        var rowMin = size, rowMax = -1
        for x in 0..<size {
            guard let c = rep.colorAt(x: x, y: y) else { continue }
            if c.alphaComponent > 0.5 && c.brightnessComponent < 0.5 {
                dark += 1
                rowMin = min(rowMin, x); rowMax = max(rowMax, x)
            }
        }
        if rowMax >= 0 {
            minX = min(minX, rowMin); maxX = max(maxX, rowMax)
            minY = min(minY, y); maxY = max(maxY, y)
            rowExtents.append((y, rowMin, rowMax))
        }
    }
    let name = (path as NSString).lastPathComponent
    print("\(name): bbox=(\(minX),\(minY))-(\(maxX),\(maxY)) dark=\(dark) fill=\(Double(dark)/Double(size*size))")
    // 每隔 8 行采样输出范围，肉眼比对上下卡对齐
    for (y, a, b) in rowExtents where y % 8 == 0 {
        print("  y=\(y) x=\(a)..\(b)")
    }
}

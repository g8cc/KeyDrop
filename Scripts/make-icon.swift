import AppKit

// 可重建的原始矢量绘制,每个尺寸独立渲染,保留透明边缘。
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources")
let iconset = root.appendingPathComponent(".build/KeyDrop.iconset")
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
}
func render(_ pixels: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 202, yRadius: 202)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.26)
    shadow.shadowBlurRadius = 22
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0.06, 0.13, 0.15).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0.13, 0.25, 0.27), ending: color(0.035, 0.085, 0.11))!.draw(in: tile, angle: -70)
    NSColor.white.withAlphaComponent(0.12).setStroke()
    tile.lineWidth = 2
    tile.stroke()

    // 宽线条与开放空间在 16/32px 下仍能保持辨识度。
    let gold = color(1, 0.78, 0.37)
    let shaft = NSBezierPath()
    shaft.move(to: NSPoint(x: 452, y: 579))
    shaft.line(to: NSPoint(x: 667, y: 364))
    shaft.lineWidth = 76
    shaft.lineCapStyle = .round
    gold.setStroke()
    shaft.stroke()
    let teeth = NSBezierPath()
    teeth.move(to: NSPoint(x: 560, y: 470))
    teeth.line(to: NSPoint(x: 616, y: 526))
    teeth.move(to: NSPoint(x: 625, y: 405))
    teeth.line(to: NSPoint(x: 681, y: 461))
    teeth.lineWidth = 62
    teeth.lineCapStyle = .round
    teeth.stroke()
    let bow = NSBezierPath(ovalIn: NSRect(x: 274, y: 558, width: 252, height: 252))
    bow.lineWidth = 72
    bow.stroke()

    let tray = NSBezierPath()
    tray.move(to: NSPoint(x: 290, y: 329))
    tray.line(to: NSPoint(x: 290, y: 251))
    tray.curve(to: NSPoint(x: 328, y: 213), controlPoint1: NSPoint(x: 290, y: 225), controlPoint2: NSPoint(x: 302, y: 213))
    tray.line(to: NSPoint(x: 696, y: 213))
    tray.curve(to: NSPoint(x: 734, y: 251), controlPoint1: NSPoint(x: 722, y: 213), controlPoint2: NSPoint(x: 734, y: 225))
    tray.line(to: NSPoint(x: 734, y: 329))
    tray.lineWidth = 46
    tray.lineCapStyle = .round
    color(0.56, 0.79, 0.77).setStroke()
    tray.stroke()
    return bitmap.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try render(size * scale).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
try render(1024).write(to: resources.appendingPathComponent("KeyDrop.png"))
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("KeyDrop.icns").path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
print("已生成 Resources/KeyDrop.icns 与 1024px 预览")

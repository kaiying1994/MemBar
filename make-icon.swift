// make-icon.swift —— 生成 MemBar.icns
// 用法： swiftc -O -o /tmp/makeicon make-icon.swift && /tmp/makeicon
// 造型：macOS 规范圆角方（squircle）+ 投影 + 深靛蓝底 + 绿色进度环（与菜单栏 ring 样式同源）
import Cocoa

let sizes: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

let outDir = "/Users/kainglee/MemBar/MemBar.iconset"
try? FileManager.default.removeItem(atPath: outDir)
try! FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

/// Apple 图标网格：1024 画布，圆角方占 824，四周各留 100
func squirclePath(in rect: NSRect, n: CGFloat = 5.0) -> NSBezierPath {
    // 用超椭圆参数方程逼近（比圆角矩形更接近 Apple 的 continuous corner）
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    let p = NSBezierPath()
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * copysign(pow(abs(ct), 2 / n), ct)
        let y = cy + b * copysign(pow(abs(st), 2 / n), st)
        if i == 0 { p.move(to: NSPoint(x: x, y: y)) } else { p.line(to: NSPoint(x: x, y: y)) }
    }
    p.close()
    return p
}

func drawIcon(size s: CGFloat) -> NSBitmapImageRep {
    let px = Int(s)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let scale = s / 1024.0
    let inset: CGFloat = 100 * scale
    let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)

    // 投影
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.shadowBlurRadius = 26 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -12 * scale)
    shadow.set()

    // 底色：深靛蓝竖向渐变
    let bodyPath = squirclePath(in: body)
    NSGraphicsContext.saveGraphicsState()
    bodyPath.addClip()
    let grad = NSGradient(colors: [
        NSColor(srgbRed: 0.148, green: 0.180, blue: 0.322, alpha: 1),
        NSColor(srgbRed: 0.073, green: 0.094, blue: 0.190, alpha: 1),
    ])!
    grad.draw(in: body, angle: -90)
    // 顶部高光
    let hl = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.16),
        NSColor.white.withAlphaComponent(0.0),
    ])!
    hl.draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // 进度环
    let ringW = 62 * scale
    let d = 340 * scale
    let r = (d - ringW) / 2
    let c = NSPoint(x: s / 2, y: s / 2)

    let track = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    track.lineWidth = ringW
    NSColor.white.withAlphaComponent(0.16).setStroke()
    track.stroke()

    let ratio: CGFloat = 0.72
    let arc = NSBezierPath()
    arc.appendArc(withCenter: c, radius: r, startAngle: 90, endAngle: 90 - 360 * ratio, clockwise: true)
    arc.lineWidth = ringW
    arc.lineCapStyle = .round
    NSColor(srgbRed: 0.20, green: 0.83, blue: 0.45, alpha: 1).setStroke()
    arc.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (size, name) in sizes {
    let rep = drawIcon(size: CGFloat(size))
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    let url = URL(fileURLWithPath: "\(outDir)/\(name).png")
    try! data.write(to: url)
    print("wrote \(name).png  \(size)x\(size)")
}
print("iconset done -> \(outDir)")

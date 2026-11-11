// Draws Blink's app icon. Run: swift scripts/make-icon.swift  → Resources/AppIcon.icns + docs/icon.png
import AppKit

let size: CGFloat = 1024

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
    // macOS icon grid: 824pt body centred in 1024 with a soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)

    ctx.saveGState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    ctx.restoreGState()

    ctx.saveGState()
    shape.addClip()
    // Deep indigo → electric blue.
    NSGradient(colors: [NSColor(srgbRed: 0.24, green: 0.15, blue: 0.78, alpha: 1),
                        NSColor(srgbRed: 0.33, green: 0.30, blue: 0.96, alpha: 1),
                        NSColor(srgbRed: 0.10, green: 0.62, blue: 1.00, alpha: 1)],
               atLocations: [0, 0.5, 1], colorSpace: .sRGB)!.draw(in: body, angle: -55)
    // A glassy sheen across the top.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.26), NSColor.white.withAlphaComponent(0)])!
        .draw(in: CGRect(x: 100, y: 470, width: 824, height: 454), angle: -90)

    // The caret: a text cursor, mid-blink.
    ctx.saveGState()
    let glow = NSShadow()
    glow.shadowColor = NSColor(srgbRed: 0.78, green: 0.92, blue: 1, alpha: 0.95)
    glow.shadowBlurRadius = 70
    glow.shadowOffset = .zero
    glow.set()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: CGRect(x: 512 - 46, y: 512 - 250, width: 92, height: 500), xRadius: 46, yRadius: 46).fill()
    ctx.restoreGState()
    ctx.restoreGState()

    // Fine highlight on the edge.
    NSColor.white.withAlphaComponent(0.18).setStroke()
    shape.lineWidth = 3
    shape.stroke()
    return true
}

func png(_ img: NSImage, _ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! png(image, base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! png(image, base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! png(image, 512).write(to: URL(fileURLWithPath: "docs/icon.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns and docs/icon.png" : "iconutil failed")

// Renders the MagGlow app icon (MagSafe connector with a green LED) into
// an .iconset folder. Usage: swift scripts/make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let k = s / 1024

    // macOS icon grid: 824 pt body inset 100 pt, continuous corners.
    let body = NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * k, yRadius: 185 * k)
    NSGradient(starting: NSColor(calibratedWhite: 0.24, alpha: 1),
               ending: NSColor(calibratedWhite: 0.11, alpha: 1))!
        .draw(in: squircle, angle: -90)

    // Glyph on the same 24-unit grid as the menu bar icon.
    let u = 824 * k * 0.78 / 24
    let ox = body.minX + (body.width - 24 * u) / 2 + 0.5 * u
    let oy = body.minY + (body.height - 24 * u) / 2
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: ox + x * u, y: oy + y * u, width: w * u, height: h * u)
    }

    NSColor.white.set()
    let plug = NSBezierPath(roundedRect: r(2.5, 7.5, 14, 9), xRadius: 4.5 * u, yRadius: 4.5 * u)
    plug.lineWidth = 1.6 * u
    plug.stroke()
    let cable = NSBezierPath()
    cable.move(to: NSPoint(x: ox + 16.5 * u, y: oy + 12 * u))
    cable.line(to: NSPoint(x: ox + 22 * u, y: oy + 12 * u))
    cable.lineWidth = 1.6 * u
    cable.lineCapStyle = .round
    cable.stroke()

    let green = NSColor(calibratedRed: 0.44, green: 0.85, blue: 0.33, alpha: 1)
    let shadow = NSShadow()
    shadow.shadowColor = green.withAlphaComponent(0.9)
    shadow.shadowBlurRadius = 1.6 * u
    shadow.set()
    green.set()
    NSBezierPath(ovalIn: r(5.3, 9.8, 4.4, 4.4)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

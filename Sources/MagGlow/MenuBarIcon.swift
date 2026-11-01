import AppKit

/// The menu bar glyph: a MagSafe connector whose LED is a dot. Drawn on a
/// 24-unit grid and scaled to 18 pt, as a template image so macOS tints it
/// like the system's own icons.
enum MenuBarIcon {
    enum LED { case on, off }

    static func image(led: LED) -> NSImage {
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let scale = size / 24
            let transform = NSAffineTransform()
            transform.scale(by: scale)
            transform.concat()

            NSColor.black.set()

            let body = NSBezierPath(roundedRect: NSRect(x: 2.5, y: 7.5, width: 14, height: 9), xRadius: 4.5, yRadius: 4.5)
            body.lineWidth = 2
            body.stroke()

            let cable = NSBezierPath()
            cable.move(to: NSPoint(x: 16.5, y: 12))
            cable.line(to: NSPoint(x: 22, y: 12))
            cable.lineWidth = 2
            cable.lineCapStyle = .round
            cable.stroke()

            let dot = NSBezierPath(ovalIn: NSRect(x: 5.4, y: 9.9, width: 4.2, height: 4.2))
            switch led {
            case .on:
                dot.fill()
            case .off:
                let ring = NSBezierPath(ovalIn: NSRect(x: 6, y: 10.5, width: 3, height: 3))
                ring.lineWidth = 1.2
                ring.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

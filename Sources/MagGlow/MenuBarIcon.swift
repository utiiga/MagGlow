import AppKit

/// The menu bar glyph: a MagSafe connector whose LED is a dot. Drawn on a
/// 24-unit grid at 1 pt per unit, cropped to the glyph (22 × 14 pt) so it
/// fills the menu bar like the system's icons. A template image, so macOS
/// tints it like them.
enum MenuBarIcon {
    enum LED { case on, off }

    /// Time left for the menu bar: "42 min", or "7 h 42 min" from an hour up.
    static func shortTime(_ interval: TimeInterval) -> String {
        let minutes = Int((interval / 60).rounded(.up))
        if minutes < 60 { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
    }

    static func image(led: LED) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 14), flipped: false) { _ in
            // The glyph spans x 1.5–23 and y 6.5–17.5 on the grid; centre it.
            let transform = NSAffineTransform()
            transform.translateX(by: -1.25, yBy: -5)
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

import AppKit

/// Menu bar mark matching the app icon: a front window card with a "Z" cut out of it, and a second card
/// peeking out behind. Drawn as a template image, so macOS tints it for light, dark and highlighted menu bars.
enum MenuBarIcon {
    static func make() -> NSImage {
        let size = NSSize(width: 20, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current else { return false }
            NSColor.black.set()

            // Back card: just its top and right edges show above/beside the front card.
            let back = NSBezierPath(roundedRect: NSRect(x: 5.5, y: 4.5, width: 13.5, height: 10.5), xRadius: 2.6, yRadius: 2.6)
            back.lineWidth = 1.4
            back.stroke()

            // Clear a gap around the front card so the two cards read as separate layers.
            ctx.compositingOperation = .clear
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 16.4, height: 12.4), xRadius: 3.4, yRadius: 3.4).fill()

            // Front card, solid.
            ctx.compositingOperation = .sourceOver
            NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 14.4, height: 10.4), xRadius: 2.6, yRadius: 2.6).fill()

            // Z knocked out of the front card.
            ctx.compositingOperation = .destinationOut
            let z = NSBezierPath()
            z.move(to: NSPoint(x: 5.0, y: 8.9)); z.line(to: NSPoint(x: 11.4, y: 8.9))
            z.line(to: NSPoint(x: 11.4, y: 7.6)); z.line(to: NSPoint(x: 7.2, y: 3.8))
            z.line(to: NSPoint(x: 11.4, y: 3.8)); z.line(to: NSPoint(x: 11.4, y: 2.5))
            z.line(to: NSPoint(x: 5.0, y: 2.5)); z.line(to: NSPoint(x: 5.0, y: 3.8))
            z.line(to: NSPoint(x: 9.2, y: 7.6)); z.line(to: NSPoint(x: 5.0, y: 7.6))
            z.close()
            z.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Zuvi Tab"
        return image
    }
}

// Renders the Zuvi Tab app icon and builds Resources/AppIcon.icns.
// Usage: swift tools/make-icon.swift   (run from the project root)
import AppKit

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let k = CGFloat(px) / 1024          // design on a 1024 grid, Apple's icon template proportions
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * k, y: y * k, width: w * k, height: h * k) }

    // Body: squircle-ish rounded square with a soft drop shadow.
    let body = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * k, yRadius: 185 * k)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28 * k
    shadow.shadowOffset = NSSize(width: 0, height: -12 * k)
    shadow.set()
    NSColor.black.setFill(); body.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(srgbRed: 0.11, green: 0.10, blue: 0.27, alpha: 1),
                        NSColor(srgbRed: 0.35, green: 0.22, blue: 0.85, alpha: 1),
                        NSColor(srgbRed: 0.62, green: 0.36, blue: 0.98, alpha: 1)])!
        .draw(in: body, angle: 60)

    // Three stacked window cards, back to front.
    let cards: [(CGFloat, CGFloat, CGFloat)] = [(330, 632, 0.28), (270, 562, 0.5), (210, 492, 1.0)]
    for (i, (x, y, a)) in cards.enumerated() {
        let card = r(x, y - 240, 480, 340)
        let path = NSBezierPath(roundedRect: card, xRadius: 44 * k, yRadius: 44 * k)
        NSColor.white.withAlphaComponent(a).setFill(); path.fill()
        if i == cards.count - 1 {
            // Title-bar dots on the front card.
            for (j, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                c.setFill()
                NSBezierPath(ovalIn: r(x + 40 + CGFloat(j) * 46, y + 40, 26, 26)).fill()
            }
            // The Z, in the icon's violet.
            let para = NSMutableParagraphStyle(); para.alignment = .center
            let z = NSAttributedString(string: "Z", attributes: [
                .font: NSFont.systemFont(ofSize: 250 * k, weight: .black),
                .foregroundColor: NSColor(srgbRed: 0.33, green: 0.20, blue: 0.82, alpha: 1),
                .paragraphStyle: para,
            ])
            z.draw(in: r(x, y - 250, 480, 300))
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let iconset = "build/AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(base * scale).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(iconset)/\(name)"))
    }
}
try! fm.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
try! render(1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/icon-preview.png"))
print(p.terminationStatus == 0 ? "Resources/AppIcon.icns written" : "iconutil failed")

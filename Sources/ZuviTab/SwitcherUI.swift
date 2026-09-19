import AppKit

enum TileAction { case close, minimize, quit }

final class SwitcherView: NSView {
    var items: [SwitchItem] = [] { didSet { needsDisplay = true } }
    var thumbnails: [CGWindowID: CGImage] = [:] { didSet { needsDisplay = true } }
    var selected = 0 { didSet { if selected != oldValue { needsDisplay = true; onSelectionChange?() } } }
    /// Off on Liquid Glass: the selection is a real glass piece placed by the panel instead.
    var drawsSelection = true
    var onSelectionChange: (() -> Void)?
    var emptyText: String? { didSet { needsDisplay = true } }
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    var onAction: ((Int, TileAction) -> Void)?
    private(set) var columns = 1
    private var tile = CGSize(width: 128, height: 118)
    private var thumbsOn = false
    private var hovered: Int?
    private var hoverPoint = NSPoint.zero
    private let pad: CGFloat = 18, gap: CGFloat = 8, captionH: CGFloat = 26, buttonSize: CGFloat = 18

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Lays out tiles in wrapping rows; shrinks tiles if the grid would not fit the screen.
    func configure(_ items: [SwitchItem], thumbnailsOn: Bool, maxWidth: CGFloat, maxHeight: CGFloat) -> NSSize {
        self.items = items
        thumbsOn = thumbnailsOn
        if let h = hovered, !items.indices.contains(h) { hovered = nil }
        var scale: CGFloat = 1
        let base = thumbnailsOn ? CGSize(width: 232, height: 172) : CGSize(width: 128, height: 118)
        while true {
            tile = CGSize(width: base.width * scale, height: base.height * scale)
            let fit = max(1, Int((maxWidth - 2 * pad + gap) / (tile.width + gap)))
            columns = max(1, min(items.count, fit))
            let rows = (items.count + columns - 1) / columns
            let size = NSSize(width: 2 * pad + CGFloat(columns) * tile.width + CGFloat(columns - 1) * gap,
                              height: 2 * pad + CGFloat(rows) * tile.height + CGFloat(max(0, rows - 1)) * gap + captionH)
            if size.height <= maxHeight || scale < 0.5 { return size }
            scale *= 0.85
        }
    }

    private func rect(at i: Int) -> NSRect {
        let col = i % columns, row = i / columns
        return NSRect(x: pad + CGFloat(col) * (tile.width + gap),
                      y: pad + CGFloat(row) * (tile.height + gap),
                      width: tile.width, height: tile.height)
    }

    private func index(at p: NSPoint) -> Int? { items.indices.first { rect(at: $0).contains(p) } }

    /// Where the selected tile is, for the glass selection piece.
    func selectionRect() -> NSRect? { items.indices.contains(selected) && emptyText == nil ? rect(at: selected) : nil }

    /// Close and minimize need a real window; quit works for any app entry; desktops get none.
    private func buttons(for i: Int) -> [(TileAction, NSRect)] {
        guard !items[i].isDesktopEntry else { return [] }
        let r = rect(at: i)
        var actions: [TileAction] = items[i].axWindow != nil ? [.close, .minimize] : []
        actions.append(.quit)
        return actions.enumerated().map { k, a in
            (a, NSRect(x: r.minX + 8 + CGFloat(k) * (buttonSize + 6), y: r.minY + 8, width: buttonSize, height: buttonSize))
        }
    }

    private func hoveredAction() -> TileAction? {
        guard let h = hovered, items.indices.contains(h) else { return nil }
        return buttons(for: h).first { $0.1.contains(hoverPoint) }?.0
    }

    override func draw(_ dirtyRect: NSRect) {
        if let emptyText {
            drawText(emptyText, in: NSRect(x: pad, y: bounds.midY - 12, width: bounds.width - 2 * pad, height: 20),
                     size: 13, alpha: 0.7)
            return
        }
        for (i, item) in items.enumerated() {
            let r = rect(at: i)
            if i == selected && drawsSelection {
                let hl = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
                NSColor.labelColor.withAlphaComponent(0.14).setFill(); hl.fill()
                NSColor.labelColor.withAlphaComponent(0.4).setStroke(); hl.lineWidth = 1.5; hl.stroke()
            }
            drawWindow(item, index: i, in: r)
        }
        if items.indices.contains(selected) {
            let it = items[selected]
            var caption: String
            switch hoveredAction() {
            case .close?: caption = "Close window"
            case .minimize?: caption = "Minimize window"
            case .quit?: caption = "Quit \(it.appName)"
            case nil:
                if it.isDesktopEntry {
                    caption = it.title
                } else {
                    caption = it.title == it.appName ? it.appName : "\(it.appName)  ·  \(it.title)"
                }
            }
            drawText(caption, in: NSRect(x: pad, y: bounds.height - pad - captionH + 8,
                                         width: bounds.width - 2 * pad, height: 18),
                     size: 13, alpha: 1, bold: true)
        }
    }

    private func drawWindow(_ item: SwitchItem, index i: Int, in r: NSRect) {
        let alpha: CGFloat = (item.isMinimized || item.isAppHidden) ? 0.55 : 1
        let imageArea = NSRect(x: r.minX + 10, y: r.minY + 10, width: r.width - 20, height: r.height - 38)
        let icon = item.app.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)

        if item.isEmptyDesktop {
            let area = aspectFit(NSSize(width: 16, height: 10), in: imageArea)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: area, xRadius: 6, yRadius: 6).addClip()
            if let wallpaper = Wallpaper.image(spaceUUID: item.desktopUUID) {
                wallpaper.draw(in: aspectFill(wallpaper.size, in: area), from: .zero, operation: .copy,
                               fraction: 1, respectFlipped: true, hints: nil)
            } else {
                NSColor(white: 0.25, alpha: 1).setFill(); area.fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        } else if let id = item.windowID, let cg = thumbnails[id] {
            let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            let fit = aspectFit(img.size, in: imageArea)
            img.draw(in: fit, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
            let badge = min(30, imageArea.height * 0.3)
            icon?.draw(in: NSRect(x: fit.minX - 4, y: fit.maxY - badge + 4, width: badge, height: badge),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            let side = min(imageArea.width, imageArea.height, thumbsOn ? 84 : 72)
            icon?.draw(in: NSRect(x: imageArea.midX - side / 2, y: imageArea.midY - side / 2, width: side, height: side),
                       from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
        }

        // Only badge: the lock, because it's the one thing that explains a missing preview.
        if item.isSensitive || item.captureBlocked { drawSymbol("lock.fill", at: NSPoint(x: r.maxX - 24, y: r.minY + 8)) }

        if i == hovered { drawButtons(for: i) }

        drawText(item.title, in: NSRect(x: r.minX + 6, y: r.maxY - 24, width: r.width - 12, height: 18),
                 size: 11.5, alpha: 0.95)
    }

    private func drawButtons(for i: Int) {
        for (action, br) in buttons(for: i) {
            let over = br.contains(hoverPoint)
            let color: NSColor
            let symbol: String
            switch action {
            case .close: color = .systemRed; symbol = "xmark"
            case .minimize: color = .systemYellow; symbol = "minus"
            case .quit: color = .systemGray; symbol = "power"
            }
            color.withAlphaComponent(over ? 1 : 0.85).setFill()
            NSBezierPath(ovalIn: br).fill()
            guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .bold).applying(.init(paletteColors: [.black])))
            else { continue }
            let s = img.size
            img.draw(in: NSRect(x: br.midX - s.width / 2, y: br.midY - s.height / 2, width: s.width, height: s.height),
                     from: .zero, operation: .sourceOver, fraction: over ? 0.9 : 0.6, respectFlipped: true, hints: nil)
        }
    }

    private func drawSymbol(_ name: String, at p: NSPoint) {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold).applying(.init(paletteColors: [.labelColor])))
        else { return }
        img.draw(in: NSRect(origin: p, size: NSSize(width: 16, height: 16)), from: .zero,
                 operation: .sourceOver, fraction: 0.9, respectFlipped: true, hints: nil)
    }

    private func drawText(_ s: String, in r: NSRect, size: CGFloat, alpha: CGFloat, bold: Bool = false) {
        let ps = NSMutableParagraphStyle()
        ps.alignment = .center
        ps.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(alpha),
            .paragraphStyle: ps,
        ]
        (s as NSString).draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
    }

    private func aspectFit(_ size: NSSize, in r: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return r }
        let s = min(r.width / size.width, r.height / size.height)
        let w = size.width * s, h = size.height * s
        return NSRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }

    private func aspectFill(_ size: NSSize, in r: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return r }
        let s = max(r.width / size.width, r.height / size.height)
        let w = size.width * s, h = size.height * s
        return NSRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseMoved(with e: NSEvent) {
        hoverPoint = convert(e.locationInWindow, from: nil)
        let i = index(at: hoverPoint)
        hovered = i
        if let i { onHover?(i) }
        needsDisplay = true
    }
    override func mouseExited(with e: NSEvent) {
        hovered = nil
        needsDisplay = true
    }
    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let h = hovered, items.indices.contains(h), let action = buttons(for: h).first(where: { $0.1.contains(p) })?.0 {
            onAction?(h, action)
            return
        }
        if let i = index(at: p) { onClick?(i) }
    }
}

final class SwitcherPanel: NSPanel {
    let view = SwitcherView()
    let searchField = NSTextField()
    /// Only true while searching: the panel then takes keyboard focus so you can type.
    var allowsKey = false
    /// Holds the tiles and the search box; sits inside whichever backdrop this macOS gets.
    private let container = NSView()
    private let host = NSView()             // glass content: selection piece underneath, tiles on top
    private var backdrop: NSView!
    private var selectionGlass: NSView?
    private var sessionScreen: NSScreen?
    private var anchorTop: CGFloat?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        // Privacy: invisible to screenshots, screen recording and screen sharing.
        sharingType = .none

        container.addSubview(view)
        if #available(macOS 26.0, *) {
            // Liquid Glass, exactly as the user has it: their light/dark mode and their Clear/Tinted glass
            // setting in System Settings > Appearance. No forced appearance.
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 28
            // The selection is its own piece of glass, tinted with the user's accent color, like Apple's switcher.
            let pill = NSGlassEffectView()
            pill.style = .regular
            pill.cornerRadius = 14
            pill.tintColor = NSColor.controlAccentColor.withAlphaComponent(0.45)
            host.addSubview(pill)
            host.addSubview(container)
            glass.contentView = host
            backdrop = glass
            selectionGlass = pill
            view.drawsSelection = false
            view.onSelectionChange = { [weak self] in self?.placeSelection(animated: true) }
        } else {
            // Before Liquid Glass: the classic dark frosted switcher panel.
            appearance = NSAppearance(named: .darkAqua)
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.maskImage = SwitcherPanel.roundedMask(radius: 18)
            effect.addSubview(container)
            backdrop = effect
        }
        contentView = backdrop

        searchField.placeholderString = "Search windows"
        searchField.font = .systemFont(ofSize: 15)
        searchField.bezelStyle = .roundedBezel
        searchField.focusRingType = .none
        searchField.isHidden = true
        container.addSubview(searchField)
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    func present(_ items: [SwitchItem], selected: Int, thumbnailsOn: Bool, searching: Bool) {
        let mouse = NSEvent.mouseLocation
        if sessionScreen == nil {
            sessionScreen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        }
        guard let screen = sessionScreen else { return }
        let vf = screen.visibleFrame
        let searchH: CGFloat = searching ? 46 : 0
        var grid = view.configure(items, thumbnailsOn: thumbnailsOn,
                                  maxWidth: vf.width * 0.9, maxHeight: vf.height * 0.85 - searchH)
        if searching { grid.width = max(grid.width, 460) }
        view.selected = selected
        view.emptyText = (searching && items.isEmpty) ? "No matching windows" : nil

        let total = NSSize(width: grid.width, height: grid.height + searchH)
        // Keep the top edge still while the results change size, so the panel doesn't jump while typing.
        let top = anchorTop ?? (vf.midY + total.height / 2)
        anchorTop = top
        setFrame(NSRect(x: vf.midX - total.width / 2, y: top - total.height, width: total.width, height: total.height),
                 display: true)
        backdrop.frame = NSRect(origin: .zero, size: total)
        host.frame = NSRect(origin: .zero, size: total)
        container.frame = NSRect(origin: .zero, size: total)
        view.frame = NSRect(x: 0, y: 0, width: total.width, height: grid.height)
        searchField.isHidden = !searching
        searchField.frame = NSRect(x: 18, y: grid.height + 6, width: total.width - 36, height: 28)
        placeSelection(animated: false)
        orderFrontRegardless()
    }

    /// Moves the glass selection onto the selected tile, sliding when it changes.
    func placeSelection(animated: Bool) {
        guard let pill = selectionGlass else { return }
        guard let r = view.selectionRect() else { pill.isHidden = true; return }
        let target = view.convert(r, to: host)
        let wasHidden = pill.isHidden || pill.frame.isEmpty
        pill.isHidden = false
        if animated && !wasHidden && isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                pill.animator().frame = target
            }
        } else {
            pill.frame = target
        }
    }

    func dismiss() {
        orderOut(nil)
        selectionGlass?.frame = .zero
        allowsKey = false
        searchField.stringValue = ""
        searchField.isHidden = true
        sessionScreen = nil
        anchorTop = nil
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { r in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }
}

/// Windows-style "peek": a full-size preview of the selected window, drawn where that window sits,
/// just below the switcher. Shows a still, or live frames once you rest on a window. Like the switcher,
/// it is hidden from screen sharing and never takes clicks.
final class PreviewWindow: NSPanel {
    private let surface = NSView()
    private var livePixels: CVPixelBuffer?   // keeps the current live frame alive while it's on screen

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        sharingType = .none
        let layer = CALayer()
        layer.contentsGravity = .resizeAspect
        layer.cornerRadius = 10
        layer.masksToBounds = true
        layer.borderWidth = 1
        layer.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        surface.layer = layer          // layer-hosting: we set its contents directly
        surface.wantsLayer = true
        contentView = surface
    }

    override var canBecomeKey: Bool { false }

    /// `cgFrame` uses window-server coordinates (origin top-left of the main display).
    func show(_ image: CGImage, cgFrame: CGRect) {
        livePixels = nil
        present(contents: image, cgFrame: cgFrame)
    }

    func showLive(_ pixels: CVPixelBuffer, cgFrame: CGRect) {
        guard let io = CVPixelBufferGetIOSurface(pixels)?.takeUnretainedValue() else { return }
        livePixels = pixels
        present(contents: io, cgFrame: cgFrame)
    }

    private func present(contents: Any, cgFrame: CGRect) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let target = NSRect(x: cgFrame.minX, y: primaryHeight - cgFrame.maxY, width: cgFrame.width, height: cgFrame.height)
        if frame != target { setFrame(target, display: false) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.layer?.contents = contents
        CATransaction.commit()
        if !isVisible { orderFrontRegardless() }
    }

    func clear() {
        orderOut(nil)
        surface.layer?.contents = nil   // drop the pixels, not just hide them
        livePixels = nil
    }
}

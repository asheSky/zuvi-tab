import AppKit

/// The picture shown on empty-desktop tiles: your real wallpaper, shrunk once and kept in memory.
///
/// macOS 14+ keeps wallpaper choices in ~/Library/Application Support/com.apple.wallpaper/Store/Index.plist.
/// For Aerial (video) wallpapers, `NSWorkspace.desktopImageURL` just returns the built-in default picture,
/// so we read the real choice from that file: an Aerial's still thumbnail, or the photo you picked.
/// Only your own wallpaper settings are read; nothing about windows.
enum Wallpaper {
    private static let store = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper")
    private static var images: [URL: NSImage] = [:]          // resolved file -> shrunk image
    private static var storeStamp: Date?
    private static var storePlist: [String: Any] = [:]

    /// `spaceUUID` lets each desktop show its own wallpaper when you've set different ones.
    static func image(spaceUUID: String? = nil) -> NSImage? {
        guard let url = resolve(spaceUUID: spaceUUID) else { return nil }
        if let cached = images[url] { return cached }
        guard let full = NSImage(contentsOf: url), full.size.width > 0 else { return nil }
        let small = shrink(full)
        if images.count > 8 { images.removeAll() }
        images[url] = small
        return small
    }

    private static func resolve(spaceUUID: String?) -> URL? {
        reloadStoreIfChanged()
        if let choice = choice(spaceUUID: spaceUUID), let url = file(for: choice) { return url }
        // Built-in dynamic/still wallpapers: the classic API is right for those.
        guard let screen = NSScreen.main else { return nil }
        return NSWorkspace.shared.desktopImageURL(for: screen)
    }

    /// Re-read the settings file only when it has changed, so a new wallpaper shows up right away.
    private static func reloadStoreIfChanged() {
        let index = store.appendingPathComponent("Store/Index.plist")
        let stamp = (try? FileManager.default.attributesOfItem(atPath: index.path))?[.modificationDate] as? Date
        guard stamp != storeStamp else { return }
        storeStamp = stamp
        storePlist = (try? PropertyListSerialization.propertyList(from: Data(contentsOf: index), format: nil)) as? [String: Any] ?? [:]
    }

    /// Per-desktop choice if there is one, otherwise the "all desktops" choice.
    private static func choice(spaceUUID: String?) -> [String: Any]? {
        if let spaceUUID, let spaces = storePlist["Spaces"] as? [String: Any], let entry = spaces[spaceUUID],
           let c = firstChoice(in: entry) { return c }
        if let all = storePlist["AllSpacesAndDisplays"], let c = firstChoice(in: all) { return c }
        return nil
    }

    /// Finds the first `Content.Choices[0]` anywhere under an entry ("Linked", "Desktop", ... vary by setup).
    private static func firstChoice(in node: Any) -> [String: Any]? {
        guard let dict = node as? [String: Any] else { return nil }
        if let content = dict["Content"] as? [String: Any], let choices = content["Choices"] as? [[String: Any]],
           let first = choices.first { return first }
        for value in dict.values { if let c = firstChoice(in: value) { return c } }
        return nil
    }

    private static func file(for choice: [String: Any]) -> URL? {
        let provider = choice["Provider"] as? String ?? ""
        if provider.hasSuffix(".aerials") {
            guard let data = choice["Configuration"] as? Data,
                  let config = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let asset = config["assetID"] as? String else { return nil }
            let thumb = store.appendingPathComponent("aerials/thumbnails/\(asset).png")
            return FileManager.default.fileExists(atPath: thumb.path) ? thumb : nil
        }
        // A photo you picked: Files = [{ relative: "file:///..." }]
        for f in choice["Files"] as? [[String: Any]] ?? [] {
            if let s = (f["relative"] ?? f["url"]) as? String, let url = URL(string: s), url.isFileURL,
               FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private static func shrink(_ full: NSImage) -> NSImage {
        let target = NSSize(width: 480, height: max(1, 480 * full.size.height / full.size.width))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return full }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        full.draw(in: NSRect(origin: .zero, size: target))
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: target)
        out.addRepresentation(rep)
        return out
    }
}

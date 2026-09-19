import AppKit
import ScreenCaptureKit

/// Previews are captured ONLY while the switcher is open, held in memory, and dropped when it closes.
/// There is no background capture. Sensitive windows (excluded apps, private windows) are never passed in.
final class Thumbnailer {
    private let content = ContentCache()

    /// Called when the switcher closes: forget the window list as well as the pixels.
    func reset() {
        let content = content
        Task { await content.reset() }
    }

    /// Small tiles for the grid, captured in parallel.
    func capture(_ ids: [CGWindowID], maxPixel: CGFloat, _ done: @escaping (CGWindowID, CGImage) -> Void) {
        guard !ids.isEmpty else { return }
        let content = content
        Task.detached {
            let byID = await content.windows()
            await withTaskGroup(of: Void.self) { group in
                for id in ids {
                    group.addTask {
                        guard let img = await Thumbnailer.shot(id, byID[id], maxPixel: maxPixel, maxScale: 1) else { return }
                        DispatchQueue.main.async { done(id, img) }
                    }
                }
            }
        }
    }

    /// Sharp capture of the selected window, plus its frame (global coordinates, top-left origin).
    func captureLarge(_ id: CGWindowID, _ done: @escaping (CGImage, CGRect) -> Void) {
        let content = content
        Task.detached {
            let w = await content.windows()[id]
            guard let frame = w?.frame ?? Thumbnailer.windowServerFrame(id),
                  let img = await Thumbnailer.shot(id, w, maxPixel: 2800, maxScale: 2) else { return }
            DispatchQueue.main.async { done(img, frame) }
        }
    }

    private static func shot(_ id: CGWindowID, _ w: SCWindow?, maxPixel: CGFloat, maxScale: CGFloat) async -> CGImage? {
        // Last-moment check: never capture a window whose app has asked not to be captured.
        if refusesCapture(id) { return nil }
        if let w, w.frame.width > 1, w.frame.height > 1 {
            let filter = SCContentFilter(desktopIndependentWindow: w)
            let cfg = SCStreamConfiguration()
            let scale = min(maxScale, maxPixel / max(w.frame.width, w.frame.height))
            cfg.width = max(1, Int(w.frame.width * scale))
            cfg.height = max(1, Int(w.frame.height * scale))
            cfg.showsCursor = false
            if let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) { return img }
        }
        // ScreenCaptureKit refuses windows on other Spaces and minimized windows (error -3811).
        // The window server can still read their last-drawn contents directly. Same Screen Recording permission.
        guard let full = windowServerCapture(id) else { return nil }
        return downscaled(full, maxPixel: maxPixel)
    }

    private typealias HWCapture = @convention(c) (Int32, UnsafeMutablePointer<CGWindowID>, UInt32, UInt32) -> Unmanaged<CFArray>?
    private typealias MainConn = @convention(c) () -> Int32
    private static let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let hwCapture: HWCapture? = dlsym(sky, "CGSHWCaptureWindowList").map { unsafeBitCast($0, to: HWCapture.self) }
    private static let mainConn: MainConn? = dlsym(sky, "CGSMainConnectionID").map { unsafeBitCast($0, to: MainConn.self) }

    private static func windowServerCapture(_ id: CGWindowID) -> CGImage? {
        guard let hwCapture, let mainConn else { return nil }
        var wid = id
        let options: UInt32 = (1 << 11) | (1 << 8)   // ignore global clip shape, best resolution
        return (hwCapture(mainConn(), &wid, 1, options)?.takeRetainedValue() as? [CGImage])?.first
    }

    private static func refusesCapture(_ id: CGWindowID) -> Bool {
        let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first
        return (info?[kCGWindowSharingState as String] as? Int) == 0
    }

    fileprivate static func windowServerFrame(_ id: CGWindowID) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first,
              let b = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: b as CFDictionary)
    }

    /// Window-server captures come back full size; shrink them so tiles stay light in memory.
    private static func downscaled(_ img: CGImage, maxPixel: CGFloat) -> CGImage {
        let s = min(1, maxPixel / CGFloat(max(img.width, img.height)))
        guard s < 1 else { return img }
        let w = max(1, Int(CGFloat(img.width) * s)), h = max(1, Int(CGFloat(img.height) * s))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? img
    }
}

/// One window-list query per switcher session, because the query is expensive for macOS.
actor ContentCache {
    private var byID: [CGWindowID: SCWindow]?

    func windows() async -> [CGWindowID: SCWindow] {
        if let byID { return byID }
        guard let c = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        else { return [:] }
        var m: [CGWindowID: SCWindow] = [:]
        for w in c.windows { m[w.windowID] = w }
        byID = m
        return m
    }

    func reset() { byID = nil }
}

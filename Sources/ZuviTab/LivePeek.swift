import AppKit
import ScreenCaptureKit

/// Live preview of ONE window, started only when you rest on it in the open switcher, stopped the moment you
/// move on or close it. Frames go straight to the screen and are never stored. While it runs, macOS shows its
/// own screen-capture indicator in the menu bar, as it should.
final class LivePeek: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Called on the main thread with the newest frame, the window's frame (window-server coordinates)
    /// and, a few times a second, a small still for the tile.
    var onFrame: ((CGWindowID, CVPixelBuffer, CGRect, CGImage?) -> Void)?

    private var stream: SCStream?
    private(set) var windowID: CGWindowID?
    private var frame: CGRect = .zero
    private var frames = 0
    private let queue = DispatchQueue(label: "zuvi.livepeek", qos: .userInteractive)
    private let ci = CIContext(options: [.cacheIntermediates: false])

    func start(_ id: CGWindowID) {
        stop()
        windowID = id
        let op: @Sendable () async -> Void = { [weak self] in await self?.begin(id) }
        Task.detached(priority: .userInitiated, operation: op)
    }

    func stop() {
        windowID = nil
        queue.async { [weak self] in self?.frames = 0 }   // frames is only touched on the capture queue
        if let s = stream {
            stream = nil
            let op: @Sendable () async -> Void = { try? await s.stopCapture() }
            Task.detached(priority: .utility, operation: op)
        }
    }

    private func begin(_ id: CGWindowID) async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let w = content.windows.first(where: { $0.windowID == id }), w.frame.width > 1 else { return }
        let cfg = SCStreamConfiguration()
        let scale = min(2, 2000 / max(w.frame.width, w.frame.height))
        cfg.width = max(1, Int(w.frame.width * scale))
        cfg.height = max(1, Int(w.frame.height * scale))
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.queueDepth = 4
        cfg.showsCursor = false
        let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg, delegate: self)
        do {
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await s.startCapture()
        } catch { return }
        let keep: Bool = await MainActor.run {
            guard self.windowID == id else { return false }   // you moved on while it was starting
            self.stream = s
            self.frame = w.frame
            return true
        }
        if !keep { try? await s.stopCapture() }
    }

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pb = sb.imageBuffer,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        frames += 1
        var tile: CGImage?
        if frames % 6 == 1 {   // refresh the small tile ~5 times a second
            let ciImage = CIImage(cvPixelBuffer: pb)
            let k = 520 / max(ciImage.extent.width, ciImage.extent.height)
            let small = ciImage.transformed(by: CGAffineTransform(scaleX: k, y: k))
            tile = ci.createCGImage(small, from: small.extent)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let id = self.windowID, self.stream === s else { return }
            self.onFrame?(id, pb, self.frame, tile)
        }
    }

    func stream(_ s: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in if self?.stream === s { self?.stream = nil } }
    }
}

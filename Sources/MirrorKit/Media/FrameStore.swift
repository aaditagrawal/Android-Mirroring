import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

/// Holds the most recent decoded frame. Agent screenshots read from here, so they cost
/// one GPU downscale + JPEG encode (~5-10 ms) instead of an `adb screencap` round trip (~500+ ms).
public final class FrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    public private(set) var frameCounter: UInt64 = 0
    public private(set) var lastFrameTime = Date.distantPast
    private let ciContext = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: false])
    private let frameCondition = NSCondition()

    public init() {}

    public func update(_ pb: CVPixelBuffer) {
        frameCondition.lock()
        lock.lock()
        latest = pb
        frameCounter &+= 1
        lastFrameTime = Date()
        lock.unlock()
        frameCondition.broadcast()
        frameCondition.unlock()
    }

    public func clear() {
        lock.lock(); latest = nil; lock.unlock()
    }

    public var current: CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return latest }

    public var size: CGSize? {
        guard let pb = current else { return nil }
        return CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
    }

    /// Wait for a frame newer than `after` (or any frame if none yet).
    @discardableResult
    public func waitForFrame(after counter: UInt64, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        frameCondition.lock()
        defer { frameCondition.unlock() }
        while frameCounter <= counter || current == nil {
            if !frameCondition.wait(until: deadline) { return false }
        }
        return true
    }

    /// Wait until the screen has stopped changing for `quiet` seconds (frames are only sent on change).
    public func waitForIdle(quiet: TimeInterval, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let since = Date().timeIntervalSince(lastFrameTime)
            if since >= quiet { return true }
            Thread.sleep(forTimeInterval: min(quiet - since + 0.01, 0.05))
        }
        return false
    }

    // MARK: Visual settle detection

    /// Coarse luma grid of the current frame, for cheap change detection (~1 ms).
    /// The status bar strip is excluded so the clock / network indicators don't count as activity.
    public func signature() -> [UInt8]? {
        guard let pb = current else { return nil }
        return FrameStore.signature(of: pb)
    }

    public static func signature(of pb: CVPixelBuffer) -> [UInt8]? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard CVPixelBufferIsPlanar(pb), let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        guard w >= 64, h >= 64 else { return nil }
        let portrait = h >= w
        let cols = portrait ? 24 : 48, rows = portrait ? 48 : 24
        let top = h * (portrait ? 4 : 7) / 100
        let usableH = h - top
        var sums = [UInt32](repeating: 0, count: cols * rows)
        var counts = [UInt32](repeating: 0, count: cols * rows)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var y = top
        while y < h {
            let row = min(rows - 1, (y - top) * rows / usableH) * cols
            let line = p + y * stride
            var x = 0
            while x < w {
                let i = row + min(cols - 1, x * cols / w)
                sums[i] &+= UInt32(line[x]); counts[i] &+= 1
                x += 3
            }
            y += 3
        }
        return (0..<sums.count).map { counts[$0] == 0 ? 0 : UInt8(sums[$0] / counts[$0]) }
    }

    /// Largest per-cell luma difference between two signatures (0-255).
    public static func maxDelta(_ a: [UInt8], _ b: [UInt8]) -> Int {
        guard a.count == b.count else { return 255 }
        var m = 0
        for i in 0..<a.count { m = max(m, abs(Int(a[i]) - Int(b[i]))) }
        return m
    }

    /// Whether two frames differ in a way that matters: a strong change anywhere, or a moderate
    /// change spread over several cells. A blinking caret (one or two cells, weak) doesn't count.
    public static func significantlyDifferent(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return true }
        var moderate = 0
        for i in 0..<a.count {
            let d = abs(Int(a[i]) - Int(b[i]))
            if d > 40 { return true }
            if d > 12 { moderate += 1; if moderate >= 3 { return true } }
        }
        return false
    }

    public struct Settle {
        public let settled: Bool
        /// Whether the screen visibly changed after the action.
        public let changed: Bool
        public let ms: Int
    }

    /// Wait until the screen has visibly stopped changing.
    ///
    /// - after: frame counter captured before an action. The screen then gets `reactTimeout` to
    ///   start reacting; if no frame arrives at all, nothing changed and we return immediately.
    /// - Insignificant changes (blinking caret, status bar) don't count. Each frame is compared
    ///   with the last *significant* frame, so slow fades still register.
    public func waitForSettle(after counter: UInt64? = nil, reactTimeout: TimeInterval = 0.35,
                              quiet: TimeInterval = 0.2, timeout: TimeInterval = 2.5) -> Settle {
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        func done(_ settled: Bool, _ changed: Bool) -> Settle {
            Settle(settled: settled, changed: changed, ms: Int(Date().timeIntervalSince(start) * 1000))
        }
        var changed = false
        if let counter {
            guard waitForFrame(after: counter, timeout: reactTimeout) else { return done(true, false) }
            changed = true
        }
        var reference = signature()
        var seen = frameCounter
        // Without an action to wait for, the screen has been quiet since its last frame
        // (frames only arrive on change), so a still screen returns immediately.
        var quietSince = Date()
        if counter == nil {
            lock.lock(); let last = lastFrameTime; lock.unlock()
            quietSince = min(quietSince, last)
        }
        while true {
            let now = Date()
            let left = quiet - now.timeIntervalSince(quietSince)
            if left <= 0 { return done(true, changed) }
            if now >= deadline { return done(false, changed) }
            guard waitForFrame(after: seen, timeout: min(left, deadline.timeIntervalSince(now))) else { continue }
            seen = frameCounter
            let sig = signature()
            if let a = reference, let b = sig, !FrameStore.significantlyDifferent(a, b) { continue }
            reference = sig
            quietSince = Date()
            changed = true
        }
    }

    public func cgImage(maxDimension: Int? = nil) -> CGImage? {
        guard let pb = current else { return nil }
        var image = CIImage(cvPixelBuffer: pb)
        if let maxDimension, maxDimension > 0 {
            let w = image.extent.width, h = image.extent.height
            let scale = min(1, CGFloat(maxDimension) / max(w, h))
            if scale < 1 {
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
        }
        let rect = image.extent.integral
        return ciContext.createCGImage(image, from: rect, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    public enum Format: String { case jpeg, png }

    public func encoded(format: Format = .jpeg, maxDimension: Int? = nil, quality: Double = 0.8) -> (data: Data, width: Int, height: Int)? {
        guard let img = cgImage(maxDimension: maxDimension) else { return nil }
        return FrameStore.encode(img, format: format, quality: quality).map { ($0, img.width, img.height) }
    }

    public static func encode(_ img: CGImage, format: Format, quality: Double) -> Data? {
        let data = NSMutableData()
        let type = format == .png ? UTType.png.identifier : UTType.jpeg.identifier
        guard let dest = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        let props: [CFString: Any] = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: quality] : [:]
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

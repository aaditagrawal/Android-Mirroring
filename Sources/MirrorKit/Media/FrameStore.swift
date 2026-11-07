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
        lock.lock()
        latest = pb
        frameCounter &+= 1
        lastFrameTime = Date()
        lock.unlock()
        frameCondition.broadcast()
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

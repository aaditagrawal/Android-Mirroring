import AppKit

/// Captures this app's own windows (no Screen Recording permission needed for own windows).
/// CGWindowListCreateImage is marked unavailable in the SDK but still exported; resolve it dynamically.
enum WindowCapture {
    private typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let fn: Fn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(sym, to: Fn.self)
    }()

    static func png(windowID: CGWindowID) -> Data? {
        // .optionIncludingWindow = 1 << 3, .boundsIgnoreFraming = 1 << 0, .bestResolution = 1 << 3
        guard let fn, let img = fn(.null, 1 << 3, windowID, (1 << 0) | (1 << 3))?.takeRetainedValue() else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }
}

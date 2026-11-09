import Foundation

/// The local agent API. The app listens on a Unix domain socket; requests and responses
/// are single-line JSON objects:
///
///   → {"id": 1, "method": "tap", "params": {"x": 540, "y": 1200}}
///   ← {"id": 1, "result": {...}}            or   {"id": 1, "error": "message"}
///
/// Coordinates are always in *screenshot space*: the pixel grid of the image returned by
/// the most recent `screenshot` call (default: the long edge scaled to `defaultMaxDimension`).
/// Pass `"space": "device"` to use raw device pixels instead.
public enum AgentAPI {
    public static let defaultMaxDimension = 1280

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("AndroidMirroring", isDirectory: true)
    }

    /// Unix socket path. Kept short: sun_path is limited to 104 bytes.
    public static var socketPath: String {
        if let env = ProcessInfo.processInfo.environment["ANDROID_MIRRORING_SOCKET"], !env.isEmpty { return env }
        return supportDirectory.appendingPathComponent("agent.sock").path
    }

    public static let bundleIdentifier = "com.aaditagrawal.AndroidMirroring"
}

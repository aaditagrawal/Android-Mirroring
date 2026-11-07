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

/// A tool exposed both as a droidctl subcommand and as an MCP tool.
public struct AgentTool {
    public let name: String
    public let description: String
    /// JSON Schema for the parameters (MCP inputSchema).
    public let schema: [String: Any]

    init(_ name: String, _ description: String, _ props: [String: [String: Any]] = [:], required: [String] = []) {
        self.name = name
        self.description = description
        self.schema = ["type": "object", "properties": props, "required": required, "additionalProperties": false]
    }
}

private func num(_ d: String) -> [String: Any] { ["type": "number", "description": d] }
private func int(_ d: String) -> [String: Any] { ["type": "integer", "description": d] }
private func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
private func bool(_ d: String) -> [String: Any] { ["type": "boolean", "description": d] }
private let space: [String: Any] = ["type": "string", "enum": ["screenshot", "device", "normalized"],
                                    "description": "Coordinate space: 'screenshot' (default, pixels of the last screenshot), 'device' (raw device pixels) or 'normalized' (0-1)."]

public enum AgentTools {
    public static let all: [AgentTool] = [
        AgentTool("screenshot",
                  "Capture the Android phone's screen (from the live mirror stream, ~10 ms). Returns an image. Coordinates for tap/swipe refer to this image's pixels.",
                  ["max_dimension": int("Long-edge size in pixels (default 1280, 0 = full resolution)."),
                   "format": ["type": "string", "enum": ["jpeg", "png"], "description": "Image format (default jpeg)."],
                   "wait_for_idle": bool("Wait until the screen stops changing (max 2 s) before capturing. Default true.")]),
        AgentTool("tap", "Tap at a point.",
                  ["x": num("X coordinate"), "y": num("Y coordinate"), "space": space], required: ["x", "y"]),
        AgentTool("double_tap", "Double-tap at a point.",
                  ["x": num("X coordinate"), "y": num("Y coordinate"), "space": space], required: ["x", "y"]),
        AgentTool("long_press", "Touch and hold at a point.",
                  ["x": num("X"), "y": num("Y"), "duration_ms": int("Hold duration (default 600)."), "space": space], required: ["x", "y"]),
        AgentTool("swipe", "Swipe (drag a finger) from one point to another. Use for scrolling lists: swipe up to scroll content down.",
                  ["x1": num("Start X"), "y1": num("Start Y"), "x2": num("End X"), "y2": num("End Y"),
                   "duration_ms": int("Gesture duration (default 300). Short = fling, long = precise drag."), "space": space],
                  required: ["x1", "y1", "x2", "y2"]),
        AgentTool("scroll", "Scroll at a point like a mouse wheel. Positive dy scrolls content down (reveals content below).",
                  ["x": num("X"), "y": num("Y"), "dx": num("Horizontal amount (wheel notches)."), "dy": num("Vertical amount (wheel notches)."), "space": space],
                  required: ["dy"]),
        AgentTool("pinch", "Two-finger pinch around a point. scale > 1 zooms in, < 1 zooms out.",
                  ["x": num("Center X"), "y": num("Center Y"), "scale": num("Zoom factor, e.g. 2 or 0.5."), "space": space], required: ["scale"]),
        AgentTool("type_text", "Type text into the focused field. Handles any Unicode (falls back to clipboard paste for non-ASCII).",
                  ["text": str("Text to type."), "submit": bool("Press Enter afterwards.")], required: ["text"]),
        AgentTool("press_key",
                  "Press a key: home, back, recents, enter, delete, tab, escape, up, down, left, right, volume_up, volume_down, mute, power, wakeup, sleep, search, menu, play_pause, notifications, or a numeric Android keycode.",
                  ["key": str("Key name or Android keycode number."), "long_press": bool("Hold the key (e.g. long-press power)."),
                   "meta": ["type": "array", "items": ["type": "string", "enum": ["shift", "ctrl", "alt", "meta"]], "description": "Modifier keys held during the press."]],
                  required: ["key"]),
        AgentTool("ui_tree",
                  "Get the on-screen UI elements (text, content description, resource id, clickable, bounds) from the Android accessibility tree. Bounds/centers are in screenshot space unless space is set. Slower than screenshot (~1 s) but exact.",
                  ["filter": str("Only return elements whose text/description/id contains this (case-insensitive)."),
                   "all": bool("Include non-interactive elements without text (default false)."), "space": space]),
        AgentTool("tap_element", "Find a UI element by visible text, content description or resource id, and tap its center.",
                  ["query": str("Text / description / resource-id to match (case-insensitive substring; exact matches win)."),
                   "index": int("Which match to tap if several (default 0)."), "long_press": bool("Long-press instead of tap.")],
                  required: ["query"]),
        AgentTool("wait_for", "Wait until a UI element containing the text appears (or disappears).",
                  ["query": str("Text / description / resource-id."), "timeout_ms": int("Default 10000."), "gone": bool("Wait for it to disappear instead.")],
                  required: ["query"]),
        AgentTool("launch_app", "Launch an app by package name (com.whatsapp) or by its label (\"WhatsApp\").",
                  ["app": str("Package name or app label."), "restart": bool("Force-stop first.")], required: ["app"]),
        AgentTool("list_apps", "List installed launchable apps (label and package).",
                  ["filter": str("Substring filter on label or package."), "include_system": bool("Include system apps (default true).")]),
        AgentTool("open_url", "Open a URL or deep link on the phone (http(s)://, tel:, mailto:, geo:, app schemes).",
                  ["url": str("URL to open.")], required: ["url"]),
        AgentTool("current_app", "Get the foreground app package and activity, and whether the keyboard is shown."),
        AgentTool("device_info", "Phone model, Android version, battery, screen size, connection path and latency, mirroring stats."),
        AgentTool("get_clipboard", "Read the phone's clipboard text."),
        AgentTool("set_clipboard", "Set the phone's clipboard text (optionally paste it into the focused field).",
                  ["text": str("Text."), "paste": bool("Also paste.")], required: ["text"]),
        AgentTool("notifications", "List current notifications on the phone (app, title, text, time).",
                  ["limit": int("Maximum notifications (default 30).")]),
        AgentTool("open_notifications", "Pull down the notification shade (or quick settings).",
                  ["quick_settings": bool("Open quick settings instead.")]),
        AgentTool("unlock", "Wake the phone and unlock it with the PIN saved in Android Mirroring settings (Keychain), if any."),
        AgentTool("screen_power", "Turn the phone's physical display off/on while mirroring keeps working.",
                  ["on": bool("true = display on, false = off (mirroring continues).")], required: ["on"]),
        AgentTool("rotate", "Rotate the device screen."),
        AgentTool("shell", "Run an adb shell command on the phone and return its output (stdout).",
                  ["command": str("Shell command."), "timeout_ms": int("Default 20000.")], required: ["command"]),
        AgentTool("install_apk", "Install an APK from a path on this Mac.", ["path": str("Absolute path to the .apk.")], required: ["path"]),
        AgentTool("push_file", "Copy a file from this Mac to the phone (default /sdcard/Download/).",
                  ["path": str("Local path."), "remote_path": str("Destination path or directory on the phone.")], required: ["path"]),
        AgentTool("pull_file", "Copy a file from the phone to this Mac.",
                  ["remote_path": str("Path on the phone."), "path": str("Local destination (default ~/Downloads).")], required: ["remote_path"]),
        AgentTool("wait", "Sleep for a duration (let animations settle).", ["ms": int("Milliseconds (default 500).")]),
        AgentTool("status", "Connection status: whether a phone is connected, via which path, and whether the mirror window is open."),
        AgentTool("show_window", "Show or hide the mirroring window on the Mac (the agent API works either way).",
                  ["visible": bool("Default true.")]),
    ]

    public static func named(_ n: String) -> AgentTool? { all.first { $0.name == n } }
}

// MARK: - Minimal client used by droidctl

public final class AgentClient {
    private var fd: Int32 = -1
    private var buffer = Data()
    private var nextId = 1

    public init() {}

    public func connect(path: String = AgentAPI.socketPath) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentError.message("socket() failed") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw AgentError.message("socket path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        if rc != 0 {
            close(fd); fd = -1
            throw AgentError.notRunning
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { if fd >= 0 { close(fd) } }

    /// Send a request and wait for its response.
    public func call(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        let id = nextId; nextId += 1
        let req: [String: Any] = ["id": id, "method": method, "params": params]
        var data = try JSONSerialization.data(withJSONObject: req)
        data.append(0x0A)
        try data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { throw AgentError.message("write failed") }
                off += n
            }
        }
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if (obj["id"] as? Int) != id { continue }
                if let err = obj["error"] as? String { throw AgentError.message(err) }
                return obj["result"] as? [String: Any] ?? [:]
            }
            var chunk = [UInt8](repeating: 0, count: 256 * 1024)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { throw AgentError.message("connection closed by Android Mirroring") }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}

public enum AgentError: Error, CustomStringConvertible {
    case notRunning
    case message(String)
    public var description: String {
        switch self {
        case .notRunning: return "Android Mirroring is not running"
        case .message(let m): return m
        }
    }
}

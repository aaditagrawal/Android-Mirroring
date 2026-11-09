import Foundation

/// A tool exposed both as a droidctl subcommand and as an MCP tool.
public struct AgentTool {
    public let name: String
    public let description: String
    /// JSON Schema for the parameters (MCP inputSchema).
    public let schema: [String: Any]

    /// Tools that change the screen: they take `screenshot` / `settle` and, over MCP, return the
    /// settled screen by default so one call = act + observe.
    public var isAction: Bool { AgentTools.actionNames.contains(name) }

    init(_ name: String, _ description: String, _ props: [String: [String: Any]] = [:], required: [String] = []) {
        self.name = name
        var props = props
        if AgentTools.actionNames.contains(name) {
            props["screenshot"] = ["type": "boolean",
                                   "description": "Return a screenshot once the screen has settled (default true). Set false when chaining blind steps."]
            props["settle"] = ["type": "boolean",
                               "description": "Wait for the screen to stop changing before returning (default: same as screenshot)."]
        }
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
    public static let actionNames: Set<String> = ["tap", "double_tap", "long_press", "swipe", "scroll", "pinch", "type_text",
                                                  "press_key", "tap_element", "launch_app", "open_url", "open_notifications",
                                                  "rotate", "unlock", "batch"]

    public static let all: [AgentTool] = [
        AgentTool("screenshot",
                  "Capture the Android phone's screen from the live mirror stream (~10 ms once the screen is still). Returns an image; tap/swipe coordinates refer to its pixels. Actions already return a screenshot, so you rarely need this after one.",
                  ["max_dimension": int("Long-edge size in pixels (default 1280, 0 = full resolution)."),
                   "format": ["type": "string", "enum": ["jpeg", "png"], "description": "Image format (default jpeg)."],
                   "wait_for_idle": bool("Wait until the screen visibly stops changing (max 1.5 s; the status bar and a blinking caret are ignored). Default true.")]),
        AgentTool("screen_text",
                  "Read the text on screen with on-device OCR (~100-200 ms; works in web views, Flutter, games, images). Returns lines with centers/bounds in screenshot space. A cheap way to check the screen without an image; with a query, returns only matching lines.",
                  ["query": str("Only return lines containing this text (case-insensitive)."), "space": space]),
        AgentTool("batch",
                  "Run several actions in one call, in order, each waiting for the screen to settle before the next. Stops at the first failure. Example: [{\"tool\":\"tap_element\",\"query\":\"Search\"},{\"tool\":\"type_text\",\"text\":\"cafes\",\"submit\":true}]. Returns one screenshot at the end.",
                  ["actions": ["type": "array", "description": "Steps: objects with \"tool\" (an action tool name) plus that tool's arguments.",
                               "items": ["type": "object", "properties": ["tool": ["type": "string"]], "required": ["tool"]]],
                   "space": space],
                  required: ["actions"]),
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
        AgentTool("tap_element",
                  "Tap something by its visible text (OCR, ~150 ms), falling back to the accessibility tree for content descriptions / resource ids. Exact matches win. Prefer this over guessing coordinates.",
                  ["query": str("Visible text, content description or resource id (case-insensitive)."),
                   "index": int("Which match to tap if several, top to bottom (default 0)."), "long_press": bool("Long-press instead of tap."),
                   "source": ["type": "string", "enum": ["auto", "ocr", "ui"], "description": "auto (default): OCR first, then the accessibility tree; ocr: visible text only; ui: accessibility tree only."]],
                  required: ["query"]),
        AgentTool("wait_for", "Wait until text appears on screen (or disappears). Checks every new frame with OCR.",
                  ["query": str("Text to wait for."), "timeout_ms": int("Default 10000."), "gone": bool("Wait for it to disappear instead."),
                   "source": ["type": "string", "enum": ["ocr", "ui", "auto"], "description": "ocr (default): visible text; ui: accessibility tree (content descriptions/ids, slower); auto: both."]],
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

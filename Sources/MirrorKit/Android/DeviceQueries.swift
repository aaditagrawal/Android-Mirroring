import CoreGraphics
import Foundation

// MARK: - UI hierarchy

public struct UINode: Sendable {
    public var text: String
    public var desc: String
    public var resourceId: String
    public var className: String
    public var package: String
    public var bounds: CGRect
    public var clickable: Bool
    public var longClickable: Bool
    public var scrollable: Bool
    public var focused: Bool
    public var checked: Bool?
    public var enabled: Bool
    public var editable: Bool
    public var selected: Bool

    public var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    public var label: String { !text.isEmpty ? text : desc }
    public var interactive: Bool { clickable || longClickable || scrollable || editable }

    func matches(_ q: String) -> Int? {
        let ql = q.lowercased()
        let fields = [text, desc, resourceId, resourceId.split(separator: "/").last.map(String.init) ?? ""]
        if fields.contains(where: { $0.lowercased() == ql }) { return 0 }       // exact
        if fields.contains(where: { $0.lowercased().hasPrefix(ql) }) { return 1 }
        if fields.contains(where: { $0.lowercased().contains(ql) }) { return 2 }
        return nil
    }
}

final class UIHierarchyParser: NSObject, XMLParserDelegate {
    var nodes: [UINode] = []

    static func parse(_ data: Data) -> [UINode] {
        let p = XMLParser(data: data)
        let d = UIHierarchyParser()
        p.delegate = d
        p.parse()
        return d.nodes
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes a: [String: String] = [:]) {
        guard elementName == "node" else { return }
        let cls = a["class"] ?? ""
        let node = UINode(
            text: a["text"] ?? "", desc: a["content-desc"] ?? "", resourceId: a["resource-id"] ?? "",
            className: cls, package: a["package"] ?? "", bounds: UIHierarchyParser.parseBounds(a["bounds"] ?? ""),
            clickable: a["clickable"] == "true", longClickable: a["long-clickable"] == "true",
            scrollable: a["scrollable"] == "true", focused: a["focused"] == "true",
            checked: a["checkable"] == "true" ? (a["checked"] == "true") : nil,
            enabled: a["enabled"] != "false",
            editable: cls.hasSuffix("EditText") || cls.contains("AutoCompleteTextView"),
            selected: a["selected"] == "true")
        nodes.append(node)
    }

    static func parseBounds(_ s: String) -> CGRect {
        // "[0,0][1080,2340]"
        let nums = s.split(whereSeparator: { "[],".contains($0) }).compactMap { Double($0) }
        guard nums.count == 4 else { return .zero }
        return CGRect(x: nums[0], y: nums[1], width: nums[2] - nums[0], height: nums[3] - nums[1])
    }
}

// MARK: - Notifications

public struct PhoneNotification: Sendable, Hashable {
    public var key: String
    public var package: String
    public var title: String
    public var text: String
    public var postedAt: Date?
    public var ongoing: Bool
    public var groupSummary: Bool
    public var importance: Int
}

enum NotificationParser {
    /// Parses the filtered output of `dumpsys notification --noredact | grep ...`.
    static func parse(_ text: String) -> [PhoneNotification] {
        var out: [PhoneNotification] = []
        var cur: PhoneNotification?
        func flush() { if let c = cur { out.append(c) }; cur = nil }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("NotificationRecord(") {
                flush()
                let pkg = field(line, "pkg=") ?? ""
                let key = field(line, "key=") ?? UUID().uuidString
                let flags = field(line, "flags=").flatMap { Int($0.replacingOccurrences(of: "0x", with: ""), radix: 16) } ?? 0
                let importance = field(line, "importance=").flatMap { Int($0) } ?? 3
                cur = PhoneNotification(key: key, package: pkg, title: "", text: "", postedAt: nil,
                                        ongoing: flags & 0x2 != 0, groupSummary: flags & 0x200 != 0, importance: importance)
            } else if cur != nil {
                if line.hasPrefix("android.title="), let v = stringValue(line) { cur!.title = v }
                else if line.hasPrefix("android.text="), let v = stringValue(line) { cur!.text = v }
                else if line.hasPrefix("android.bigText="), let v = stringValue(line), cur!.text.isEmpty || v.count > cur!.text.count { cur!.text = v }
                else if line.hasPrefix("mCreationTimeMs="), let ms = Double(line.dropFirst(16).prefix { $0.isNumber }) {
                    cur!.postedAt = Date(timeIntervalSince1970: ms / 1000)
                } else if line.contains("flags=0x"), let f = field(line, "flags="), let v = Int(f.replacingOccurrences(of: "0x", with: ""), radix: 16) {
                    cur!.ongoing = v & 0x2 != 0
                    cur!.groupSummary = v & 0x200 != 0
                }
            }
        }
        flush()
        // Deduplicate by key (dumpsys can list a record twice in different sections).
        var seen = Set<String>()
        return out.filter { seen.insert($0.key).inserted }
    }

    private static func field(_ line: String, _ name: String) -> String? {
        guard let r = line.range(of: name) else { return nil }
        let rest = line[r.upperBound...]
        let v = rest.prefix { $0 != " " && $0 != ")" && $0 != "," }
        return v.isEmpty ? nil : String(v)
    }

    /// `android.title=String (Hello)` → Hello ; also SpannableString / null.
    private static func stringValue(_ line: String) -> String? {
        guard let open = line.firstIndex(of: "(") , line.hasSuffix(")") else { return nil }
        let v = line[line.index(after: open)..<line.index(before: line.endIndex)]
        return String(v)
    }
}

// MARK: - Apps

public struct PhoneApp: Sendable, Hashable {
    public var label: String
    public var package: String
    public var system: Bool
}

enum AppListParser {
    static func parse(_ text: String) -> [PhoneApp] {
        var apps: [PhoneApp] = []
        var pending: (String, Bool)?
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let p = pending, !trimmed.isEmpty, !trimmed.hasPrefix("* "), !trimmed.hasPrefix("- ") {
                apps.append(PhoneApp(label: p.0, package: trimmed, system: p.1))
                pending = nil
                continue
            }
            guard trimmed.hasPrefix("* ") || trimmed.hasPrefix("- ") else { continue }
            let system = trimmed.hasPrefix("* ")
            let body = String(trimmed.dropFirst(2))
            // label is followed by padding then the package (last token without spaces)
            if let range = body.range(of: " ", options: .backwards) {
                let pkg = String(body[range.upperBound...])
                let label = body[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                if pkg.contains("."), !label.isEmpty, body.contains("  ") || label.count >= 29 {
                    apps.append(PhoneApp(label: label, package: pkg, system: system))
                    continue
                }
            }
            pending = (body.trimmingCharacters(in: .whitespaces), system)
        }
        return apps
    }
}

// MARK: - Queries

public struct DeviceQueries {
    let adb: ADBClient
    let serial: String

    public init(adb: ADBClient, serial: String) {
        self.adb = adb
        self.serial = serial
    }

    public func uiTree() throws -> [UINode] {
        let path = "/data/local/tmp/android-mirroring-ui.xml"
        let out = try adb.exec(serial: serial, "uiautomator dump --compressed \(path) >/dev/null 2>&1; cat \(path); rm -f \(path)", timeout: 15)
        guard let start = out.range(of: Data("<?xml".utf8)) else {
            // Fallback without --compressed (some ROMs reject it)
            let out2 = try adb.exec(serial: serial, "uiautomator dump \(path) 2>&1 >/dev/null; cat \(path); rm -f \(path)", timeout: 15)
            guard let s2 = out2.range(of: Data("<?xml".utf8)) else {
                let msg = String(decoding: out2.prefix(300), as: UTF8.self)
                if msg.contains("Killed") || msg.contains("already registered") || msg.contains("UiAutomationService") {
                    throw ADBError("the accessibility tree is unavailable: another automation tool on the phone is holding UiAutomation (e.g. an agent-device / Appium / Maestro helper). Use screenshot + coordinates instead, or stop that tool.")
                }
                throw ADBError("uiautomator dump failed: \(msg)")
            }
            return UIHierarchyParser.parse(out2[s2.lowerBound...])
        }
        return UIHierarchyParser.parse(out[start.lowerBound...])
    }

    public func notifications() throws -> [PhoneNotification] {
        let cmd = #"dumpsys notification --noredact | grep -E "^ +NotificationRecord\(|android\.(title|text|bigText)=|mCreationTimeMs=|^ +Notification\(channel""#
        let text = try adb.shell(serial: serial, cmd, timeout: 15)
        return NotificationParser.parse(text)
    }

    public func foreground() -> (package: String, activity: String, keyboard: Bool) {
        let out = (try? adb.shell(serial: serial, "dumpsys window | grep -E 'mCurrentFocus|mFocusedApp|mInputMethodWindow|isInputMethodWindowVisible|mImeShowing'", timeout: 6)) ?? ""
        var pkg = "", act = ""
        for line in out.split(separator: "\n") where line.contains("mCurrentFocus=Window{") || line.contains("mFocusedApp=") {
            // ... u0 com.pkg/com.pkg.Activity}
            if let comp = line.split(separator: " ").last(where: { $0.contains("/") }) {
                let c = comp.trimmingCharacters(in: CharacterSet(charactersIn: "}"))
                let parts = c.split(separator: "/")
                if parts.count == 2 { pkg = String(parts[0]); act = String(parts[1]); break }
            }
        }
        let keyboard = out.contains("mImeShowing=true") || out.contains("isInputMethodWindowVisible=true")
        return (pkg, act, keyboard)
    }

    public func battery() -> (level: Int, charging: Bool)? {
        guard let out = try? adb.shell(serial: serial, "dumpsys battery | head -15", timeout: 6) else { return nil }
        var level = -1, charging = false
        for line in out.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("level:") { level = Int(l.dropFirst(6).trimmingCharacters(in: .whitespaces)) ?? -1 }
            if (l.hasPrefix("AC powered:") || l.hasPrefix("USB powered:") || l.hasPrefix("Wireless powered:")) && l.hasSuffix("true") { charging = true }
        }
        return level >= 0 ? (level, charging) : nil
    }

    /// Lists apps through the scrcpy server's `list_apps` mode (labels need the Android framework).
    public func listApps() throws -> [PhoneApp] {
        try ScrcpySession.ensureServer(adb: adb, serial: serial)
        let cmd = ScrcpySession.launchPrefix("apps") + " list_apps=true log_level=info"
        let out = try adb.shell(serial: serial, cmd, timeout: 40)
        return AppListParser.parse(out)
    }

    public func isLocked() -> Bool {
        let out = (try? adb.shell(serial: serial, "dumpsys window | grep -E 'mDreamingLockscreen|isKeyguardShowing|mShowingLockscreen|keyguardShowing'", timeout: 5)) ?? ""
        return out.contains("mDreamingLockscreen=true") || out.contains("mShowingLockscreen=true") || out.contains("isKeyguardShowing=true") || out.contains("keyguardShowing=true")
    }

    public func isScreenOn() -> Bool {
        let out = (try? adb.shell(serial: serial, "dumpsys power | grep -E 'mWakefulness='", timeout: 5)) ?? ""
        return out.contains("Awake")
    }

    public func ipv4(interface: String) -> String? {
        guard let out = try? adb.shell(serial: serial, "ip -4 -o addr show \(interface) 2>/dev/null", timeout: 5) else { return nil }
        // "30: wlan0    inet 192.168.1.5/24 brd ..."
        guard let r = out.range(of: "inet ") else { return nil }
        let rest = out[r.upperBound...]
        return rest.prefix { $0 != "/" && $0 != " " }.description
    }

    /// Tailscale's VPN interface address (100.64.0.0/10), if the Tailscale app is connected.
    public func tailscaleIP() -> String? {
        guard let out = try? adb.shell(serial: serial, "ip -4 -o addr show 2>/dev/null | grep -E 'inet 100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.'", timeout: 5) else { return nil }
        guard let r = out.range(of: "inet ") else { return nil }
        return out[r.upperBound...].prefix { $0 != "/" && $0 != " " }.description
    }
}

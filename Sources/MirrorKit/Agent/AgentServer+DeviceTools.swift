import AgentProtocol
import CoreGraphics
import Foundation

extension AgentServer {
    func handleDeviceTools(_ method: String, _ p: [String: Any]) throws -> [String: Any] {
        let c = controller
        switch method {
        case "launch_app":
            let app = try requireString(p, "app")
            let restart = p["restart"] as? Bool ?? false
            let isPackage = app.contains(".") && !app.contains(" ")
            let pkg = isPackage ? app : (try resolveApp(label: app))
            let serial = try requireSerial()
            if restart { _ = try? c.adb.shell(serial: serial, "am force-stop \(pkg)") }
            let out = try c.adb.shell(serial: serial, "monkey -p \(pkg) -c android.intent.category.LAUNCHER 1 2>&1", timeout: 15)
            if out.contains("No activities found") || out.contains("monkey aborted") {
                throw ADBError("could not launch \(pkg)")
            }
            return ["launched": pkg]

        case "list_apps":
            let apps = try cachedApps()
            let f = (p["filter"] as? String)?.lowercased()
            let includeSystem = p["include_system"] as? Bool ?? true
            let list = apps.filter { a in
                (includeSystem || !a.system) && (f == nil || a.label.lowercased().contains(f!) || a.package.lowercased().contains(f!))
            }.map { ["label": $0.label, "package": $0.package, "system": $0.system] as [String: Any] }
            return ["apps": list, "count": list.count]

        case "open_url":
            let url = try requireString(p, "url")
            let escaped = url.replacingOccurrences(of: "'", with: "'\\''")
            let out = try c.adb.shell(serial: try requireSerial(), "am start -a android.intent.action.VIEW -d '\(escaped)' 2>&1", timeout: 10)
            if out.contains("Error") { throw ADBError(out.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return ["ok": true]

        case "current_app":
            let fg = DeviceQueries(adb: c.adb, serial: try requireSerial()).foreground()
            return ["package": fg.package, "activity": fg.activity, "keyboard_visible": fg.keyboard]

        case "device_info":
            return try deviceInfo()

        case "get_clipboard":
            let sem = DispatchSemaphore(value: 0)
            var text: String?
            c.fetchDeviceClipboard { t in text = t; sem.signal() }
            _ = sem.wait(timeout: .now() + 3)
            return ["text": text ?? ""]

        case "set_clipboard":
            guard let text = p["text"] as? String else { throw ADBError("missing parameter 'text'") }
            c.setDeviceClipboard(text, paste: p["paste"] as? Bool ?? false)
            return ["ok": true]

        case "notifications":
            let list = try DeviceQueries(adb: c.adb, serial: try requireSerial()).notifications()
            let limit = Int(num(p, "limit") ?? 30)
            let labels = (try? cachedApps()).map { Dictionary($0.map { ($0.package, $0.label) }, uniquingKeysWith: { a, _ in a }) } ?? [:]
            let iso = ISO8601DateFormatter()
            let items = list.filter { !$0.groupSummary && !($0.title.isEmpty && $0.text.isEmpty) }
                .sorted { ($0.postedAt ?? .distantPast) > ($1.postedAt ?? .distantPast) }
                .prefix(limit)
                .map { n -> [String: Any] in
                    var e: [String: Any] = ["app": labels[n.package] ?? n.package, "package": n.package, "title": n.title, "text": n.text]
                    if let d = n.postedAt { e["posted"] = iso.string(from: d) }
                    if n.ongoing { e["ongoing"] = true }
                    return e
                }
            return ["notifications": Array(items), "count": items.count]

        case "open_notifications":
            if p["quick_settings"] as? Bool ?? false { c.expandSettings() } else { c.expandNotifications() }
            return ["ok": true]

        case "unlock":
            c.unlock(pin: pinProvider?())
            return ["locked": DeviceQueries(adb: c.adb, serial: try requireSerial()).isLocked()]

        case "screen_power":
            let on = p["on"] as? Bool ?? true
            c.setDisplayPower(on)
            return ["ok": true]

        case "rotate":
            c.rotate()
            return ["ok": true]

        case "shell":
            let cmd = try requireString(p, "command")
            let out = try c.adb.shell(serial: try requireSerial(), cmd, timeout: (num(p, "timeout_ms") ?? 20_000) / 1000)
            return ["output": out]

        case "install_apk":
            let path = (try requireString(p, "path") as NSString).expandingTildeInPath
            let (status, out) = try ADBTool.run(["-s", try requireSerial(), "install", "-r", path], timeout: 300)
            if status != 0 { throw ADBError(out) }
            return ["output": out.trimmingCharacters(in: .whitespacesAndNewlines)]

        case "push_file":
            let path = (try requireString(p, "path") as NSString).expandingTildeInPath
            var remote = p["remote_path"] as? String ?? "/sdcard/Download/"
            if remote.hasSuffix("/") { remote += (path as NSString).lastPathComponent }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            try c.adb.push(serial: try requireSerial(), data: data, remotePath: remote)
            c.send(ControlMessage.scanFile(remote))
            return ["remote_path": remote, "bytes": data.count]

        case "pull_file":
            let remote = try requireString(p, "remote_path")
            let data = try c.adb.pull(serial: try requireSerial(), remotePath: remote)
            var local = ((p["path"] as? String) ?? "~/Downloads/" as String)
            local = (local as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: local, isDirectory: &isDir), isDir.boolValue {
                local = (local as NSString).appendingPathComponent((remote as NSString).lastPathComponent)
            }
            try data.write(to: URL(fileURLWithPath: local))
            return ["path": local, "bytes": data.count]

        default:
            throw ADBError("unknown devicetools method '\(method)'")
        }
    }

    func cachedApps() throws -> [PhoneApp] {
        cacheLock.lock()
        let cached = appCache
        cacheLock.unlock()
        if let (t, apps) = cached, Date().timeIntervalSince(t) < 300 { return apps }
        let apps = try DeviceQueries(adb: controller.adb, serial: try requireSerial()).listApps()
        cacheLock.lock(); appCache = (Date(), apps); cacheLock.unlock()
        return apps
    }

    func resolveApp(label: String) throws -> String {
        let apps = try cachedApps()
        let l = label.lowercased()
        if let exact = apps.first(where: { $0.label.lowercased() == l }) { return exact.package }
        let partial = apps.filter { $0.label.lowercased().contains(l) }
        if partial.count == 1 { return partial[0].package }
        if partial.isEmpty { throw ADBError("no app named '\(label)'") }
        throw ADBError("several apps match '\(label)': " + partial.prefix(8).map { "\($0.label) (\($0.package))" }.joined(separator: ", "))
    }

    func statusInfo() -> [String: Any] {
        // @Published state is owned by the main thread: snapshot it there.
        let visible = windowVisible?() ?? false
        if Thread.isMainThread { return statusSnapshot(visible) }
        return DispatchQueue.main.sync { statusSnapshot(visible) }
    }

    func statusSnapshot(_ windowVisible: Bool) -> [String: Any] {
        let c = controller
        var r: [String: Any] = ["state": "\(c.state)", "mirroring": c.isStreaming]
        if let d = c.device {
            r["device"] = ["name": d.name, "model": d.model, "android": d.androidVersion,
                           "paths": d.transports.map { ["serial": $0.serial, "kind": $0.kind.rawValue, "online": $0.isOnline, "rtt_ms": $0.rttMs ?? -1] }]
        }
        if let t = c.activeTransport { r["active_path"] = ["serial": t.serial, "kind": t.kind.rawValue, "rtt_ms": t.rttMs ?? -1] }
        r["window_visible"] = windowVisible
        r["available_devices"] = c.devices.devices.map { ["id": $0.id, "name": $0.name] }
        r["unauthorized"] = c.devices.pending.filter { $0.state == "unauthorized" }.map(\.serial)
        return r
    }

    func deviceInfo() throws -> [String: Any] {
        let c = controller
        var r = statusInfo()
        let serial = try requireSerial()
        let q = DeviceQueries(adb: c.adb, serial: serial)
        if let b = q.battery() { r["battery"] = ["level": b.level, "charging": b.charging] }
        let (w, h) = c.screenSize
        r["video_size"] = [Int(w), Int(h)]
        if let phys = physicalSize(serial) { r["screen_size"] = [Int(phys.0), Int(phys.1)] }
        let s = DispatchQueue.main.sync { c.stats }
        r["stream"] = ["codec": s.codec, "fps": (s.fps * 10).rounded() / 10, "mbps": (s.bitrateMbps * 100).rounded() / 100]
        r["locked"] = q.isLocked()
        r["screen_on"] = q.isScreenOn()
        return r
    }
}

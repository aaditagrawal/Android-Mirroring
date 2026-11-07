import AgentProtocol
import CoreGraphics
import Darwin
import Foundation

/// Serves the agent API (see AgentProtocol) on a Unix domain socket.
/// Every connection is handled on its own thread; requests on one connection run in order.
public final class AgentServer: @unchecked Sendable {
    let controller: MirrorController
    private var listenFD: Int32 = -1
    private let path: String
    /// Hooks provided by the app.
    public var showWindow: ((Bool) -> Void)?
    public var windowVisible: (() -> Bool)?
    public var pinProvider: (() -> String?)?
    public var connectHandler: (() -> Void)?
    /// Debug: PNG of the app's own windows (hidden method `debug_window`).
    public var windowSnapshot: ((String) -> Data?)?

    /// Size of the last screenshot handed to an agent; defines "screenshot space".
    private var shotSize: CGSize?
    private let shotLock = NSLock()
    private var appCache: (Date, [PhoneApp])?

    public init(controller: MirrorController, path: String = AgentAPI.socketPath) {
        self.controller = controller
        self.path = path
    }

    public func start() throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw ADBError("socket() failed") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes.prefix(raw.count - 1))
            raw[min(bytes.count, raw.count - 1)] = 0
        }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { throw ADBError("bind \(path): \(String(cString: strerror(errno)))") }
        chmod(path, 0o600) // only this user
        listen(listenFD, 16)
        Log.info("agent API listening on \(path)")
        let t = Thread { [weak self] in self?.acceptLoop() }
        t.qualityOfService = .userInteractive
        t.start()
    }

    public func stop() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(path)
    }

    private func acceptLoop() {
        while listenFD >= 0 {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { if errno == EINTR { continue }; break }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let t = Thread { [weak self] in self?.serve(fd) }
            t.qualityOfService = .userInteractive
            t.name = "agent-conn"
            t.start()
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard !line.isEmpty else { continue }
                let response = handleLine(Data(line))
                var out = (try? JSONSerialization.data(withJSONObject: response)) ?? Data("{\"error\":\"encode\"}".utf8)
                out.append(0x0A)
                let ok = out.withUnsafeBytes { raw -> Bool in
                    var off = 0
                    while off < raw.count {
                        let w = write(fd, raw.baseAddress! + off, raw.count - off)
                        if w <= 0 { return false }
                        off += w
                    }
                    return true
                }
                if !ok { return }
            }
        }
    }

    private func handleLine(_ line: Data) -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let method = obj["method"] as? String else {
            return ["error": "invalid request"]
        }
        let id = obj["id"] ?? NSNull()
        let params = obj["params"] as? [String: Any] ?? [:]
        let t0 = Date()
        do {
            let result = try handle(method, params)
            Log.info("agent \(method) \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            return ["id": id, "result": result]
        } catch {
            Log.warn("agent \(method) failed: \(error)")
            return ["id": id, "error": "\(error)"]
        }
    }

    // MARK: Coordinate spaces

    private func deviceSize() throws -> CGSize {
        let (w, h) = controller.screenSize
        guard w > 0 else { throw ADBError("not mirroring: no phone connected (call status / open Android Mirroring)") }
        return CGSize(width: Int(w), height: Int(h))
    }

    private func currentShotSize(_ dev: CGSize) -> CGSize {
        shotLock.lock(); defer { shotLock.unlock() }
        if let s = shotSize, abs(s.width / s.height - dev.width / dev.height) < 0.02 { return s }
        let scale = min(1, CGFloat(AgentAPI.defaultMaxDimension) / max(dev.width, dev.height))
        return CGSize(width: (dev.width * scale).rounded(), height: (dev.height * scale).rounded())
    }

    /// Convert from the requested space to device pixels.
    private func toDevice(_ x: Double, _ y: Double, _ params: [String: Any]) throws -> (Double, Double) {
        let dev = try deviceSize()
        switch params["space"] as? String ?? "screenshot" {
        case "device": return (x, y)
        case "normalized": return (x * dev.width, y * dev.height)
        default:
            let s = currentShotSize(dev)
            return (x * dev.width / s.width, y * dev.height / s.height)
        }
    }

    private func fromDevice(_ r: CGRect, _ params: [String: Any]) throws -> CGRect {
        let dev = try deviceSize()
        switch params["space"] as? String ?? "screenshot" {
        case "device": return r
        case "normalized": return CGRect(x: r.minX / dev.width, y: r.minY / dev.height, width: r.width / dev.width, height: r.height / dev.height)
        default:
            let s = currentShotSize(dev)
            let fx = s.width / dev.width, fy = s.height / dev.height
            return CGRect(x: (r.minX * fx).rounded(), y: (r.minY * fy).rounded(), width: (r.width * fx).rounded(), height: (r.height * fy).rounded())
        }
    }

    /// The uiautomator tree uses the *physical* display resolution, which can differ from the
    /// video size (max_size scaling). Map it to video pixels.
    private func uiScale() throws -> (Double, Double) {
        let dev = try deviceSize()
        let serial = try requireSerial()
        if let phys = physicalSize(serial) {
            // Account for rotation: compare orientation.
            let landscapeVideo = dev.width > dev.height
            let (pw, ph) = landscapeVideo == (phys.0 > phys.1) ? phys : (phys.1, phys.0)
            return (dev.width / pw, dev.height / ph)
        }
        return (1, 1)
    }

    private var physicalSizeCache: [String: (Double, Double)] = [:]
    private func physicalSize(_ serial: String) -> (Double, Double)? {
        if let c = physicalSizeCache[serial] { return c }
        guard let out = try? controller.adb.shell(serial: serial, "wm size", timeout: 5) else { return nil }
        // "Physical size: 1080x2340\nOverride size: ..." – the override (if any) is what apps see.
        let lines = out.split(separator: "\n")
        let line = lines.first(where: { $0.contains("Override size") }) ?? lines.first(where: { $0.contains("Physical size") })
        guard let l = line, let dims = l.split(separator: ":").last?.trimmingCharacters(in: .whitespaces).split(separator: "x"),
              dims.count == 2, let w = Double(dims[0]), let h = Double(dims[1]) else { return nil }
        physicalSizeCache[serial] = (w, h)
        return (w, h)
    }

    private func requireSerial() throws -> String {
        guard let s = controller.serial else { throw ADBError("not mirroring: no phone connected") }
        return s
    }

    private func num(_ p: [String: Any], _ k: String) -> Double? {
        if let d = p[k] as? Double { return d }
        if let i = p[k] as? Int { return Double(i) }
        if let s = p[k] as? String { return Double(s) }
        return nil
    }

    private func requireNum(_ p: [String: Any], _ k: String) throws -> Double {
        guard let v = num(p, k) else { throw ADBError("missing parameter '\(k)'") }
        return v
    }

    private func requireString(_ p: [String: Any], _ k: String) throws -> String {
        guard let v = p[k] as? String, !v.isEmpty else { throw ADBError("missing parameter '\(k)'") }
        return v
    }

    private func waitForStreaming(timeout: TimeInterval = 8) throws {
        if controller.serial != nil && controller.screenSize.0 > 0 { return }
        connectHandler?()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if controller.serial != nil && controller.screenSize.0 > 0 { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw ADBError("no phone is being mirrored. Open Android Mirroring and connect your phone (state: \(controller.state))")
    }

    // MARK: Dispatch

    private func handle(_ method: String, _ p: [String: Any]) throws -> [String: Any] {
        switch method {
        case "status":
            return statusInfo()
        case "show_window":
            let v = p["visible"] as? Bool ?? true
            DispatchQueue.main.async { self.showWindow?(v) }
            return ["ok": true]
        case "wait":
            Thread.sleep(forTimeInterval: (num(p, "ms") ?? 500) / 1000)
            return ["ok": true]
        case "debug_window":
            guard let png = windowSnapshot?(p["window"] as? String ?? "mirror") else { throw ADBError("window not available") }
            let path = p["path"] as? String ?? NSTemporaryDirectory() + "android-mirroring-window.png"
            try png.write(to: URL(fileURLWithPath: path))
            return ["path": path, "bytes": png.count]
        default:
            break
        }

        try waitForStreaming()
        let c = controller

        switch method {
        case "screenshot":
            let maxDim = Int(num(p, "max_dimension") ?? Double(AgentAPI.defaultMaxDimension))
            let format = FrameStore.Format(rawValue: p["format"] as? String ?? "jpeg") ?? .jpeg
            if p["wait_for_idle"] as? Bool ?? true { _ = c.frames.waitForIdle(quiet: 0.25, timeout: 2) }
            guard let enc = c.frames.encoded(format: format, maxDimension: maxDim == 0 ? nil : maxDim, quality: 0.75) else {
                throw ADBError("no frame available yet")
            }
            shotLock.lock(); shotSize = CGSize(width: enc.width, height: enc.height); shotLock.unlock()
            let dev = try deviceSize()
            return ["image": enc.data.base64EncodedString(), "mime": format == .png ? "image/png" : "image/jpeg",
                    "width": enc.width, "height": enc.height, "device_width": Int(dev.width), "device_height": Int(dev.height)]

        case "tap":
            let (x, y) = try toDevice(try requireNum(p, "x"), try requireNum(p, "y"), p)
            c.tap(x: x, y: y)
            return ["ok": true]

        case "double_tap":
            let (x, y) = try toDevice(try requireNum(p, "x"), try requireNum(p, "y"), p)
            c.tap(x: x, y: y); preciseSleep(microseconds: 90_000); c.tap(x: x, y: y)
            return ["ok": true]

        case "long_press":
            let (x, y) = try toDevice(try requireNum(p, "x"), try requireNum(p, "y"), p)
            c.longPress(x: x, y: y, ms: Int(num(p, "duration_ms") ?? 600))
            return ["ok": true]

        case "swipe":
            let (x1, y1) = try toDevice(try requireNum(p, "x1"), try requireNum(p, "y1"), p)
            let (x2, y2) = try toDevice(try requireNum(p, "x2"), try requireNum(p, "y2"), p)
            c.swipe(x1: x1, y1: y1, x2: x2, y2: y2, ms: Int(num(p, "duration_ms") ?? 300))
            return ["ok": true]

        case "scroll":
            let dev = try deviceSize()
            var (x, y) = (Double(dev.width) / 2, Double(dev.height) / 2)
            if let px = num(p, "x"), let py = num(p, "y") { (x, y) = try toDevice(px, py, p) }
            let dx = num(p, "dx") ?? 0, dy = num(p, "dy") ?? 0
            // Android: positive vscroll scrolls up; agent semantics: positive dy reveals content below.
            var remaining = (dx, -dy)
            while abs(remaining.0) > 0.001 || abs(remaining.1) > 0.001 {
                let sx = max(-1, min(1, remaining.0)), sy = max(-1, min(1, remaining.1))
                c.scroll(x: x, y: y, dx: Float(sx), dy: Float(sy))
                remaining.0 -= sx; remaining.1 -= sy
                preciseSleep(microseconds: 16_000)
            }
            return ["ok": true]

        case "pinch":
            let dev = try deviceSize()
            var (x, y) = (Double(dev.width) / 2, Double(dev.height) / 2)
            if let px = num(p, "x"), let py = num(p, "y") { (x, y) = try toDevice(px, py, p) }
            c.pinch(cx: x, cy: y, scale: try requireNum(p, "scale"))
            return ["ok": true]

        case "type_text":
            guard let text = p["text"] as? String else { throw ADBError("missing parameter 'text'") }
            c.type(text)
            if p["submit"] as? Bool ?? false { preciseSleep(microseconds: 80_000); c.key(AKey.enter) }
            return ["ok": true]

        case "press_key":
            let keyName = try requireString(p, "key").lowercased()
            guard let code = AKey.named[keyName] ?? Int32(keyName) else { throw ADBError("unknown key '\(keyName)'") }
            var meta: Int32 = 0
            for m in p["meta"] as? [String] ?? [] {
                switch m {
                case "shift": meta |= AKey.metaShiftOn
                case "ctrl": meta |= AKey.metaCtrlOn | AKey.metaCtrlLeftOn
                case "alt": meta |= AKey.metaAltOn
                case "meta": meta |= AKey.metaMetaOn
                default: break
                }
            }
            c.key(code, meta: meta, longPress: p["long_press"] as? Bool ?? false)
            return ["ok": true]

        case "ui_tree":
            let nodes = try DeviceQueries(adb: c.adb, serial: try requireSerial()).uiTree()
            let (sx, sy) = try uiScale()
            let filter = (p["filter"] as? String)?.lowercased()
            let all = p["all"] as? Bool ?? false
            var out: [[String: Any]] = []
            for n in nodes {
                if let f = filter, n.matches(f) == nil { continue }
                if !all && filter == nil && n.label.isEmpty && !n.interactive { continue }
                if n.bounds.width <= 0 || n.bounds.height <= 0 { continue }
                let devRect = CGRect(x: n.bounds.minX * sx, y: n.bounds.minY * sy, width: n.bounds.width * sx, height: n.bounds.height * sy)
                let r = try fromDevice(devRect, p)
                var e: [String: Any] = ["bounds": [Int(r.minX), Int(r.minY), Int(r.maxX), Int(r.maxY)],
                                        "center": [Int(r.midX), Int(r.midY)]]
                if !n.text.isEmpty { e["text"] = n.text }
                if !n.desc.isEmpty { e["desc"] = n.desc }
                if !n.resourceId.isEmpty { e["id"] = n.resourceId.split(separator: "/").last.map(String.init) ?? n.resourceId }
                e["class"] = n.className.split(separator: ".").last.map(String.init) ?? n.className
                if n.clickable { e["clickable"] = true }
                if n.longClickable { e["long_clickable"] = true }
                if n.scrollable { e["scrollable"] = true }
                if n.editable { e["editable"] = true }
                if n.focused { e["focused"] = true }
                if n.selected { e["selected"] = true }
                if let ch = n.checked { e["checked"] = ch }
                if !n.enabled { e["enabled"] = false }
                out.append(e)
            }
            let fg = nodes.first?.package ?? ""
            return ["elements": out, "count": out.count, "package": fg]

        case "tap_element":
            let q = try requireString(p, "query")
            let nodes = try DeviceQueries(adb: c.adb, serial: try requireSerial()).uiTree()
            let matches = nodes.compactMap { n -> (Int, UINode)? in
                guard n.bounds.width > 0, let score = n.matches(q) else { return nil }
                return (score * 2 + (n.clickable ? 0 : 1), n)
            }.sorted { $0.0 < $1.0 }.map(\.1)
            let idx = Int(num(p, "index") ?? 0)
            guard idx < matches.count else { throw ADBError("no element matching '\(q)' (found \(matches.count))") }
            let n = matches[idx]
            let (sx, sy) = try uiScale()
            let x = n.center.x * sx, y = n.center.y * sy
            if p["long_press"] as? Bool ?? false { c.longPress(x: x, y: y, ms: 600) } else { c.tap(x: x, y: y) }
            let r = try fromDevice(CGRect(x: n.bounds.minX * sx, y: n.bounds.minY * sy, width: n.bounds.width * sx, height: n.bounds.height * sy), p)
            return ["tapped": n.label.isEmpty ? n.resourceId : n.label, "center": [Int(r.midX), Int(r.midY)], "matches": matches.count]

        case "wait_for":
            let q = try requireString(p, "query")
            let gone = p["gone"] as? Bool ?? false
            let deadline = Date().addingTimeInterval((num(p, "timeout_ms") ?? 10_000) / 1000)
            let dq = DeviceQueries(adb: c.adb, serial: try requireSerial())
            while Date() < deadline {
                let found = ((try? dq.uiTree()) ?? []).contains { $0.matches(q) != nil }
                if found != gone { return ["ok": true] }
                Thread.sleep(forTimeInterval: 0.3)
            }
            throw ADBError("timed out waiting for '\(q)'\(gone ? " to disappear" : "")")

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
            throw ADBError("unknown method '\(method)'")
        }
    }

    private func cachedApps() throws -> [PhoneApp] {
        if let (t, apps) = appCache, Date().timeIntervalSince(t) < 300 { return apps }
        let apps = try DeviceQueries(adb: controller.adb, serial: try requireSerial()).listApps()
        appCache = (Date(), apps)
        return apps
    }

    private func resolveApp(label: String) throws -> String {
        let apps = try cachedApps()
        let l = label.lowercased()
        if let exact = apps.first(where: { $0.label.lowercased() == l }) { return exact.package }
        let partial = apps.filter { $0.label.lowercased().contains(l) }
        if partial.count == 1 { return partial[0].package }
        if partial.isEmpty { throw ADBError("no app named '\(label)'") }
        throw ADBError("several apps match '\(label)': " + partial.prefix(8).map { "\($0.label) (\($0.package))" }.joined(separator: ", "))
    }

    private func statusInfo() -> [String: Any] {
        let c = controller
        var r: [String: Any] = ["state": "\(c.state)", "mirroring": c.isStreaming]
        if let d = c.device {
            r["device"] = ["name": d.name, "model": d.model, "android": d.androidVersion,
                           "paths": d.transports.map { ["serial": $0.serial, "kind": $0.kind.rawValue, "online": $0.isOnline, "rtt_ms": $0.rttMs ?? -1] }]
        }
        if let t = c.activeTransport { r["active_path"] = ["serial": t.serial, "kind": t.kind.rawValue, "rtt_ms": t.rttMs ?? -1] }
        r["window_visible"] = windowVisible?() ?? false
        r["available_devices"] = c.devices.devices.map { ["id": $0.id, "name": $0.name] }
        r["unauthorized"] = c.devices.pending.filter { $0.state == "unauthorized" }.map(\.serial)
        return r
    }

    private func deviceInfo() throws -> [String: Any] {
        let c = controller
        var r = statusInfo()
        let serial = try requireSerial()
        let q = DeviceQueries(adb: c.adb, serial: serial)
        if let b = q.battery() { r["battery"] = ["level": b.level, "charging": b.charging] }
        let (w, h) = c.screenSize
        r["video_size"] = [Int(w), Int(h)]
        if let phys = physicalSize(serial) { r["screen_size"] = [Int(phys.0), Int(phys.1)] }
        let s = c.stats
        r["stream"] = ["codec": s.codec, "fps": (s.fps * 10).rounded() / 10, "mbps": (s.bitrateMbps * 100).rounded() / 100]
        r["locked"] = q.isLocked()
        r["screen_on"] = q.isScreenOn()
        return r
    }
}

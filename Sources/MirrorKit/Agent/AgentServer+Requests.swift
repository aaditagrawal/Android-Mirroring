import AgentProtocol
import CoreGraphics
import Foundation

extension AgentServer {
    func requireSerial() throws -> String {
        guard let s = controller.serial else { throw ADBError("not mirroring: no phone connected") }
        return s
    }

    func num(_ p: [String: Any], _ k: String) -> Double? {
        if let d = p[k] as? Double { return d }
        if let i = p[k] as? Int { return Double(i) }
        if let s = p[k] as? String { return Double(s) }
        return nil
    }

    func requireNum(_ p: [String: Any], _ k: String) throws -> Double {
        guard let v = num(p, k) else { throw ADBError("missing parameter '\(k)'") }
        return v
    }

    func requireString(_ p: [String: Any], _ k: String) throws -> String {
        guard let v = p[k] as? String, !v.isEmpty else { throw ADBError("missing parameter '\(k)'") }
        return v
    }

    func waitForStreaming(timeout: TimeInterval = 8) throws {
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

    func handle(_ method: String, _ p: [String: Any]) throws -> [String: Any] {
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
        case "debug_present":
            try setPacing(p["pacing"])
            var r = presentStats?(p["reset"] as? Bool ?? false) ?? [:]
            let s = controller.session?.currentStats
            r["stream_fps"] = s?.fps ?? 0
            r["transport"] = controller.session?.activeTransport.rawValue ?? ""
            return r
        case "debug_synthetic":
            try setPacing(p["pacing"])
            guard let r = syntheticTest?(p) else { throw ADBError("renderer unavailable") }
            return r
        case "debug_window":
            guard let png = windowSnapshot?(p["window"] as? String ?? "mirror") else { throw ADBError("window not available") }
            let path = p["path"] as? String ?? NSTemporaryDirectory() + "android-mirroring-window.png"
            try png.write(to: URL(fileURLWithPath: path))
            return ["path": path, "bytes": png.count]
        default:
            break
        }

        try waitForStreaming()
        switch method {
        case "tap", "double_tap", "long_press", "swipe", "scroll", "pinch", "type_text", "press_key":
            return try handleInput(method, p)
        case "screenshot", "screen_text", "batch", "ui_tree", "tap_element", "wait_for":
            return try handleObservation(method, p)
        case "launch_app", "list_apps", "open_url", "current_app", "device_info", "get_clipboard", "set_clipboard", "notifications", "open_notifications", "unlock", "screen_power", "rotate", "shell", "install_apk", "push_file", "pull_file":
            return try handleDeviceTools(method, p)
        default:
            throw ADBError("unknown method '\(method)'")
        }
    }

}

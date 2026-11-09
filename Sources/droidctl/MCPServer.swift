import AgentProtocol
import Foundation

// MARK: - MCP server

final class MCPServer {
    var client: AgentClient?

    func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let id = msg["id"]
            let method = msg["method"] as? String ?? ""
            let params = msg["params"] as? [String: Any] ?? [:]
            if id == nil { continue } // notification (e.g. notifications/initialized)
            let response: [String: Any]
            switch method {
            case "initialize":
                let requested = params["protocolVersion"] as? String ?? "2025-06-18"
                response = result(id, [
                    "protocolVersion": requested,
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "android-mirroring", "version": "1.0.0"],
                    "instructions": """
                    Controls the user's Android phone through Android Mirroring (live, low-latency).
                    Every action (tap, swipe, type_text, press_key, tap_element, launch_app, ...) waits for the screen \
                    to settle and returns a screenshot, so the loop is: act → look at the returned image → act. Call \
                    screenshot only at the start. Pass screenshot:false on steps whose result you don't need to see.
                    Prefer tap_element (taps visible text via OCR) and launch_app (by app name) over coordinates. \
                    Use batch for known multi-step sequences, screen_text to read text cheaply, and wait_for to wait for \
                    something to load. Coordinates are pixels of the most recent screenshot. The phone does not need to \
                    be locked or idle; the user may be watching the mirror window.
                    """,
                ])
            case "ping":
                response = result(id, [:])
            case "tools/list":
                let tools = AgentTools.all.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.schema] as [String: Any] }
                response = result(id, ["tools": tools])
            case "tools/call":
                response = result(id, callTool(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:]))
            default:
                response = ["jsonrpc": "2.0", "id": id!, "error": ["code": -32601, "message": "method not found: \(method)"]]
            }
            send(response)
        }
    }

    private func result(_ id: Any?, _ r: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": r] }

    private func send(_ obj: [String: Any]) {
        guard var d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        d.append(0x0A)
        FileHandle.standardOutput.write(d)
    }

    private func callTool(_ name: String, _ args: [String: Any]) -> [String: Any] {
        guard AgentTools.named(name) != nil else {
            return ["content": [["type": "text", "text": "Unknown tool \(name)"]], "isError": true]
        }
        do {
            var args = args
            if AgentTools.named(name)?.isAction == true, args["screenshot"] == nil { args["screenshot"] = true }
            var r = try call(name, args)
            if let img = r["image"] as? String {
                let w = r["width"] as? Int ?? 0, h = r["height"] as? Int ?? 0
                let mime = r["mime"] as? String ?? "image/jpeg"
                for k in ["image", "mime", "width", "height", "device_width", "device_height"] { r.removeValue(forKey: k) }
                if r["ok"] as? Bool == true { r.removeValue(forKey: "ok") }
                var note = "Screenshot \(w)x\(h) px (coordinates use this grid)."
                if r["screen_changed"] as? Bool == false { note += " The screen did not change." }
                if r["still_changing"] as? Bool == true { note += " The screen was still changing (animation or loading)." }
                r.removeValue(forKey: "screen_changed"); r.removeValue(forKey: "still_changing"); r.removeValue(forKey: "settle_ms")
                var content: [[String: Any]] = [["type": "image", "data": img, "mimeType": mime]]
                content.append(["type": "text", "text": r.isEmpty ? note : jsonString(r) + "\n" + note])
                return ["content": content]
            }
            if let out = r["output"] as? String, r.count == 1 {
                return ["content": [["type": "text", "text": out]]]
            }
            if r.count == 1, r["ok"] as? Bool == true {
                return ["content": [["type": "text", "text": "ok"]]]
            }
            return ["content": [["type": "text", "text": jsonString(r)]]]
        } catch {
            return ["content": [["type": "text", "text": "Error: \(error)"]], "isError": true]
        }
    }

    /// Calls the app, reconnecting once if the app restarted.
    private func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        if client == nil { client = try connectClient() }
        do {
            return try client!.call(method, params)
        } catch AgentError.message(let m) where m.contains("connection closed") || m.contains("write failed") {
            client = try connectClient()
            return try client!.call(method, params)
        }
    }
}

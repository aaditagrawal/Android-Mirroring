import AgentProtocol
import CoreGraphics
import Foundation

extension AgentServer {
    func handleInput(_ method: String, _ p: [String: Any]) throws -> [String: Any] {
        let c = controller
        switch method {
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

        default:
            throw ADBError("unknown input method '\(method)'")
        }
    }

}

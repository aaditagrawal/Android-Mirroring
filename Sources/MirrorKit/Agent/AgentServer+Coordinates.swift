import AgentProtocol
import CoreGraphics
import Foundation

extension AgentServer {
    // MARK: Coordinate spaces

    func deviceSize() throws -> CGSize {
        let (w, h) = controller.screenSize
        guard w > 0 else { throw ADBError("not mirroring: no phone connected (call status / open Android Mirroring)") }
        return CGSize(width: Int(w), height: Int(h))
    }

    func currentShotSize(_ dev: CGSize) -> CGSize {
        shotLock.lock(); defer { shotLock.unlock() }
        if let s = shotSize, abs(s.width / s.height - dev.width / dev.height) < 0.02 { return s }
        let scale = min(1, CGFloat(AgentAPI.defaultMaxDimension) / max(dev.width, dev.height))
        return CGSize(width: (dev.width * scale).rounded(), height: (dev.height * scale).rounded())
    }

    /// Convert from the requested space to device pixels.
    func toDevice(_ x: Double, _ y: Double, _ params: [String: Any]) throws -> (Double, Double) {
        let dev = try deviceSize()
        switch params["space"] as? String ?? "screenshot" {
        case "device": return (x, y)
        case "normalized": return (x * dev.width, y * dev.height)
        default:
            let s = currentShotSize(dev)
            return (x * dev.width / s.width, y * dev.height / s.height)
        }
    }

    func fromDevice(_ r: CGRect, _ params: [String: Any]) throws -> CGRect {
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
    func uiScale() throws -> (Double, Double) {
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

    func physicalSize(_ serial: String) -> (Double, Double)? {
        cacheLock.lock()
        let cached = physicalSizeCache[serial]
        cacheLock.unlock()
        if let (t, c) = cached, Date().timeIntervalSince(t) < 30 { return c }
        guard let out = try? controller.adb.shell(serial: serial, "wm size", timeout: 5) else { return nil }
        // "Physical size: 1080x2340\nOverride size: ..." – the override (if any) is what apps see.
        let lines = out.split(separator: "\n")
        let line = lines.first(where: { $0.contains("Override size") }) ?? lines.first(where: { $0.contains("Physical size") })
        guard let l = line, let dims = l.split(separator: ":").last?.trimmingCharacters(in: .whitespaces).split(separator: "x"),
              dims.count == 2, let w = Double(dims[0]), let h = Double(dims[1]) else { return nil }
        cacheLock.lock(); physicalSizeCache[serial] = (Date(), (w, h)); cacheLock.unlock()
        return (w, h)
    }

}

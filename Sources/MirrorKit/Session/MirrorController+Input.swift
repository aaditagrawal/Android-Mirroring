import Foundation

extension MirrorController {
    // MARK: Input (device pixel coordinates)

    public var screenSize: (UInt16, UInt16) { session?.frameSize ?? (0, 0) }

    public func send(_ bytes: [UInt8]) { session?.send(bytes) }

    public func touch(_ action: MotionAction, x: Double, y: Double, pointer: UInt64 = PointerID.genericFinger, pressure: Float = 1) {
        guard let s = session else { return }
        let (w, h) = s.frameSize
        guard w > 0 else { return }
        let px = max(0, min(Double(w) - 1, x)), py = max(0, min(Double(h) - 1, y))
        s.send(ControlMessage.touch(action, pointer: pointer, at: DevicePoint(px, py), screen: (w, h), pressure: pressure))
    }

    public func scroll(x: Double, y: Double, dx: Float, dy: Float) {
        guard let s = session else { return }
        let (w, h) = s.frameSize
        guard w > 0 else { return }
        s.send(ControlMessage.scroll(at: DevicePoint(x, y), screen: (w, h), h: dx, v: dy))
    }

    public func key(_ code: Int32, meta: Int32 = 0, longPress: Bool = false) {
        guard let s = session else { return }
        s.send(ControlMessage.keycode(.down, code, meta: meta))
        if longPress {
            for i in 1...12 { preciseSleep(microseconds: 50_000); s.send(ControlMessage.keycode(.down, code, repeatCount: Int32(i), meta: meta)) }
        }
        s.send(ControlMessage.keycode(.up, code, meta: meta))
    }

    public func keyEvent(_ action: KeyAction, _ code: Int32, meta: Int32 = 0, repeatCount: Int32 = 0) {
        session?.send(ControlMessage.keycode(action, code, repeatCount: repeatCount, meta: meta))
    }

    /// Type text. ASCII goes through key injection; anything else via clipboard paste,
    /// which works in every text field regardless of keyboard app.
    public func type(_ text: String) {
        guard let s = session, !text.isEmpty else { return }
        let ascii = text.unicodeScalars.allSatisfy { $0.isASCII && ($0.value >= 0x20 || $0 == "\n" || $0 == "\t") }
        if ascii {
            var chunk = ""
            for ch in text {
                if ch == "\n" {
                    if !chunk.isEmpty { s.send(ControlMessage.text(chunk)); chunk = "" }
                    key(AKey.enter)
                    continue
                }
                chunk.append(ch)
                if chunk.utf8.count >= 250 { s.send(ControlMessage.text(chunk)); chunk = "" }
            }
            if !chunk.isEmpty { s.send(ControlMessage.text(chunk)) }
        } else {
            setDeviceClipboard(text, paste: true)
        }
    }

    public func backOrScreenOn() {
        session?.send(ControlMessage.backOrScreenOn(.down))
        session?.send(ControlMessage.backOrScreenOn(.up))
    }

    public func setDisplayPower(_ on: Bool) { session?.send(ControlMessage.setDisplayPower(on)) }
    public func rotate() { session?.send(ControlMessage.rotateDevice()) }
    public func expandNotifications() { session?.send(ControlMessage.expandNotifications()) }
    public func expandSettings() { session?.send(ControlMessage.expandSettings()) }
    public func collapsePanels() { session?.send(ControlMessage.collapsePanels()) }
    public func startApp(_ name: String) { session?.send(ControlMessage.startApp(name)) }
    public func requestKeyFrame() { session?.send(ControlMessage.resetVideo()) }
    public var audioVolume: Float {
        get { session?.audioVolume ?? 1 }
        set { session?.audioVolume = newValue }
    }

    // MARK: Gestures (blocking; call off the main thread)

    public func tap(x: Double, y: Double) {
        touch(.down, x: x, y: y)
        preciseSleep(microseconds: 40_000)
        touch(.up, x: x, y: y)
    }

    public func longPress(x: Double, y: Double, ms: Int) {
        touch(.down, x: x, y: y)
        var waited = 0
        while waited < ms { preciseSleep(microseconds: 100_000); waited += 100; touch(.move, x: x, y: y) }
        touch(.up, x: x, y: y)
    }

    public func swipe(x1: Double, y1: Double, x2: Double, y2: Double, ms: Int) {
        let steps = max(4, ms / 8)
        touch(.down, x: x1, y: y1)
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            // ease-in-out so the end velocity is realistic (prevents unintended flings)
            let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            touch(.move, x: x1 + (x2 - x1) * e, y: y1 + (y2 - y1) * e)
            preciseSleep(microseconds: max(1, ms * 1000 / steps))
        }
        touch(.up, x: x2, y: y2)
    }

    public func pinch(cx: Double, cy: Double, scale: Double, ms: Int = 400) {
        let (w, h) = screenSize
        let base = Double(min(w, h)) * 0.12
        let startR = scale >= 1 ? base : base * 2.5
        let endR = max(20, min(Double(min(w, h)) * 0.45, startR * scale))
        let steps = max(6, ms / 10)
        let p0: UInt64 = 10, p1: UInt64 = 11
        // Plain DOWN/UP for each finger: the scrcpy server adds the POINTER_* flags itself.
        touch(.down, x: cx - startR, y: cy, pointer: p0)
        touch(.down, x: cx + startR, y: cy, pointer: p1)
        for i in 1...steps {
            let r = startR + (endR - startR) * Double(i) / Double(steps)
            touch(.move, x: cx - r, y: cy, pointer: p0)
            touch(.move, x: cx + r, y: cy, pointer: p1)
            preciseSleep(microseconds: ms * 1000 / steps)
        }
        touch(.up, x: cx + endR, y: cy, pointer: p1)
        touch(.up, x: cx - endR, y: cy, pointer: p0)
    }

    /// Wake and unlock with a PIN (digits typed on the keyguard).
    public func unlock(pin: String?) {
        guard let s = session else { return }
        let q = DeviceQueries(adb: adb, serial: s.serial)
        if !q.isScreenOn() { key(AKey.wakeup); preciseSleep(microseconds: 400_000) }
        guard q.isLocked() else { return }
        let (w, h) = screenSize
        swipe(x1: Double(w) / 2, y1: Double(h) * 0.85, x2: Double(w) / 2, y2: Double(h) * 0.3, ms: 250)
        preciseSleep(microseconds: 500_000)
        if let pin, !pin.isEmpty {
            s.send(ControlMessage.text(pin))
            preciseSleep(microseconds: 150_000)
            key(AKey.enter)
        }
    }
}

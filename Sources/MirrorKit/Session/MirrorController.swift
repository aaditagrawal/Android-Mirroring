import AppKit
import Combine
import CoreVideo
import Foundation

public enum MirrorState: Equatable, Sendable {
    case idle
    case connecting(String)          // detail, e.g. "Connecting over Wi-Fi…"
    case streaming
    case reconnecting(String)
    case failed(String)

    public var isActive: Bool {
        switch self { case .streaming, .connecting, .reconnecting: return true; default: return false }
    }
}

/// User-tunable settings (backed by UserDefaults so the Settings UI binds directly).
public struct MirrorSettings {
    static var d: UserDefaults { .standard }
    public static var quality: String { d.string(forKey: "quality") ?? "auto" }      // auto | high | balanced | data
    public static var codec: String { d.string(forKey: "codec") ?? "h265" }
    public static var maxFps: Int { d.object(forKey: "maxFps") as? Int ?? 60 }
    public static var audio: Bool { d.object(forKey: "audio") as? Bool ?? true }
    public static var clipboardSync: Bool { d.object(forKey: "clipboardSync") as? Bool ?? true }
    public static var screenOffWhileMirroring: Bool { d.object(forKey: "screenOff") as? Bool ?? false }
    public static var stayAwake: Bool { d.object(forKey: "stayAwake") as? Bool ?? false }
    public static var showTouches: Bool { d.object(forKey: "showTouches") as? Bool ?? false }
    public static var autoSwitchPaths: Bool { d.object(forKey: "autoSwitchPaths") as? Bool ?? true }
    public static var lockPhoneOnDisconnect: Bool { d.object(forKey: "lockOnDisconnect") as? Bool ?? false }
}

public final class MirrorController: ObservableObject, @unchecked Sendable {
    @Published public private(set) var state: MirrorState = .idle
    @Published public private(set) var device: PhoneDevice?
    @Published public private(set) var activeTransport: Transport?
    @Published public private(set) var frameSize: CGSize = .zero
    @Published public private(set) var stats = StreamStats()
    @Published public private(set) var lastSwitchReason: String?

    public let devices: DeviceManager
    public let frames = FrameStore()
    public var adb: ADBClient { devices.adb }

    /// Called on the decoder thread for each decoded frame (the view enqueues it for display).
    public var displaySink: ((CVPixelBuffer) -> Void)?

    private let sessionLock = NSLock()
    private var _session: ScrcpySession?
    /// Accessed from the main thread, agent threads and decoder threads: lock-protected.
    private var session: ScrcpySession? {
        get { sessionLock.lock(); defer { sessionLock.unlock() }; return _session }
        set { sessionLock.lock(); _session = newValue; sessionLock.unlock() }
    }
    private let sessionQueue = DispatchQueue(label: "mirror-session", qos: .userInitiated)
    private var wantedDeviceId: String?
    private var generation = 0
    private var healthTimer: DispatchSourceTimer?
    private var consecutivePingFailures = 0
    private var reconnectAttempt = 0
    private var cancellables = Set<AnyCancellable>()
    private var clipboardSequence: UInt64 = 1
    private var lastClipboardFromDevice: String?
    private var pasteboardChangeCount = NSPasteboard.general.changeCount
    private var clipboardTimer: Timer?
    private var betterPathSince: Date?
    private var pendingClipboardReply: ((String) -> Void)?
    /// True while a session is being started (server push/launch/socket connect).
    private var startInFlight = false
    /// True when no usable transport exists: the next device-list change may start a session.
    /// (Otherwise retries are driven only by `scheduleReconnect`'s backoff, never by list churn.)
    private var waitingForDevice = false
    private var reconnectScheduled = false

    public init(devices: DeviceManager) {
        self.devices = devices
        devices.$devices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] list in self?.devicesChanged(list) }
            .store(in: &cancellables)
    }

    public var serial: String? { session?.serial }
    public var isStreaming: Bool { state == .streaming }

    // MARK: Connect / disconnect

    /// Start mirroring a phone; keeps it connected (failover + reconnect) until `disconnect()`.
    public func connect(deviceId: String) {
        DispatchQueue.main.async { [self] in
            wantedDeviceId = deviceId
            devices.focusDeviceId = deviceId
            reconnectAttempt = 0
            reconnectScheduled = false
            if let d = devices.device(id: deviceId) {
                device = d
                waitingForDevice = false
                startSession(on: d, reason: nil)
            } else {
                waitingForDevice = true
                state = .connecting("Looking for your phone…")
            }
        }
    }

    public func disconnect() {
        DispatchQueue.main.async { [self] in
            wantedDeviceId = nil
            generation += 1
            startInFlight = false
            stopHealth()
            let s = session
            session = nil
            if MirrorSettings.lockPhoneOnDisconnect, let s {
                s.send(ControlMessage.keycode(.down, AKey.sleep)); s.send(ControlMessage.keycode(.up, AKey.sleep))
            }
            sessionQueue.async { s?.stop() }
            activeTransport = nil
            state = .idle
            frames.clear()
            clipboardTimer?.invalidate()
        }
    }

    /// Restart the stream with current settings (after a settings change).
    public func restart() {
        DispatchQueue.main.async { [self] in
            guard let d = device ?? wantedDeviceId.flatMap(devices.device(id:)) else { return }
            startSession(on: d, reason: "Applying settings")
        }
    }

    private func devicesChanged(_ list: [PhoneDevice]) {
        guard let id = wantedDeviceId else { return }
        if let d = list.first(where: { $0.id == id }) {
            device = d
            if let t = activeTransport, let nt = d.transports.first(where: { $0.serial == t.serial }) {
                activeTransport = nt
            }
            switch state {
            case .connecting, .reconnecting, .failed:
                if waitingForDevice && session == nil && !startInFlight && !reconnectScheduled && d.isOnline {
                    waitingForDevice = false
                    startSession(on: d, reason: nil)
                }
            case .streaming:
                considerUpgrade(d)
            case .idle:
                break
            }
        }
    }

    private func options(for t: Transport) -> StreamOptions {
        var o: StreamOptions
        let q = MirrorSettings.quality
        switch q {
        case "high":
            o = StreamOptions(); o.maxSize = 0; o.videoBitRate = 16_000_000
        case "balanced":
            o = StreamOptions(); o.maxSize = 1920; o.videoBitRate = 8_000_000
        case "data":
            o = .remote(); o.maxSize = 1280; o.videoBitRate = 3_000_000; o.maxFps = 45
        default: // auto: pick by path
            let slow = t.kind == .tailscale || t.kind == .remote || (t.rttMs ?? 0) > 60
            if t.kind == .usb { o = StreamOptions(); o.maxSize = 0; o.videoBitRate = 20_000_000 }
            else if slow { o = .remote() }
            else { o = StreamOptions(); o.maxSize = 0; o.videoBitRate = 12_000_000 }
        }
        o.videoCodec = MirrorSettings.codec
        if q != "data" { o.maxFps = MirrorSettings.maxFps }
        o.audio = MirrorSettings.audio
        o.clipboardAutosync = MirrorSettings.clipboardSync
        o.stayAwake = MirrorSettings.stayAwake
        o.showTouches = MirrorSettings.showTouches
        return o
    }

    private func startSession(on d: PhoneDevice, reason: String?, excluding: Set<String> = []) {
        generation += 1
        let gen = generation
        let old = session
        session = nil
        stopHealth()

        let candidates = d.transports.filter { $0.isOnline && !excluding.contains($0.serial) }
        guard let t = (candidates.filter(\.isHealthy).sorted { a, b in
            a.kind != b.kind ? a.kind < b.kind : (a.rttMs ?? 999) < (b.rttMs ?? 999)
        }.first ?? candidates.first) else {
            state = .reconnecting("Waiting for a connection to \(d.name)…")
            startInFlight = false
            waitingForDevice = true
            sessionQueue.async { old?.stop() }
            return
        }
        let opts = options(for: t)
        startInFlight = true
        let detail = reason.map { "\($0) — \(t.kind.label)" } ?? "Connecting over \(t.kind.label)…"
        if case .streaming = state, reason != nil { state = .reconnecting(detail) } else { state = .connecting(detail) }
        if reason != nil { lastSwitchReason = reason }

        sessionQueue.async { [weak self] in
            old?.stop()
            guard let self else { return }
            let s = ScrcpySession(adb: self.adb, serial: t.serial, options: opts)
            s.onFrame = { [weak self] pb in
                guard let self else { return }
                self.frames.update(pb)
                self.displaySink?(pb)
            }
            s.onFrameSize = { [weak self] w, h in
                DispatchQueue.main.async { self?.frameSize = CGSize(width: w, height: h) }
            }
            s.onStats = { [weak self] st in DispatchQueue.main.async { self?.stats = st } }
            s.onClipboard = { [weak self] text in self?.clipboardFromDevice(text) }
            s.onClosed = { [weak self] reason in
                DispatchQueue.main.async { self?.sessionClosed(gen: gen, serial: t.serial, reason: reason) }
            }
            do {
                try s.start()
            } catch {
                DispatchQueue.main.async {
                    if gen == self.generation { self.startInFlight = false }
                    guard gen == self.generation else { s.stop(); return }
                    Log.error("session start failed on \(t.serial): \(error)")
                    self.devices.reportFailure(serial: t.serial)
                    self.scheduleReconnect(after: "\(error)", failedSerial: t.serial)
                }
                return
            }
            DispatchQueue.main.async {
                if gen == self.generation { self.startInFlight = false }
                guard gen == self.generation else { s.stop(); return }
                self.session = s
                self.activeTransport = t
                self.state = .streaming
                self.reconnectAttempt = 0
                self.consecutivePingFailures = 0
                self.betterPathSince = nil
                self.devices.markConnected(d.id)
                self.startHealth(gen: gen)
                self.startClipboardSync()
                if MirrorSettings.screenOffWhileMirroring {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { s.send(ControlMessage.setDisplayPower(false)) }
                }
            }
        }
    }

    private func sessionClosed(gen: Int, serial: String, reason: String?) {
        guard gen == generation, wantedDeviceId != nil else { return }
        session = nil
        devices.reportFailure(serial: serial)
        scheduleReconnect(after: reason ?? "stream ended", failedSerial: serial)
    }

    private func scheduleReconnect(after reason: String, failedSerial: String?) {
        guard let id = wantedDeviceId, !reconnectScheduled else { return }
        reconnectAttempt += 1
        let delay = min(0.25 * pow(2, Double(reconnectAttempt - 1)), 3)
        state = .reconnecting(reconnectAttempt > 2 ? "Reconnecting… (\(shortReason(reason)))" : "Reconnecting…")
        reconnectScheduled = true
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.reconnectScheduled = false
            guard gen == self.generation, self.wantedDeviceId == id else { return }
            guard let d = self.devices.device(id: id), d.isOnline else {
                self.waitingForDevice = true
                self.state = .reconnecting("Waiting for \(self.device?.name ?? "phone")…")
                return
            }
            // Prefer a different path than the one that just failed, if one exists.
            let exclude: Set<String> = (failedSerial != nil && d.transports.filter(\.isOnline).count > 1) ? [failedSerial!] : []
            self.startSession(on: d, reason: exclude.isEmpty ? nil : "Switched path", excluding: exclude)
        }
    }

    private func shortReason(_ r: String) -> String {
        if r.contains("Connection refused") || r.contains("unreachable") { return "ADB server unreachable" }
        if r.contains("timeout") || r.contains("timed out") { return "phone not responding" }
        if r.contains("closed") { return "connection dropped" }
        return String(r.prefix(60))
    }

    // MARK: Health & path upgrades

    private func startHealth(gen: Int) {
        stopHealth()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self, let s = self.session, gen == self.generation else { return }
            let ok = self.adb.ping(serial: s.serial, timeout: 2.5) != nil
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                if ok { self.consecutivePingFailures = 0; return }
                self.consecutivePingFailures += 1
                Log.warn("health probe failed on \(s.serial) (\(self.consecutivePingFailures))")
                if self.consecutivePingFailures >= 2, let d = self.device {
                    self.devices.reportFailure(serial: s.serial)
                    self.startSession(on: d, reason: "Connection lost", excluding: [s.serial])
                }
            }
        }
        t.resume()
        healthTimer = t
    }

    private func stopHealth() { healthTimer?.cancel(); healthTimer = nil }

    /// If a strictly better path (e.g. back on home Wi-Fi, or USB plugged in) has been healthy
    /// for a few seconds, move the stream to it.
    private func considerUpgrade(_ d: PhoneDevice) {
        guard MirrorSettings.autoSwitchPaths, let active = activeTransport, let best = d.bestTransport,
              best.serial != active.serial, best.kind < active.kind, best.rttMs != nil else {
            betterPathSince = nil
            return
        }
        if let since = betterPathSince {
            if Date().timeIntervalSince(since) > 4 {
                betterPathSince = nil
                startSession(on: d, reason: "Faster connection available")
            }
        } else {
            betterPathSince = Date()
        }
    }

    /// Manually move the stream to a specific transport.
    public func switchTo(serial: String) {
        DispatchQueue.main.async { [self] in
            guard let d = device else { return }
            let others = Set(d.transports.map(\.serial)).subtracting([serial])
            startSession(on: d, reason: "Switching", excluding: others)
        }
    }

    // MARK: Clipboard

    private func clipboardFromDevice(_ text: String) {
        DispatchQueue.main.async { [self] in
            if let reply = pendingClipboardReply {
                pendingClipboardReply = nil
                reply(text)
            }
            guard MirrorSettings.clipboardSync else { return }
            lastClipboardFromDevice = text
            let pb = NSPasteboard.general
            if pb.string(forType: .string) != text {
                pb.clearContents()
                pb.setString(text, forType: .string)
            }
            pasteboardChangeCount = pb.changeCount
        }
    }

    private func startClipboardSync() {
        clipboardTimer?.invalidate()
        pasteboardChangeCount = NSPasteboard.general.changeCount
        guard MirrorSettings.clipboardSync else { return }
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let pb = NSPasteboard.general
            guard pb.changeCount != self.pasteboardChangeCount else { return }
            self.pasteboardChangeCount = pb.changeCount
            guard let text = pb.string(forType: .string), text != self.lastClipboardFromDevice else { return }
            self.setDeviceClipboard(text, paste: false)
        }
    }

    public func setDeviceClipboard(_ text: String, paste: Bool) {
        clipboardSequence += 1
        session?.send(ControlMessage.setClipboard(sequence: clipboardSequence, text: text, paste: paste))
    }

    /// Ask the device for its clipboard (optionally injecting COPY first).
    public func fetchDeviceClipboard(copyKey: UInt8 = 0, timeout: TimeInterval = 2, completion: @escaping (String?) -> Void) {
        DispatchQueue.main.async { [self] in
            guard let s = session else { completion(nil); return }
            var done = false
            pendingClipboardReply = { text in
                guard !done else { return }
                done = true
                completion(text)
            }
            s.send(ControlMessage.getClipboard(copyKey: copyKey))
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard !done else { return }
                done = true
                self.pendingClipboardReply = nil
                completion(nil)
            }
        }
    }

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
        touch(.down, x: cx - startR, y: cy, pointer: p0)
        touch(.pointerDown, x: cx + startR, y: cy, pointer: p1)
        for i in 1...steps {
            let r = startR + (endR - startR) * Double(i) / Double(steps)
            touch(.move, x: cx - r, y: cy, pointer: p0)
            touch(.move, x: cx + r, y: cy, pointer: p1)
            preciseSleep(microseconds: ms * 1000 / steps)
        }
        touch(.pointerUp, x: cx + endR, y: cy, pointer: p1)
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

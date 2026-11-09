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

    /// Called on the decoder thread for each decoded frame (the view schedules it for display).
    public var displaySink: ((DecodedFrame) -> Void)?

    private let sessionLock = NSLock()
    private var _session: ScrcpySession?
    /// Accessed from the main thread, agent threads and decoder threads: lock-protected.
    public internal(set) var session: ScrcpySession? {
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
    /// Generation that scheduled the pending retry (nil = none pending).
    private var reconnectGeneration: Int?
    private var reconnectScheduled: Bool { reconnectGeneration == generation }
    /// Transports that recently failed to start a stream; not eligible for automatic upgrades.
    private var startFailures: [String: Date] = [:]
    private var clipboardRequestId = 0

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
            reconnectGeneration = nil
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
        default: // auto: pick by measured latency (Tailscale is often a direct LAN path)
            if t.kind == .usb { o = StreamOptions(); o.maxSize = 0; o.videoBitRate = 20_000_000 }
            else if isSlow(t) { o = .remote() }
            else { o = StreamOptions(); o.maxSize = 0; o.videoBitRate = 16_000_000 }
        }
        o.videoCodec = MirrorSettings.codec
        if q != "data" {
            let fps = MirrorSettings.maxFps
            // Native rate (0 = no cap). A 60 cap on a 120 Hz phone makes MediaCodec drop frames
            // unevenly (16/25/33 ms gaps); uncapped, the phone's own cadence is perfectly even.
            o.maxFps = fps > 0 ? fps : (isSlow(t) ? 60 : 0)
        }
        // Every address this phone is known at (its other transports and learned endpoints):
        // the direct media connection races them and keeps the first that answers.
        o.directHosts = directHosts(for: t)
        // Over USB, adb's own transport is the fast path (no Wi-Fi in the loop): never race the
        // phone's network addresses there.
        if t.kind == .usb { o.transport = MirrorSettings.usbTransport == "direct" ? .auto : .adb; if o.transport == .adb { o.directHosts = [] } }
        // Qualcomm encoders have a low-latency mode (~8 ms less touch-to-photon in our tests).
        if devices.isQualcomm(t.serial) { o.videoCodecOptions += ",vendor.qti-ext-enc-low-latency.enable:int=1" }
        o.audio = MirrorSettings.audio
        o.clipboardAutosync = MirrorSettings.clipboardSync
        o.stayAwake = MirrorSettings.stayAwake
        o.showTouches = MirrorSettings.showTouches
        // Development: mirror a virtual display instead of the phone's screen (performance tests).
        if let vd = UserDefaults.standard.string(forKey: "debugVirtualDisplay"), !vd.isEmpty { o.newDisplay = vd }
        return o
    }

    private func directHosts(for t: Transport) -> [String] {
        func host(_ ep: String) -> String? {
            guard let c = ep.lastIndex(of: ":"), !ep.contains("._adb") else { return nil }
            let h = String(ep[..<c]); return h.isEmpty ? nil : h
        }
        var hosts: [String] = []
        let d = device
        for tr in d?.transports ?? [] { if let h = host(tr.serial), !hosts.contains(h) { hosts.append(h) } }
        if let id = d?.id, let k = devices.known.first(where: { $0.id == id }) {
            for ep in k.endpoints { if let h = host(ep), !hosts.contains(h) { hosts.append(h) } }
        }
        return hosts
    }

    private func isSlow(_ t: Transport) -> Bool {
        if t.kind == .remote { return true }
        if let rtt = t.rttMs { return rtt > 45 }
        return t.kind == .tailscale
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
            var firstFrame = true
            s.onFrame = { [weak self] f in
                guard let self else { return }
                self.frames.update(f.buffer)
                self.displaySink?(f)
                if firstFrame {
                    firstFrame = false
                    // Only a decoded frame proves the path works: reset the backoff here.
                    DispatchQueue.main.async {
                        guard gen == self.generation else { return }
                        self.reconnectAttempt = 0
                        self.startFailures[t.serial] = nil
                    }
                }
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
                    self.startFailures[t.serial] = Date()
                    self.devices.reportFailure(serial: t.serial)
                    self.scheduleReconnect(after: "\(error)", failedSerial: t.serial)
                }
                return
            }
            DispatchQueue.main.async {
                if gen == self.generation { self.startInFlight = false }
                guard gen == self.generation else { s.stop(); return }
                // The stream may already have died between start() returning and now.
                guard !s.isStopped else {
                    self.startFailures[t.serial] = Date()
                    self.scheduleReconnect(after: "stream closed during startup", failedSerial: t.serial)
                    return
                }
                self.session = s
                self.activeTransport = t
                self.state = .streaming
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
        let gen = generation
        reconnectGeneration = gen
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard gen == self.generation, self.wantedDeviceId == id else { return }
            self.reconnectGeneration = nil
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
        // A path that recently failed to carry a stream is on cooldown, so we don't flap between paths.
        let eligible = d.transports.filter { t in
            t.isHealthy && t.rttMs != nil && (startFailures[t.serial].map { Date().timeIntervalSince($0) > 120 } ?? true)
        }.sorted { $0.kind != $1.kind ? $0.kind < $1.kind : ($0.rttMs ?? 999) < ($1.rttMs ?? 999) }
        guard MirrorSettings.autoSwitchPaths, let active = activeTransport, let best = eligible.first,
              best.serial != active.serial, best.kind < active.kind else {
            betterPathSince = nil
            return
        }
        if let since = betterPathSince {
            // A cable is unambiguous: switch to USB after 1 s; network paths must prove stable for 4 s.
            if Date().timeIntervalSince(since) > (best.kind == .usb ? 1 : 4) {
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
            clipboardRequestId += 1
            let requestId = clipboardRequestId
            pendingClipboardReply = { text in
                guard !done else { return }
                done = true
                completion(text)
            }
            s.send(ControlMessage.getClipboard(copyKey: copyKey))
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard !done else { return }
                done = true
                if self.clipboardRequestId == requestId { self.pendingClipboardReply = nil }
                completion(nil)
            }
        }
    }

}

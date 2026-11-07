import Combine
import Foundation

/// One adb transport to a phone (a phone can have several at once: USB + Wi-Fi + Tailscale).
public struct Transport: Identifiable, Hashable, Sendable {
    public var id: String { serial }
    public var serial: String
    public var kind: TransportKind
    public var state: String
    public var rttMs: Double?
    public var lastProbe: Date?
    public var failures: Int = 0

    public var isOnline: Bool { state == "device" }
    public var isHealthy: Bool { isOnline && failures < 2 }

    public var label: String {
        var s = kind.label
        if let rttMs { s += String(format: " · %.0f ms", rttMs) }
        return s
    }
}

/// A physical phone, identified by ro.serialno, with all its transports.
public struct PhoneDevice: Identifiable, Hashable, Sendable {
    public var id: String               // hardware serial (ro.serialno)
    public var name: String             // user-visible device name
    public var model: String
    public var manufacturer: String
    public var androidVersion: String
    public var transports: [Transport]

    /// Best usable transport: by kind preference, then latency.
    public var bestTransport: Transport? {
        transports.filter(\.isHealthy).sorted { a, b in
            if a.kind != b.kind { return a.kind < b.kind }
            return (a.rttMs ?? 999) < (b.rttMs ?? 999)
        }.first
    }

    public var isOnline: Bool { transports.contains(where: \.isOnline) }
}

/// Persisted knowledge about a phone: every network endpoint we have ever reached it on.
public struct KnownDevice: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var model: String
    public var endpoints: [String]       // host:port
    public var lastConnected: Date?
}

public final class DeviceManager: ObservableObject, @unchecked Sendable {
    @Published public private(set) var devices: [PhoneDevice] = []
    /// Transports that are connected but not usable yet (unauthorized / offline / connecting).
    @Published public private(set) var pending: [ADBDeviceEntry] = []
    @Published public private(set) var serverError: String?
    @Published public private(set) var known: [KnownDevice] = []
    @Published public private(set) var pairingServices: [MDNSService] = []

    public let adb: ADBClient
    private let queue = DispatchQueue(label: "device-manager", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var identities: [String: (id: String, name: String, model: String, manufacturer: String, android: String)] = [:]
    private var rtt: [String: (Double?, Date, Int)] = [:]
    private var lastEntries: [ADBDeviceEntry] = []
    private var lastReconnectAttempt: [String: Date] = [:]
    private var learnedEndpointsFor: Set<String> = []
    private var tick = 0
    private let knownLock = NSLock()
    private var knownCache: [KnownDevice] = []
    /// Ids for which latency of all transports should be probed frequently (the active phone).
    public var focusDeviceId: String?

    /// Keep every known endpoint connected (hot standby). On by default only for a local
    /// adb server, so we never add transports to a shared/remote server.
    public var keepStandbyLinks: Bool {
        get { UserDefaults.standard.object(forKey: "keepStandbyLinks") as? Bool ?? adb.isLocalServer }
        set { UserDefaults.standard.set(newValue, forKey: "keepStandbyLinks") }
    }

    public init(adb: ADBClient = .shared) {
        self.adb = adb
        loadKnown()
    }

    public func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.5)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    public func stop() { timer?.cancel(); timer = nil }

    public func refreshNow() { queue.async { self.poll() } }

    // MARK: Polling

    private func poll() {
        tick += 1
        let entries: [ADBDeviceEntry]
        do {
            entries = try adb.devices()
            if serverError != nil { DispatchQueue.main.async { self.serverError = nil } }
        } catch {
            let msg = "\(error)"
            DispatchQueue.main.async { self.serverError = msg }
            return
        }

        // Resolve identities for new online serials.
        for e in entries where e.isOnline && identities[e.serial] == nil {
            resolveIdentity(e)
        }
        // Forget identities for transports that vanished.
        let present = Set(entries.map(\.serial))
        identities = identities.filter { present.contains($0.key) }

        // Probe latency: every transport of the focused phone every ~3 s, others every ~15 s.
        for e in entries where e.isOnline {
            let isFocus = identities[e.serial]?.id == focusDeviceId
            let interval: TimeInterval = isFocus ? 3 : 15
            if let last = rtt[e.serial], Date().timeIntervalSince(last.1) < interval { continue }
            let serial = e.serial
            let prevFailures = rtt[serial]?.2 ?? 0
            rtt[serial] = (rtt[serial]?.0, Date(), prevFailures)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let r = self.adb.ping(serial: serial, timeout: 3)
                self.queue.async {
                    let f = r == nil ? prevFailures + 1 : 0
                    self.rtt[serial] = (r.map { $0 * 1000 } ?? self.rtt[serial]?.0, Date(), f)
                    self.publish(self.lastEntries)
                }
            }
        }

        lastEntries = entries
        publish(entries)

        if keepStandbyLinks && tick % 4 == 0 { reconnectStandbyLinks(entries) }
        if tick % 3 == 0 { refreshPairingServices() }
    }

    private func publish(_ entries: [ADBDeviceEntry]) {
        var groups: [String: PhoneDevice] = [:]
        var pend: [ADBDeviceEntry] = []
        for e in entries {
            guard e.isOnline, let ident = identities[e.serial] else {
                if !e.isOnline { pend.append(e) }
                continue
            }
            let r = rtt[e.serial]
            let t = Transport(serial: e.serial, kind: e.kind, state: e.state, rttMs: r?.0, lastProbe: r?.1, failures: r?.2 ?? 0)
            if groups[ident.id] == nil {
                groups[ident.id] = PhoneDevice(id: ident.id, name: ident.name, model: ident.model,
                                               manufacturer: ident.manufacturer, androidVersion: ident.android, transports: [])
            }
            groups[ident.id]!.transports.append(t)
        }
        let list = groups.values.map { d -> PhoneDevice in
            var d = d
            d.transports.sort { $0.kind < $1.kind }
            return d
        }.sorted { $0.name < $1.name }
        DispatchQueue.main.async {
            if self.devices != list { self.devices = list }
            if self.pending != pend { self.pending = pend }
        }
    }

    private func resolveIdentity(_ e: ADBDeviceEntry) {
        let script = "getprop ro.serialno; getprop ro.product.model; getprop ro.product.manufacturer; getprop ro.build.version.release; settings get global device_name"
        guard let out = try? adb.shell(serial: e.serial, script, timeout: 6) else { return }
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.count >= 4 else { return }
        var id = lines[0]
        if id.isEmpty || id == "unknown" { id = e.serial }
        let model = lines[1].isEmpty ? (e.model ?? "Android") : lines[1]
        var name = lines.count > 4 ? lines[4] : ""
        if name.isEmpty || name == "null" { name = model }
        identities[e.serial] = (id, name, model, lines[2].capitalized, lines[3])
        learnEndpoints(serial: e.serial, deviceId: id, name: name, model: model)
    }

    // MARK: Endpoint learning & standby links

    private func learnEndpoints(serial: String, deviceId: String, name: String, model: String) {
        var endpoints: [String] = []
        let kind = TransportKind.infer(serial: serial, usb: nil)
        if kind == .lan || kind == .tailscale { endpoints.append(serial) }
        if !learnedEndpointsFor.contains(deviceId) {
            learnedEndpointsFor.insert(deviceId)
            let q = DeviceQueries(adb: adb, serial: serial)
            let tcpPort = (adb.getprop(serial: serial, "service.adb.tcp.port") ?? adb.getprop(serial: serial, "persist.adb.tcp.port"))
                .flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
            if let port = tcpPort {
                if let wlan = q.ipv4(interface: "wlan0") { endpoints.append("\(wlan):\(port)") }
                if let ts = q.tailscaleIP() { endpoints.append("\(ts):\(port)") }
            }
        }
        updateKnown(id: deviceId, name: name, model: model, endpoints: endpoints)
    }

    private func updateKnown(id: String, name: String, model: String, endpoints: [String]) {
        DispatchQueue.main.async {
            var k = self.known
            if let i = k.firstIndex(where: { $0.id == id }) {
                k[i].endpoints = k[i].endpoints.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                k[i].name = name
                k[i].model = model
                for ep in endpoints where !k[i].endpoints.contains(ep) { k[i].endpoints.append(ep) }
            } else {
                var unique: [String] = []
                for ep in endpoints where !unique.contains(ep) { unique.append(ep) }
                k.append(KnownDevice(id: id, name: name, model: model, endpoints: unique, lastConnected: nil))
            }
            if k != self.known {
                self.known = k
                self.saveKnown()
            }
        }
    }

    public func markConnected(_ id: String) {
        DispatchQueue.main.async {
            if let i = self.known.firstIndex(where: { $0.id == id }) {
                self.known[i].lastConnected = Date()
                self.saveKnown()
            }
        }
    }

    public func forget(_ id: String) {
        DispatchQueue.main.async {
            self.known.removeAll { $0.id == id }
            self.saveKnown()
        }
    }

    public func addEndpoint(_ endpoint: String) {
        queue.async { _ = try? self.adb.connect(endpoint) }
    }

    private func reconnectStandbyLinks(_ entries: [ADBDeviceEntry]) {
        let online = Set(entries.filter(\.isOnline).map(\.serial))
        knownLock.lock(); let known = knownCache; knownLock.unlock()
        for dev in known {
            for ep in dev.endpoints where !online.contains(ep) {
                if let last = lastReconnectAttempt[ep], Date().timeIntervalSince(last) < 20 { continue }
                lastReconnectAttempt[ep] = Date()
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    guard let self else { return }
                    // Quick TCP pre-check so an unreachable path doesn't block the adb server for 10 s.
                    let parts = ep.split(separator: ":")
                    guard parts.count == 2, let port = UInt16(parts[1]),
                          (try? TCPSocket.connect(host: String(parts[0]), port: port, timeout: 1.5)) != nil else { return }
                    if let msg = try? self.adb.connect(ep) { Log.info("standby link \(ep): \(msg)") }
                }
            }
        }
    }

    // MARK: Pairing discovery

    private func refreshPairingServices() {
        guard adb.isLocalServer else { return }
        let services = (try? adb.hostQuery("host:mdns:services", timeout: 3)).map(MDNSService.parse) ?? []
        DispatchQueue.main.async {
            if self.pairingServices != services { self.pairingServices = services }
        }
    }

    // MARK: Persistence

    private var knownURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AndroidMirroring", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("devices.json")
    }

    private func loadKnown() {
        if let data = try? Data(contentsOf: knownURL), let k = try? JSONDecoder().decode([KnownDevice].self, from: data) {
            known = k
            knownCache = k
        }
    }

    private func saveKnown() {
        knownLock.lock(); knownCache = known; knownLock.unlock()
        if let data = try? JSONEncoder().encode(known) { try? data.write(to: knownURL, options: .atomic) }
    }

    // MARK: Helpers

    public func device(id: String) -> PhoneDevice? { devices.first { $0.id == id } }

    /// Fresh latency probe of every online transport of a device (blocking; call off main).
    public func probeAll(_ device: PhoneDevice) -> [String: Double] {
        var out: [String: Double] = [:]
        let lock = NSLock()
        let group = DispatchGroup()
        for t in device.transports where t.isOnline {
            group.enter()
            DispatchQueue.global().async {
                if let r = self.adb.ping(serial: t.serial, timeout: 2.5) {
                    lock.lock(); out[t.serial] = r * 1000; lock.unlock()
                }
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + 3)
        queue.async {
            for (s, v) in out { self.rtt[s] = (v, Date(), 0) }
            self.publish(self.lastEntries)
        }
        return out
    }

    /// Mark a transport as failing (used by the session when its stream dies).
    public func reportFailure(serial: String) {
        queue.async {
            let r = self.rtt[serial]
            self.rtt[serial] = (r?.0, Date(), (r?.2 ?? 0) + 2)
            self.publish(self.lastEntries)
        }
    }
}

/// An entry from `adb mdns services`.
public struct MDNSService: Hashable, Sendable {
    public var name: String
    public var type: String     // _adb-tls-pairing._tcp / _adb-tls-connect._tcp / _adb._tcp
    public var address: String  // ip:port

    public var isPairing: Bool { type.contains("pairing") }

    static func parse(_ text: String) -> [MDNSService] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            guard parts.count >= 3 else { return nil }
            return MDNSService(name: parts[0], type: parts[1].trimmingCharacters(in: CharacterSet(charactersIn: ".")), address: parts[2])
        }
    }
}

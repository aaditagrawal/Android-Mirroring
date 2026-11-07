import AppKit
import CoreImage.CIFilterBuiltins
import MirrorKit
import SwiftUI

// MARK: - Bonjour discovery of pairing services (works even if adb's own mDNS is off)

final class BonjourBrowser: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    struct Found: Hashable, Identifiable { var id: String { name }; let name: String; let address: String }
    @Published var services: [Found] = []
    private let browser = NetServiceBrowser()
    private var resolving: [NetService] = []
    private let type: String

    init(type: String = "_adb-tls-pairing._tcp.") {
        self.type = type
        super.init()
        browser.delegate = self
    }

    func start() { browser.searchForServices(ofType: type, inDomain: "local.") }
    func stop() { browser.stop(); resolving.removeAll() }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolving.append(service)
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0.name == service.name }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let addrs = sender.addresses else { return }
        for data in addrs {
            let ip: String? = data.withUnsafeBytes { raw in
                guard let sa = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self), sa.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
                var sin = raw.load(as: sockaddr_in.self)
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
                return String(cString: buf)
            }
            if let ip {
                let f = Found(name: sender.name, address: "\(ip):\(sender.port)")
                if !services.contains(f) { services.append(f) }
                break
            }
        }
    }
}

// MARK: - Pairing model

final class PairingModel: ObservableObject {
    enum Status: Equatable { case idle, waiting, pairing, success(String), failure(String) }
    @Published var status: Status = .idle
    @Published var qrName = "AndroidMirroring-" + PairingModel.random(6)
    @Published var qrPassword = PairingModel.random(10)
    @Published var code = ""
    @Published var manualPairAddress = ""
    @Published var connectAddress = ""
    @Published var tailscalePeers: [TailscalePeers.Peer] = []
    let bonjour = BonjourBrowser()
    let devices: DeviceManager
    private var qrTimer: Timer?

    init(devices: DeviceManager) {
        self.devices = devices
        bonjour.start()
        DispatchQueue.global().async {
            let peers = TailscalePeers.android()
            DispatchQueue.main.async { self.tailscalePeers = peers }
        }
    }

    deinit { bonjour.stop(); qrTimer?.invalidate() }

    static func random(_ n: Int) -> String {
        let chars = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<n).map { _ in chars.randomElement()! })
    }

    var qrPayload: String { "WIFI:T:ADB;S:\(qrName);P:\(qrPassword);;" }

    /// All pairing services currently visible (from adb's mDNS and from Bonjour).
    var pairingServices: [(name: String, address: String)] {
        var out: [(String, String)] = devices.pairingServices.filter(\.isPairing).map { ($0.name, $0.address) }
        for s in bonjour.services where !out.contains(where: { $0.1 == s.address }) { out.append((s.name, s.address)) }
        return out
    }

    func startQR() {
        status = .waiting
        qrTimer?.invalidate()
        qrTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            guard let self, self.status == .waiting else { return }
            if let svc = self.pairingServices.first(where: { $0.name == self.qrName }) {
                self.pair(address: svc.address, code: self.qrPassword)
            }
        }
    }

    func regenerateQR() {
        qrName = "AndroidMirroring-" + PairingModel.random(6)
        qrPassword = PairingModel.random(10)
        startQR()
    }

    func pair(address: String, code: String) {
        status = .pairing
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let msg = try ADBTool.pair(address: address, code: code)
                // Pairing done; the phone now advertises _adb-tls-connect. Connect explicitly
                // in case the adb server's auto-connect is disabled.
                let host = address.split(separator: ":").first.map(String.init) ?? ""
                for _ in 0..<20 {
                    Thread.sleep(forTimeInterval: 0.5)
                    let connectSvc = (try? self.devices.adb.hostQuery("host:mdns:services", timeout: 2))
                        .map { $0.split(separator: "\n").filter { $0.contains("_adb-tls-connect") && $0.contains(host) } } ?? []
                    if let line = connectSvc.first, let addr = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).last {
                        _ = try? self.devices.adb.connect(String(addr))
                        break
                    }
                    if (try? self.devices.adb.devices())?.contains(where: { $0.serial.contains(host) && $0.isOnline }) == true { break }
                }
                self.devices.refreshNow()
                DispatchQueue.main.async { self.status = .success(msg) }
            } catch {
                DispatchQueue.main.async { self.status = .failure("\(error)") }
            }
        }
    }

    func connect(_ address: String) {
        var addr = address.trimmingCharacters(in: .whitespaces)
        if !addr.contains(":") { addr += ":5555" }
        status = .pairing
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let msg = try self.devices.adb.connect(addr)
                self.devices.refreshNow()
                DispatchQueue.main.async { self.status = .success(msg) }
            } catch {
                DispatchQueue.main.async { self.status = .failure("\(error)") }
            }
        }
    }
}

// MARK: - Views

struct DevicesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var devices: DeviceManager
    @ObservedObject var controller: MirrorController
    @StateObject private var pairing: PairingModel
    @StateObject private var tab = Box(0)

    init(model: AppModel) {
        self.model = model
        self.devices = model.devices
        self.controller = model.controller
        _pairing = StateObject(wrappedValue: PairingModel(devices: model.devices))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let err = devices.serverError {
                        Label(err, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                    }
                    phonesSection
                    if !devices.pending.isEmpty { pendingSection }
                    addSection
                }
                .padding(20)
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 680)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Android Mirroring").font(.title2.weight(.semibold))
                Text("Use your Android phone from your Mac — over Wi-Fi, USB or Tailscale.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // Phones

    private var phonesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Phones").font(.headline)
            if devices.devices.isEmpty {
                Text("No phones connected yet. Pair one below.")
                    .foregroundStyle(.secondary).font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
            ForEach(devices.devices) { d in phoneRow(d) }
        }
    }

    private func phoneRow(_ d: PhoneDevice) -> some View {
        let active = controller.device?.id == d.id && controller.state.isActive
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: "smartphone").font(.system(size: 26, weight: .light)).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(d.name).font(.body.weight(.semibold))
                    if active { Text("Mirroring").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2).background(.green.opacity(0.2), in: Capsule()) }
                }
                Text("\(d.manufacturer) \(d.model) · Android \(d.androidVersion)").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(d.transports) { t in
                        HStack(spacing: 3) {
                            Image(systemName: t.kind.symbol)
                            Text(t.rttMs.map { "\(t.kind.label) \(Int($0)) ms" } ?? t.kind.label)
                        }
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((t.serial == controller.activeTransport?.serial ? Color.accentColor : Color.secondary).opacity(0.15), in: Capsule())
                        .help(t.serial)
                    }
                }
            }
            Spacer()
            if active {
                Button("Show") { model.windowController?.showMirror() }
            } else {
                Button("Mirror") { model.connect(d.id) }.buttonStyle(.borderedProminent)
            }
            Menu {
                Button("Enable Network ADB on Port 5555") { enableTCP(d) }
                Button("Forget Phone") { devices.forget(d.id) }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func enableTCP(_ d: PhoneDevice) {
        guard let serial = d.bestTransport?.serial else { return }
        DispatchQueue.global().async {
            // Restarts adbd listening on tcp:5555 (persists until reboot); then connect over Wi-Fi.
            let sock = try? devices.adb.openStream(serial: serial, service: "tcpip:5555")
            _ = try? sock?.readToEnd()
            Thread.sleep(forTimeInterval: 2)
            if let ip = DeviceQueries(adb: devices.adb, serial: serial).ipv4(interface: "wlan0") {
                _ = try? devices.adb.connect("\(ip):5555")
            }
            devices.refreshNow()
        }
    }

    // Pending (unauthorized etc.)

    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Waiting").font(.headline)
            ForEach(devices.pending, id: \.serial) { e in
                HStack(spacing: 10) {
                    Image(systemName: e.state == "unauthorized" ? "lock.shield" : "hourglass")
                        .font(.title3).foregroundStyle(.orange).frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.serial).font(.callout.weight(.medium))
                        Text(e.state == "unauthorized"
                             ? "Unlock your phone and tap “Allow” on the debugging prompt (check “Always allow from this computer”)."
                             : "State: \(e.state)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if e.kind != .usb {
                        Button("Retry") { pairing.connect(e.serial) }
                    }
                }
                .padding(12)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // Add a phone

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add a Phone").font(.headline)
            Picker("", selection: $tab.value) {
                Text("QR Code").tag(0)
                Text("Pairing Code").tag(1)
                Text("IP Address").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch tab.value {
                case 0: qrPane
                case 1: codePane
                default: addressPane
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            statusLine
        }
    }

    private var qrPane: some View {
        HStack(alignment: .top, spacing: 18) {
            QRCodeView(text: pairing.qrPayload)
                .frame(width: 170, height: 170)
                .padding(8)
                .background(.white, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 8) {
                step(1, "On your phone, open Settings › Developer options › Wireless debugging.")
                step(2, "Tap “Pair device with QR code”.")
                step(3, "Scan this code. Your Mac and phone must be on the same Wi-Fi network.")
                HStack {
                    Button("New Code") { pairing.regenerateQR() }
                    if pairing.status == .waiting { ProgressView().controlSize(.small); Text("Waiting for phone…").font(.caption).foregroundStyle(.secondary) }
                }
                .padding(.top, 4)
            }
        }
        .onAppear { pairing.startQR() }
    }

    private var codePane: some View {
        VStack(alignment: .leading, spacing: 10) {
            step(1, "On your phone: Wireless debugging › “Pair device with pairing code”.")
            step(2, "Enter the 6-digit code shown on the phone.")
            let services = pairing.pairingServices
            if services.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Looking for phones in pairing mode…").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ForEach(services, id: \.address) { s in
                    Label("\(s.name)  \(s.address)", systemImage: "dot.radiowaves.left.and.right").font(.caption)
                }
            }
            HStack {
                TextField("Pairing code", text: $pairing.code).textFieldStyle(.roundedBorder).frame(width: 130)
                TextField("IP:port (optional, auto-detected)", text: $pairing.manualPairAddress).textFieldStyle(.roundedBorder)
                Button("Pair") {
                    let addr = pairing.manualPairAddress.isEmpty ? services.first?.address : pairing.manualPairAddress
                    if let addr { pairing.pair(address: addr, code: pairing.code) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(pairing.code.count < 6 || (services.isEmpty && pairing.manualPairAddress.isEmpty))
            }
        }
    }

    private var addressPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect to a phone that already trusts this Mac — on Wi-Fi, or anywhere via Tailscale (adb tcpip 5555 or a Wireless debugging port).")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("192.168.1.20:5555 or 100.x.y.z:5555", text: $pairing.connectAddress)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { pairing.connect(pairing.connectAddress) }
                Button("Connect") { pairing.connect(pairing.connectAddress) }
                    .buttonStyle(.borderedProminent)
                    .disabled(pairing.connectAddress.isEmpty)
            }
            if !pairing.tailscalePeers.isEmpty {
                Text("Android devices on your tailnet").font(.caption.weight(.semibold)).padding(.top, 4)
                ForEach(pairing.tailscalePeers, id: \.ip) { p in
                    HStack {
                        Image(systemName: "network")
                        Text(p.name).font(.callout)
                        Text(p.ip).font(.caption.monospaced()).foregroundStyle(.secondary)
                        if !p.online { Text("offline").font(.caption2).foregroundStyle(.orange) }
                        Spacer()
                        Button("Connect") { pairing.connect("\(p.ip):5555") }.controlSize(.small)
                    }
                }
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch pairing.status {
        case .pairing:
            HStack { ProgressView().controlSize(.small); Text("Connecting…").font(.callout) }
        case .success(let msg):
            Label(msg.isEmpty ? "Done" : msg, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
        case .failure(let msg):
            Label(msg, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout).textSelection(.enabled)
        default:
            EmptyView()
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.caption.weight(.bold)).frame(width: 18, height: 18).background(.tint.opacity(0.2), in: Circle())
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct QRCodeView: View {
    let text: String
    var body: some View {
        if let img = QRCodeView.make(text) {
            Image(nsImage: img).interpolation(.none).resizable().scaledToFit()
        } else {
            Color.gray
        }
    }

    static func make(_ text: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

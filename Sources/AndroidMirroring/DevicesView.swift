import AppKit
import Combine
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
    func stop() {
        browser.stop()
        resolving.forEach { $0.stop() }
        resolving.removeAll()
        services.removeAll()
    }

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
    enum Status: Equatable { case idle, waiting, working(String), paired, connected, failure(String) }
    @Published var status: Status = .idle
    @Published var qrName = "AndroidMirroring-" + PairingModel.random(6)
    @Published var qrPassword = PairingModel.random(10)
    @Published var code = ""
    @Published var manualPairAddress = ""
    @Published var selectedPairAddress: String?
    @Published var connectAddress = ""
    @Published var tailscalePeers: [TailscalePeers.Peer] = []
    let bonjour = BonjourBrowser()
    let devices: DeviceManager
    private var qrTimer: Timer?
    private var discovery: AnyCancellable?

    init(devices: DeviceManager) {
        self.devices = devices
        discovery = bonjour.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    deinit { bonjour.stop(); qrTimer?.invalidate() }

    static func random(_ n: Int) -> String {
        let chars = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<n).map { _ in chars.randomElement()! })
    }

    var qrPayload: String { "WIFI:T:ADB;S:\(qrName);P:\(qrPassword);;" }

    var busy: Bool { if case .working = status { return true }; return false }

    var pairAddress: String? {
        let manual = manualPairAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty { return manual }
        let services = pairingServices
        if services.count == 1 { return services[0].address }
        return services.first { $0.address == selectedPairAddress }?.address
    }

    var validCode: Bool { code.utf8.count == 6 && code.utf8.allSatisfy { (48...57).contains($0) } }

    func discoverPhones() { bonjour.start() }

    func discoverTailscale() {
        DispatchQueue.global().async {
            let peers = TailscalePeers.android()
            DispatchQueue.main.async { self.tailscalePeers = peers }
        }
    }

    /// All pairing services currently visible (from adb's mDNS and from Bonjour).
    var pairingServices: [(name: String, address: String)] {
        var out: [(String, String)] = devices.pairingServices.filter(\.isPairing).map { ($0.name, $0.address) }
        for s in bonjour.services where !out.contains(where: { $0.1 == s.address }) { out.append((s.name, s.address)) }
        return out
    }

    func startQR() {
        guard !busy else { return }
        status = .waiting
        qrTimer?.invalidate()
        let deadline = Date().addingTimeInterval(60)
        qrTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            guard let self, self.status == .waiting else { return }
            if let svc = self.pairingServices.first(where: { $0.name == self.qrName }) {
                self.pair(address: svc.address, code: self.qrPassword)
            } else if Date() >= deadline {
                self.stopQR()
                self.status = .failure("No scan detected. Check that both devices are on the same Wi-Fi and that Android Mirroring has Local Network access in Mac System Settings. Then try a new code.")
            }
        }
    }

    func stopQR() {
        qrTimer?.invalidate()
        qrTimer = nil
        if status == .waiting { status = .idle }
    }

    func regenerateQR() {
        qrName = "AndroidMirroring-" + PairingModel.random(6)
        qrPassword = PairingModel.random(10)
        startQR()
    }

    func pair(address: String, code: String) {
        guard !busy else { return }
        stopQR()
        status = .working("Pairing with your phone…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try ADBTool.pair(address: address, code: code)
                DispatchQueue.main.async { self.status = .working("Paired. Looking for the connection address…") }
                // Pairing proves trust, not that the phone has an online transport.
                let host = address.split(separator: ":").first.map(String.init) ?? ""
                for _ in 0..<8 {
                    let services = (try? self.devices.adb.hostQuery("host:mdns:services", timeout: 1)).map(MDNSService.parse) ?? []
                    let matches = services.filter { $0.type == "_adb-tls-connect._tcp" && $0.address.split(separator: ":").first == host[...] }
                    let serials = Set(matches.flatMap { [$0.name + "._adb-tls-connect._tcp", $0.address] })
                    if (try? self.devices.adb.devices())?.contains(where: { serials.contains($0.serial) && $0.isOnline }) == true {
                        break
                    }
                    if matches.count == 1, let service = matches.first, (try? self.devices.adb.connect(service.address)) != nil { break }
                    Thread.sleep(forTimeInterval: 0.5)
                }
                self.devices.refreshNow()
                DispatchQueue.main.async { self.status = .paired }
            } catch {
                DispatchQueue.main.async { self.status = .failure("Couldn't pair. Keep the pairing screen open on your phone, get a fresh code, and try again.") }
            }
        }
    }

    func connect(_ address: String) {
        guard !busy else { return }
        var addr = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addr.isEmpty else { return }
        if !addr.contains(":") { addr += ":5555" }
        stopQR()
        status = .working("Connecting to your phone…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try self.devices.adb.connect(addr)
                self.devices.refreshNow()
                DispatchQueue.main.async { self.status = .connected }
            } catch {
                DispatchQueue.main.async { self.status = .failure("Couldn't connect. Use the IP address and port on the main Wireless debugging screen, not the pairing screen.") }
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
    private enum Setup: String, CaseIterable { case usb = "USB", wifi = "Wi-Fi", advanced = "Advanced" }
    @State private var setup = Setup.usb
    @State private var showSetup = false
    @State private var useCode = false
    @State private var forgetID: String?

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
                    if let error = devices.serverError {
                        setupError(error)
                    }
                    if !devices.devices.isEmpty || !devices.known.isEmpty { phonesSection }
                    if !devices.pending.isEmpty { pendingSection }
                    if (devices.devices.isEmpty && devices.known.isEmpty) || showSetup {
                        addSection
                    } else {
                        Button("Add a Phone…", systemImage: "plus") { showSetup = true }
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 680)
        .onChange(of: model.selectedPhoneID) { _, id in
            if id != nil { showSetup = false }
        }
        .confirmationDialog("Forget this phone?", isPresented: Binding(
            get: { forgetID != nil }, set: { if !$0 { forgetID = nil } }
        ), titleVisibility: .visible) {
            if let id = forgetID { Button("Forget Phone", role: .destructive) { model.forgetPhone(id); forgetID = nil } }
        } message: {
            Text("This removes saved connection details and favorites. To revoke debugging access, also remove this Mac in Android’s Developer options.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your Phones").font(.title2.weight(.semibold))
                Text("Open a phone again or connect one for the first time.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // Phones

    private func setupError(_ error: String) -> some View {
        let missingADB = devices.adb.isLocalServer && ADBTool.executablePath == nil
        return VStack(alignment: .leading, spacing: 8) {
            Label(missingADB ? "Android tools needed" : "Can’t reach the Android tools", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(missingADB ? "Install Android Platform Tools, then check again." : "Check that your ADB server is running. If you set a custom server in Settings, check its address.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                if missingADB {
                    Button("Copy Install Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("brew install --cask android-platform-tools", forType: .string)
                    }
                    Link("Install Guide", destination: URL(string: "https://github.com/aaditagrawal/Android-Mirroring#download-the-app")!)
                }
                Button("Check Again") { devices.refreshNow() }
            }
            DisclosureGroup("Technical details") { Text(error).textSelection(.enabled).font(.caption) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    private var phonesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            let offline = devices.known.filter { devices.device(id: $0.id) == nil }
            ForEach(devices.devices) { d in phoneRow(id: d.id, name: d.name, phone: d) }
            ForEach(offline, id: \.id) { d in phoneRow(id: d.id, name: d.name, phone: nil) }
        }
    }

    private func phoneRow(id: String, name: String, phone: PhoneDevice?) -> some View {
        let selected = model.selectedPhoneID == id
        let live = selected && controller.device?.id == id && controller.isStreaming && controller.hasVideo
        let needsPermission = phone == nil && devices.pending.contains { $0.serial == id && $0.state == "unauthorized" }
        let action = live ? "Show Phone" : phone == nil ? "Reconnect" : "Mirror"
        let label = live ? "Mirroring" : selected ? (phone == nil ? "Waiting for phone" : "Connecting") :
            needsPermission ? "Needs permission" : phone == nil ? "Offline" : "Ready to mirror"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "iphone").font(.system(size: 26, weight: .light)).frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.body.weight(.semibold))
                    let connection = live ? controller.activeTransport.map { " over \($0.kind.label)" } ?? "" : ""
                    Text(label + connection).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if selected && !live {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Button("Cancel") { model.disconnect() }.accessibilityLabel("Cancel connection to \(name)")
                } else {
                    Button(action) { model.connect(id) }
                        .buttonStyle(.bordered).accessibilityLabel("\(action) \(name)")
                }
                Menu {
                    if let phone { Button("Enable Network ADB on Port 5555") { enableTCP(phone) } }
                    Button("Forget Phone…") { forgetID = id }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Options for \(name)")
            }
            if selected && !live {
                Text(connectionHelp).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var connectionHelp: String {
        switch controller.state {
        case .connecting(let detail), .reconnecting(let detail), .failed(let detail): detail
        case .streaming: "Starting video…"
        case .idle: "Looking for your phone…"
        }
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
            Text("Connection Help").font(.headline)
            ForEach(devices.pending, id: \.serial) { e in
                HStack(spacing: 10) {
                    Image(systemName: e.state == "unauthorized" ? "lock.shield" : "hourglass")
                        .font(.title3).foregroundStyle(.orange).frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.state == "unauthorized" ? "Allow debugging on your phone" : "Phone isn’t ready yet")
                            .font(.callout.weight(.medium))
                        Text(e.state == "unauthorized"
                             ? "Unlock your phone and tap “Allow” on the debugging prompt (check “Always allow from this computer”)."
                             : "Check that your phone is unlocked and debugging is on.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Check Again") { devices.refreshNow() }
                }
                .padding(12)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // Add a phone

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect a Phone").font(.headline)
            Picker("Connection method", selection: Binding(get: { setup }, set: { method in
                pairing.status = .idle
                showSetup = true
                setup = method
            })) {
                ForEach(Setup.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(pairing.busy)

            Group {
                switch setup {
                case .usb: usbPane
                case .wifi: wifiPane
                case .advanced: addressPane.onAppear { pairing.discoverTailscale() }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            statusLine
        }
    }

    private var usbPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Connect with a USB cable", systemImage: "cable.connector").font(.headline)
            step(1, "On your phone, open Settings › Developer options and turn on USB debugging.")
            step(2, "Plug your unlocked phone into the Mac using a cable that supports data.")
            step(3, "If Android asks to allow USB debugging, tap Allow. Your phone will appear above.")
            developerOptions
        }
    }

    private var developerOptions: some View {
        DisclosureGroup("Don’t see Developer options?") {
            Text("Open Settings › About phone and tap Build number seven times. On some phones, Build number is under Software information. Then return to Settings and search for Developer options.")
                .font(.callout).foregroundStyle(.secondary).padding(.top, 3)
        }
        .font(.callout)
    }

    private var wifiPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Connect over Wi-Fi", systemImage: "wifi").font(.headline)
            Text("On Android 11 or later, connect both devices to the same Wi-Fi. On your phone, open Developer options and turn on Wireless debugging.")
                .font(.callout)
            developerOptions
            if useCode { codePane } else { qrPane }
            Button(useCode ? "Use QR Code Instead" : "Use a Pairing Code Instead") {
                pairing.status = .idle
                useCode.toggle()
            }
            .disabled(pairing.busy)
        }
        .onAppear { pairing.discoverPhones() }
        .onDisappear { pairing.bonjour.stop() }
    }

    private var qrPane: some View {
        HStack(alignment: .top, spacing: 18) {
            QRCodeView(text: pairing.qrPayload)
                .frame(width: 170, height: 170)
                .padding(8)
                .background(.white, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("Wireless debugging pairing QR code")
            VStack(alignment: .leading, spacing: 8) {
                step(1, "On the Wireless debugging screen, tap “Pair device with QR code”.")
                step(2, "Scan this code using your phone.")
                HStack {
                    Button("New QR Code") { pairing.regenerateQR() }.disabled(pairing.busy)
                    if pairing.status == .waiting { ProgressView().controlSize(.small); Text("Waiting for phone…").font(.caption).foregroundStyle(.secondary) }
                }
                .padding(.top, 4)
            }
        }
        .onAppear { pairing.regenerateQR() }
        .onDisappear { pairing.stopQR() }
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
            } else if services.count > 1 {
                Picker("Pairing address", selection: $pairing.selectedPairAddress) {
                    Text("Choose the address on your phone").tag(String?.none)
                    ForEach(services, id: \.address) { s in Text(s.address).tag(Optional(s.address)) }
                }
            } else if let service = services.first {
                Label("Found pairing address: \(service.address)", systemImage: "dot.radiowaves.left.and.right").font(.caption)
            }
            HStack {
                TextField("Six-digit code", text: $pairing.code).textFieldStyle(.roundedBorder).frame(width: 130)
                TextField("Enter pairing address manually", text: $pairing.manualPairAddress).textFieldStyle(.roundedBorder)
                Button("Pair") {
                    if let addr = pairing.pairAddress { pairing.pair(address: addr, code: pairing.code) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!pairing.validCode || pairing.pairAddress == nil)
            }
        }
        .disabled(pairing.busy)
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
        .disabled(pairing.busy)
    }

    @ViewBuilder private var statusLine: some View {
        switch pairing.status {
        case .working(let detail):
            HStack { ProgressView().controlSize(.small); Text(detail).font(.callout) }
        case .paired:
            VStack(alignment: .leading, spacing: 6) {
                Label("Pairing complete", systemImage: "checkmark.circle").font(.headline)
                Text("When your phone is ready, it will appear above. If it doesn’t, enter the IP address and port from the main Wireless debugging screen.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Enter Connection Address…") { setup = .advanced }
            }
        case .connected:
            Text("Connection requested. Your phone will appear above when it’s ready to mirror.").font(.callout)
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

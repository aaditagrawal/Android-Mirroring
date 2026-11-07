import AgentProtocol
import AppKit
import Combine
import MirrorKit
import SwiftUI
import UniformTypeIdentifiers

final class AppModel: ObservableObject {
    let devices: DeviceManager
    let controller: MirrorController
    let agent: AgentServer
    let notifications: NotificationBridge
    weak var windowController: MirrorWindowController?
    var showDevicesWindow: (() -> Void)?
    var showSettingsWindow: (() -> Void)?

    @Published var phoneScreenOff = false
    private var cancellables = Set<AnyCancellable>()
    private var autoConnectDone = false
    private var lastDeviceId: String? {
        get { UserDefaults.standard.string(forKey: "lastDeviceId") }
        set { UserDefaults.standard.set(newValue, forKey: "lastDeviceId") }
    }

    init() {
        devices = DeviceManager()
        controller = MirrorController(devices: devices)
        agent = AgentServer(controller: controller)
        notifications = NotificationBridge(controller: controller)

        agent.showWindow = { [weak self] visible in
            if visible { self?.windowController?.showMirror() } else { self?.windowController?.window?.orderOut(nil) }
        }
        agent.windowVisible = { [weak self] in
            DispatchQueue.main.sync { self?.windowController?.window?.isVisible ?? false }
        }
        agent.pinProvider = { Keychain.pin }
        agent.windowSnapshot = { which in
            DispatchQueue.main.sync {
                if which == "phones" { self.showDevicesWindow?() }
                if which == "settings" { self.showSettingsWindow?() }
                RunLoop.current.run(until: Date().addingTimeInterval(0.6))
                let w: NSWindow? = which == "mirror" ? self.windowController?.window
                    : NSApp.windows.first { $0.title.lowercased().contains(which.lowercased()) && $0.isVisible }
                guard let w else { return nil }
                return WindowCapture.png(windowID: CGWindowID(w.windowNumber))
            }
        }
        agent.connectHandler = { [weak self] in DispatchQueue.main.async { self?.autoConnect(force: true) } }

        devices.$devices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.autoConnect(force: false) }
            .store(in: &cancellables)
        controller.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in
                if case .streaming = s { self?.notifications.start() }
                if case .idle = s { self?.notifications.stop(); self?.phoneScreenOff = false }
            }
            .store(in: &cancellables)
    }

    func start() {
        devices.start()
        do { try agent.start() } catch { Log.error("agent server: \(error)") }
        // If nothing connects within a few seconds and we've never paired, show the device window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            if !self.controller.state.isActive && self.devices.devices.isEmpty { self.showDevices() }
        }
    }

    // MARK: Connection

    /// Connect to the last-used phone (or the only phone) as soon as it shows up.
    func autoConnect(force: Bool) {
        guard force || !autoConnectDone else { return }
        guard !controller.state.isActive || force else { return }
        if controller.state.isActive { return }
        let list = devices.devices
        guard !list.isEmpty else { return }
        let target = list.first(where: { $0.id == lastDeviceId }) ?? (list.count == 1 ? list[0] : nil)
        guard let target else { return }
        autoConnectDone = true
        connect(target.id)
    }

    func connect(_ id: String) {
        lastDeviceId = id
        controller.connect(deviceId: id)
        windowController?.showMirror()
    }

    func reconnect() {
        if let id = lastDeviceId ?? devices.devices.first?.id { connect(id) } else { showDevices() }
    }

    func disconnect() {
        if phoneScreenOff { controller.setDisplayPower(true) }
        controller.disconnect()
    }

    var canQuickConnect: Bool { !devices.devices.isEmpty }

    var idleHint: String {
        if let e = devices.serverError { return e }
        if devices.pending.contains(where: { $0.state == "unauthorized" }) {
            return "Your phone is asking for permission. Unlock it and tap “Allow” on the USB debugging prompt."
        }
        if devices.devices.isEmpty { return "Pair your phone using Wireless Debugging to get started." }
        return "\(devices.devices.first!.name) is available."
    }

    func showDevices() { showDevicesWindow?() }

    func windowClosed() {
        // Keep the session alive in the background for agents unless the user opted out.
        if !(UserDefaults.standard.object(forKey: "keepConnectedWhenClosed") as? Bool ?? true) {
            disconnect()
        }
    }

    // MARK: Actions

    func setPhoneScreenOff(_ off: Bool) {
        phoneScreenOff = off
        controller.setDisplayPower(!off)
    }

    func unlockPhone() {
        DispatchQueue.global().async { self.controller.unlock(pin: Keychain.pin) }
    }

    func saveScreenshot(ui: WindowUIState?) {
        guard let enc = controller.frames.encoded(format: .png, maxDimension: nil) else { return }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "Android Screenshot \(fmt.string(from: Date())).png"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let url = desktop.appendingPathComponent(name)
        do {
            try enc.data.write(to: url)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([NSImage(data: enc.data)].compactMap { $0 })
            ui?.show(toast: "Screenshot saved to Desktop and copied")
        } catch {
            ui?.show(toast: "Couldn't save screenshot")
        }
    }

    /// Dropped files: APKs are installed; everything else is copied to Downloads on the phone.
    func handleDrop(_ urls: [URL], ui: WindowUIState) {
        guard let serial = controller.serial else { ui.show(toast: "Connect a phone first"); return }
        DispatchQueue.global(qos: .userInitiated).async {
            for url in urls {
                let name = url.lastPathComponent
                if url.pathExtension.lowercased() == "apk" {
                    DispatchQueue.main.async { ui.progress = "Installing \(name)…" }
                    let result = try? ADBTool.run(["-s", serial, "install", "-r", url.path], timeout: 600)
                    let ok = result?.status == 0
                    DispatchQueue.main.async {
                        ui.progress = nil
                        ui.show(toast: ok ? "Installed \(name)" : "Install failed: \(result?.output.split(separator: "\n").last ?? "")")
                    }
                } else {
                    DispatchQueue.main.async { ui.progress = "Sending \(name)…" }
                    let remote = "/sdcard/Download/\(name)"
                    var ok = false
                    if let data = try? Data(contentsOf: url) {
                        ok = (try? self.controller.adb.push(serial: serial, data: data, remotePath: remote)) != nil
                        if ok { self.controller.send(ControlMessage.scanFile(remote)) }
                    }
                    DispatchQueue.main.async {
                        ui.progress = nil
                        ui.show(toast: ok ? "Saved to Downloads on phone" : "Couldn't send \(name)")
                    }
                }
            }
        }
    }

    // MARK: Agent setup helpers

    /// Path to the bundled droidctl binary.
    var droidctlPath: String {
        let inBundle = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/droidctl").path
        if FileManager.default.isExecutableFile(atPath: inBundle) { return inBundle }
        return URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("droidctl").path
    }

    var mcpConfigSnippet: String {
        """
        {
          "mcpServers": {
            "android": {
              "command": "\(droidctlPath)",
              "args": ["mcp"]
            }
          }
        }
        """
    }

    var claudeCodeCommand: String { "claude mcp add android -s user -- \"\(droidctlPath)\" mcp" }
}

/// Stores the optional phone PIN in the macOS Keychain (used by "Unlock").
enum Keychain {
    private static let service = "com.aaditagrawal.AndroidMirroring.pin"

    static var pin: String? {
        get {
            let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
            return String(data: d, encoding: .utf8)
        }
        set {
            let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service]
            SecItemDelete(base as CFDictionary)
            guard let v = newValue, !v.isEmpty else { return }
            var add = base
            add[kSecValueData] = Data(v.utf8)
            add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

/// Captures this app's own windows (no Screen Recording permission needed for own windows).
/// CGWindowListCreateImage is marked unavailable in the SDK but still exported; resolve it dynamically.
enum WindowCapture {
    private typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let fn: Fn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(sym, to: Fn.self)
    }()

    static func png(windowID: CGWindowID) -> Data? {
        // .optionIncludingWindow = 1 << 3, .boundsIgnoreFraming = 1 << 0, .bestResolution = 1 << 3
        guard let fn, let img = fn(.null, 1 << 3, windowID, (1 << 0) | (1 << 3))?.takeRetainedValue() else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }
}

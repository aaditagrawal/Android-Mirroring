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
    var showConnectedMirror: (() -> Void)?
    var showSettingsWindow: (() -> Void)?

    @Published var phoneScreenOff = false
    @Published private(set) var selectedPhoneID: String?
    private var cancellables = Set<AnyCancellable>()
    private var autoConnectDone = false
    private var openWhenReady = false
    private var pendingFavorite: FavoriteApp?
    private var requestedNotifications = false
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
                if which == "toolbar" { self.windowController?.ui.toolbarVisible = true }
                RunLoop.current.run(until: Date().addingTimeInterval(0.6))
                let w: NSWindow? = (which == "mirror" || which == "toolbar") ? self.windowController?.window
                    : NSApp.windows.first { $0.title.lowercased().contains(which.lowercased()) && $0.isVisible }
                guard let w else { return nil }
                return WindowCapture.png(windowID: CGWindowID(w.windowNumber))
            }
        }
        agent.presentStats = { [weak self] reset in
            guard let self else { return [:] }
            return DispatchQueue.main.sync {
                guard let r = self.windowController?.mirrorView.renderer else { return ["renderer": "sample-buffer layer"] }
                return r.report(reset: reset)
            }
        }
        agent.syntheticTest = { [weak self] p in
            guard let self else { return [:] }
            let r: VideoRenderer? = DispatchQueue.main.sync {
                self.windowController?.showMirror()
                return self.windowController?.mirrorView.renderer
            }
            guard let r else { return ["error": "no renderer"] }
            Thread.sleep(forTimeInterval: 0.5)
            return r.runSynthetic(seconds: (p["seconds"] as? Double) ?? 4, jitter: (p["jitter"] as? Bool) ?? true)
        }
        agent.connectHandler = { [weak self] in DispatchQueue.main.async { self?.autoConnect(force: true) } }

        devices.$devices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.autoConnect(force: false) }
            .store(in: &cancellables)
        controller.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in
                if case .idle = s { self?.notifications.stop(); self?.phoneScreenOff = false }
            }
            .store(in: &cancellables)
        controller.$state.combineLatest(controller.$hasVideo)
            .map { $0 == .streaming && $1 }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ready in
                guard let self, ready, self.controller.isStreaming, self.controller.hasVideo else { return }
                if NotificationBridge.enabled, !self.requestedNotifications {
                    self.requestedNotifications = true
                    self.notifications.requestAuthorization()
                }
                self.notifications.start()
                guard self.controller.device?.id == self.selectedPhoneID, self.openWhenReady else { return }
                self.openWhenReady = false
                self.showConnectedMirror?()
                self.windowController?.revealToolbarOnFirstConnect()
                if let app = self.pendingFavorite {
                    self.pendingFavorite = nil
                    self.launch(app)
                }
            }
            .store(in: &cancellables)
    }

    func start() {
        devices.start()
        do { try agent.start() } catch { Log.error("agent server: \(error)") }
    }

    // MARK: Connection

    /// Connect to the last-used phone (or the only phone) as soon as it shows up.
    func autoConnect(force: Bool) {
        guard force || !autoConnectDone else { return }
        guard !controller.state.isActive else { return }
        let list = devices.devices
        let target: PhoneDevice?
        if let id = lastDeviceId { target = devices.device(id: id) }
        else { target = list.count == 1 ? list.first : nil }
        guard let target else { return }
        connect(target.id)
    }

    func connect(_ id: String) {
        connect(id, opening: nil)
    }

    private func connect(_ id: String, opening app: FavoriteApp?) {
        autoConnectDone = true
        if selectedPhoneID == id, controller.device?.id == id, controller.isStreaming, controller.hasVideo {
            showConnectedMirror?()
            if let app { launch(app) }
            return
        }
        if selectedPhoneID != id, phoneScreenOff { setPhoneScreenOff(false) }
        let alreadyConnecting = selectedPhoneID == id && controller.state.isActive
        selectedPhoneID = id
        lastDeviceId = id
        pendingFavorite = app
        openWhenReady = true
        if !alreadyConnecting { controller.connect(deviceId: id) }
    }

    func reconnect() {
        if let phone = preferredPhone { connect(phone.id) } else { showDevices() }
    }

    func disconnect() {
        autoConnectDone = true
        openWhenReady = false
        pendingFavorite = nil
        selectedPhoneID = nil
        if phoneScreenOff { controller.setDisplayPower(true) }
        controller.disconnect()
    }

    var preferredPhone: (id: String, name: String)? {
        if let id = lastDeviceId {
            if let phone = devices.device(id: id) { return (id, phone.name) }
            if let phone = devices.known.first(where: { $0.id == id }) { return (id, phone.name) }
        }
        if devices.devices.count == 1, let phone = devices.devices.first { return (phone.id, phone.name) }
        if devices.devices.isEmpty, devices.known.count == 1, let phone = devices.known.first { return (phone.id, phone.name) }
        return nil
    }

    var selectedPhoneName: String {
        guard let id = selectedPhoneID else { return "your phone" }
        return devices.device(id: id)?.name ?? devices.known.first { $0.id == id }?.name ?? "your phone"
    }

    var idleHint: String {
        if devices.pending.contains(where: { $0.state == "unauthorized" }) {
            return "Your phone is asking for permission. Unlock it and tap “Allow” on the USB debugging prompt."
        }
        if devices.serverError != nil { return "Open Phones to check your connection setup." }
        return preferredPhone == nil ? "Choose a phone or connect one by USB or Wi-Fi." : "Ready when your phone is available."
    }

    func showDevices() { showDevicesWindow?() }

    func showShortcuts() {
        UserDefaults.standard.set("shortcuts", forKey: "settingsTab")
        showSettingsWindow?()
    }

    func forgetPhone(_ id: String) {
        if selectedPhoneID == id { disconnect() }
        if lastDeviceId == id { lastDeviceId = nil }
        var saved = favorites
        saved[id] = nil
        favorites = saved
        devices.forget(id)
    }

    func windowClosed() {
        connectionWindowClosed()
        if !(UserDefaults.standard.object(forKey: "keepConnectedWhenClosed") as? Bool ?? true) {
            disconnect()
        } else if controller.isStreaming && controller.hasVideo && !UserDefaults.standard.bool(forKey: "explainedBackgroundConnection") {
            let alert = NSAlert()
            alert.messageText = "Keep mirroring in the background?"
            alert.informativeText = "Use the Android Mirroring menu bar icon to show the phone again or disconnect. You can change this behavior in Settings."
            alert.addButton(withTitle: "Keep Connected")
            alert.addButton(withTitle: "Disconnect")
            UserDefaults.standard.set(true, forKey: "explainedBackgroundConnection")
            if alert.runModal() == .alertSecondButtonReturn { disconnect() }
        }
    }

    func connectionWindowClosed() {
        openWhenReady = false
        pendingFavorite = nil
    }

    // MARK: App favorites

    private var favorites: [String: [FavoriteApp]] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "favoriteApps") else { return [:] }
            return (try? JSONDecoder().decode([String: [FavoriteApp]].self, from: data)) ?? [:]
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "favoriteApps") }
    }

    func favoriteApps(on id: String) -> [FavoriteApp] { favorites[id] ?? [] }

    func setFavoriteApps(_ apps: [FavoriteApp], on id: String) {
        var saved = favorites
        saved[id] = apps.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        favorites = saved
    }

    func openFavorite(_ app: FavoriteApp, on id: String) {
        connect(id, opening: app)
        if openWhenReady { showDevices() }
    }

    private func launch(_ app: FavoriteApp) {
        controller.startApp(app.package)
        windowController?.ui.show(toast: "Opening \(app.label) · Unlock your phone if asked")
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

    var agentCommandPath: String {
        let bundled = URL(fileURLWithPath: droidctlPath).resolvingSymlinksInPath()
        for path in ["/opt/homebrew/bin/droidctl", "/usr/local/bin/droidctl"] {
            if FileManager.default.isExecutableFile(atPath: path),
               URL(fileURLWithPath: path).resolvingSymlinksInPath() == bundled { return path }
        }
        return droidctlPath
    }

    var mcpConfigSnippet: String {
        """
        {
          "mcpServers": {
            "android": {
              "command": "\(agentCommandPath)",
              "args": ["mcp"]
            }
          }
        }
        """
    }

    var claudeCodeCommand: String { "claude mcp add android -s user -- \"\(agentCommandPath)\" mcp" }
}

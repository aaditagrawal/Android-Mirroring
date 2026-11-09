import AppKit
import Combine
import MirrorKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = AppModel()
    var mirror: MirrorWindowController!
    var devicesWindow: NSWindow?
    var settingsWindow: NSWindow?
    var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()

    /// Prevents App Nap: agents drive the phone while the window is hidden, and gesture timing
    /// (8 ms touch steps) plus decode latency must not be throttled in the background.
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
            reason: "Low-latency phone mirroring and agent control")
        mirror = MirrorWindowController(model: model)
        model.windowController = mirror
        model.showDevicesWindow = { [weak self] in self?.showDevices() }
        model.showSettingsWindow = { [weak self] in self?.showSettings() }
        model.notifications.onOpen = { [weak self] pkg in
            self?.model.controller.startApp(pkg)
            self?.mirror.showMirror()
        }
        buildMainMenu()
        buildStatusItem()
        model.notifications.requestAuthorization()
        model.start()
        mirror.showMirror()

        model.controller.$state.combineLatest(model.controller.$activeTransport)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.updateStatusIcon() }
            .store(in: &cancellables)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mirror.showMirror() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if model.phoneScreenOff { model.controller.setDisplayPower(true) }
        model.agent.stop()
        model.controller.disconnect()
        Thread.sleep(forTimeInterval: 0.15)
    }

    // MARK: Windows

    @objc func showDevices() {
        if devicesWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
                             styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Phones"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: DevicesView(model: model))
            w.center()
            w.setFrameAutosaveName("DevicesWindow")
            devicesWindow = w
        }
        devicesWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 470),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(model: model))
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showMirror() { mirror.showMirror() }

    // MARK: Menu actions

    @objc func home() { model.controller.key(AKey.home) }
    @objc func back() { model.controller.key(AKey.back) }
    @objc func recents() { model.controller.key(AKey.appSwitch) }
    @objc func notifications() { model.controller.expandNotifications() }
    @objc func quickSettings() { model.controller.expandSettings() }
    @objc func volumeUp() { model.controller.key(AKey.volumeUp) }
    @objc func volumeDown() { model.controller.key(AKey.volumeDown) }
    @objc func rotate() { model.controller.rotate() }
    @objc func lock() { model.controller.key(AKey.power) }
    @objc func unlock() { model.unlockPhone() }
    @objc func screenshot() { model.saveScreenshot(ui: mirror.ui) }
    @objc func toggleScreenOff() { model.setPhoneScreenOff(!model.phoneScreenOff) }
    @objc func actualSize() { mirror.setScale(1) }
    @objc func zoomIn() { mirror.zoom(by: 1.15) }
    @objc func zoomOut() { mirror.zoom(by: 1 / 1.15) }
    @objc func disconnect() { model.disconnect() }
    @objc func reconnect() { model.reconnect() }
    @objc func toggleFloat() {
        guard let w = mirror.window else { return }
        w.level = w.level == .floating ? .normal : .floating
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleScreenOff): item.state = model.phoneScreenOff ? .on : .off
        case #selector(toggleFloat): item.state = mirror.window?.level == .floating ? .on : .off
        default: break
        }
        let needsSession: Set<Selector?> = [#selector(home), #selector(back), #selector(recents), #selector(notifications),
                                             #selector(quickSettings), #selector(volumeUp), #selector(volumeDown), #selector(rotate),
                                             #selector(lock), #selector(unlock), #selector(screenshot), #selector(toggleScreenOff),
                                             #selector(actualSize), #selector(disconnect)]
        if needsSession.contains(item.action) { return model.controller.isStreaming }
        return true
    }

    // MARK: Main menu

    private func buildMainMenu() {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About Android Mirroring", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(showSettings), ","))
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Android Mirroring", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Android Mirroring", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu("Android Mirroring", app))

        let file = NSMenu(title: "File")
        file.addItem(item("Phones…", #selector(showDevices), "p", [.command, .shift]))
        file.addItem(item("Reconnect", #selector(reconnect), "r", [.command, .shift]))
        file.addItem(item("Disconnect", #selector(disconnect), "d", [.command, .shift]))
        file.addItem(.separator())
        file.addItem(item("Save Screenshot", #selector(screenshot), "s", [.command, .shift]))
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu("File", file))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu("Edit", edit))

        let view = NSMenu(title: "View")
        view.addItem(item("Actual Size", #selector(actualSize), "0"))
        view.addItem(item("Make Bigger", #selector(zoomIn), "+"))
        view.addItem(item("Make Smaller", #selector(zoomOut), "-"))
        view.addItem(.separator())
        view.addItem(item("Keep on Top", #selector(toggleFloat), "t", [.command, .option]))
        main.addItem(submenu("View", view))

        let phone = NSMenu(title: "Phone")
        phone.addItem(item("Home", #selector(home), "1"))
        phone.addItem(item("Recent Apps", #selector(recents), "2"))
        phone.addItem(item("Notifications", #selector(notifications), "3"))
        phone.addItem(item("Quick Settings", #selector(quickSettings), "4"))
        phone.addItem(item("Back", #selector(back), "["))
        phone.addItem(.separator())
        phone.addItem(item("Volume Up", #selector(volumeUp), String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))))
        phone.addItem(item("Volume Down", #selector(volumeDown), String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))))
        phone.addItem(item("Rotate", #selector(rotate), "r"))
        phone.addItem(.separator())
        phone.addItem(item("Turn Phone Screen Off", #selector(toggleScreenOff), "o", [.command, .option]))
        phone.addItem(item("Lock", #selector(lock), "l"))
        phone.addItem(item("Unlock", #selector(unlock), "u", [.command, .option]))
        main.addItem(submenu("Phone", phone))

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(item("Android Mirroring", #selector(showMirror), "m", [.command, .shift]))
        main.addItem(submenu("Window", window))
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    private func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = self
        return i
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        i.submenu = menu
        return i
    }

    // MARK: Status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        let symbol: String
        switch model.controller.state {
        case .streaming: symbol = "smartphone"
        case .connecting, .reconnecting: symbol = "arrow.triangle.2.circlepath"
        default: symbol = "iphone.slash"
        }
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Android Mirroring")
        img?.isTemplate = true
        statusItem.button?.image = img
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let c = model.controller
        if let d = c.device, c.state.isActive {
            let title = NSMenuItem(title: d.name, action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            if let t = c.activeTransport {
                let s = NSMenuItem(title: "\(t.label) · \(c.stats.codec) \(Int(c.stats.fps)) fps", action: nil, keyEquivalent: "")
                s.isEnabled = false
                menu.addItem(s)
            }
            if d.transports.count > 1 {
                let paths = NSMenu()
                for t in d.transports {
                    let i = NSMenuItem(title: t.label, action: #selector(switchPath(_:)), keyEquivalent: "")
                    i.representedObject = t.serial
                    i.target = self
                    i.state = t.serial == c.activeTransport?.serial ? .on : .off
                    paths.addItem(i)
                }
                let pi = NSMenuItem(title: "Connection", action: nil, keyEquivalent: "")
                pi.submenu = paths
                menu.addItem(pi)
            }
            menu.addItem(.separator())
            menu.addItem(item("Show Phone", #selector(showMirror), ""))
            let so = item("Phone Screen Off", #selector(toggleScreenOff), "")
            so.state = model.phoneScreenOff ? .on : .off
            menu.addItem(so)
            menu.addItem(item("Disconnect", #selector(disconnect), ""))
        } else {
            for d in model.devices.devices {
                let i = NSMenuItem(title: "Mirror \(d.name)", action: #selector(connectDevice(_:)), keyEquivalent: "")
                i.representedObject = d.id
                i.target = self
                menu.addItem(i)
            }
            if model.devices.devices.isEmpty {
                let i = NSMenuItem(title: "No phones connected", action: nil, keyEquivalent: "")
                i.isEnabled = false
                menu.addItem(i)
            }
        }
        menu.addItem(.separator())
        menu.addItem(item("Phones…", #selector(showDevices), ""))
        menu.addItem(item("Settings…", #selector(showSettings), ""))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
    }

    @objc func switchPath(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? String { model.controller.switchTo(serial: s) }
    }

    @objc func connectDevice(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { model.connect(id) }
    }
}

// If launched from a throttled (background-role) process, leave the background band so
// decode, gesture timing and agent calls are not delayed.
setpriority(PRIO_DARWIN_PROCESS, 0, 0)
// Deliver every mouse / trackpad event instead of one per display refresh: denser touch paths give
// Android's input resampling more to work with (smoother drags), and the relay keeps their spacing.
NSEvent.isMouseCoalescingEnabled = false

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

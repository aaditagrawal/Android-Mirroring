import AppKit
import Foundation
import MirrorKit
import UserNotifications

/// Mirrors new phone notifications into macOS Notification Center.
/// Clicking one opens that app on the phone and brings up the mirror window.
final class NotificationBridge: NSObject, UNUserNotificationCenterDelegate, NSUserNotificationCenterDelegate {
    let controller: MirrorController
    private var timer: DispatchSourceTimer?
    private var seen = Set<String>()
    private var primed = false
    private var labels: [String: String] = [:]
    var onOpen: ((String) -> Void)?
    private var authorized = false
    private var lastKeys = Set<String>()
    private var lastFullFetch = Date.distantPast

    static var enabled: Bool { UserDefaults.standard.object(forKey: "forwardNotifications") as? Bool ?? true }

    init(controller: MirrorController) {
        self.controller = controller
        super.init()
    }

    func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            self.authorized = granted
            if let error { Log.warn("notification authorization: \(error.localizedDescription) — using legacy notifications") }
        }
        NSUserNotificationCenter.default.delegate = self
    }

    func start() {
        guard timer == nil, NotificationBridge.enabled else { return }
        primed = false
        seen.removeAll()
        lastKeys.removeAll()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 1, repeating: 5)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }

    private func poll() {
        guard NotificationBridge.enabled, let serial = controller.serial else { return }
        let q = DeviceQueries(adb: controller.adb, serial: serial)
        // Cheap change detection first (`cmd notification list` ≈ keys only); the full dumpsys
        // is ~3 MB of work on the phone, so only run it when something changed (or every 30 s,
        // since messaging apps update text in place under the same key).
        if let keysOut = try? controller.adb.shell(serial: serial, "cmd notification list", timeout: 5) {
            let keys = Set(keysOut.split(separator: "\n").map(String.init))
            let changed = !keys.subtracting(lastKeys).isEmpty
            lastKeys = keys
            if primed && !changed && Date().timeIntervalSince(lastFullFetch) < 30 { return }
        }
        lastFullFetch = Date()
        guard let list = try? q.notifications() else { return }
        if labels.isEmpty, let apps = try? q.listApps() {
            labels = Dictionary(apps.map { ($0.package, $0.label) }, uniquingKeysWith: { a, _ in a })
        }
        let fresh = list.filter { n in
            !n.ongoing && !n.groupSummary && n.importance >= 2 && !(n.title.isEmpty && n.text.isEmpty)
                && n.package != "android" && n.package != "com.android.systemui"
        }
        defer { primed = true }
        for n in fresh {
            let id = n.key + "|" + n.title + "|" + n.text
            guard seen.insert(id).inserted else { continue }
            // Don't replay what was already on the phone when we connected.
            guard primed else { continue }
            if let posted = n.postedAt, Date().timeIntervalSince(posted) > 120 { continue }
            post(n)
        }
    }

    private func post(_ n: PhoneNotification) {
        let content = UNMutableNotificationContent()
        let app = labels[n.package] ?? n.package.split(separator: ".").last.map { String($0).capitalized } ?? n.package
        content.title = n.title.isEmpty ? app : n.title
        content.subtitle = n.title.isEmpty ? "" : app
        content.body = n.text
        content.sound = .default
        content.userInfo = ["package": n.package]
        content.threadIdentifier = n.package
        if authorized {
            let req = UNNotificationRequest(identifier: n.key, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req) { err in
                if let err { Log.warn("post notification: \(err.localizedDescription)") }
            }
        } else {
            // Ad-hoc signed builds can't use UserNotifications; the legacy center still delivers.
            let legacy = NSUserNotification()
            legacy.title = content.title
            legacy.subtitle = content.subtitle.isEmpty ? nil : content.subtitle
            legacy.informativeText = content.body
            legacy.soundName = NSUserNotificationDefaultSoundName
            legacy.userInfo = ["package": n.package]
            legacy.identifier = n.key
            DispatchQueue.main.async { NSUserNotificationCenter.default.deliver(legacy) }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let pkg = response.notification.request.content.userInfo["package"] as? String {
            DispatchQueue.main.async { self.onOpen?(pkg) }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: NSUserNotificationCenter, didActivate notification: NSUserNotification) {
        if let pkg = notification.userInfo?["package"] as? String { onOpen?(pkg) }
        center.removeDeliveredNotification(notification)
    }

    func userNotificationCenter(_ center: NSUserNotificationCenter, shouldPresent notification: NSUserNotification) -> Bool { true }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Show banners even while the mirror window is frontmost, unless that app is already on screen.
        completionHandler([.banner, .sound])
    }
}

/// Reads Android peers from the local Tailscale client, for one-click remote connections.
enum TailscalePeers {
    struct Peer: Hashable { let name: String; let ip: String; let online: Bool }

    static var binary: String? {
        ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func android() -> [Peer] {
        guard let bin = binary else { return [] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["status", "--json"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let peers = obj["Peer"] as? [String: [String: Any]] else { return [] }
        return peers.values.compactMap { peer in
            guard (peer["OS"] as? String)?.lowercased() == "android",
                  let ip = (peer["TailscaleIPs"] as? [String])?.first(where: { $0.contains(".") }) else { return nil }
            let name = (peer["HostName"] as? String) ?? (peer["DNSName"] as? String) ?? ip
            return Peer(name: name, ip: ip, online: peer["Online"] as? Bool ?? false)
        }.sorted { $0.name < $1.name }
    }
}

import AgentProtocol
import AppKit
import MirrorKit
import ServiceManagement
import SwiftUI

// MARK: - General

struct GeneralSettings: View {
    let model: AppModel
    @AppStorage("clipboardSync") private var clipboardSync = true
    @AppStorage("forwardNotifications") private var forwardNotifications = true
    @AppStorage("screenOff") private var screenOff = false
    @AppStorage("keepConnectedWhenClosed") private var keepConnected = true
    @AppStorage("lockOnDisconnect") private var lockOnDisconnect = false
    @AppStorage("trackpadAsTouch") private var trackpadAsTouch = true
    @AppStorage("stayAwake") private var stayAwake = false
    @AppStorage("autoSwitchPaths") private var autoSwitch = true
    @AppStorage("adbServerSocket") private var serverSocket = ""
    @AppStorage("adbPath") private var adbPath = ""
    @StateObject private var standby = Box(true)
    @StateObject private var pin = Box(Keychain.pin ?? "")
    @StateObject private var loginItem = Box(SMAppService.mainApp.status == .enabled)

    var body: some View {
        Form {
            Section { PhoneHeader(controller: model.controller) }

            Section {
                ToggleRow("Share clipboard", icon: "doc.on.clipboard.fill", tint: .blue, isOn: $clipboardSync)
                ToggleRow("Phone notifications on this Mac", icon: "bell.badge.fill", tint: .red, isOn: $forwardNotifications)
                ToggleRow("Trackpad scrolls like a finger", icon: "hand.draw.fill", tint: .orange, isOn: $trackpadAsTouch)
                ToggleRow("Dim the phone while mirroring", icon: "moon.fill", tint: .indigo, isOn: $screenOff,
                          detail: "The phone stays dark and private.")
            }

            Section("Connection") {
                ToggleRow("Hop to the fastest link", icon: "bolt.horizontal.fill", tint: .green, isOn: $autoSwitch,
                          detail: "Moves to USB or Wi-Fi when they appear, falls back in about a second.")
                ToggleRow("Keep backup links warm", icon: "point.3.connected.trianglepath.dotted", tint: .teal, isOn: $standby.value)
                    .onChange(of: standby.value) { _, v in model.devices.keepStandbyLinks = v }
                ToggleRow("Stay connected when closed", icon: "link", tint: .purple, isOn: $keepConnected,
                          detail: "So agents can keep using the phone.")
                ToggleRow("Open at login", icon: "power", tint: .gray, isOn: $loginItem.value)
                    .onChange(of: loginItem.value) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            Log.warn("login item: \(error)")
                        }
                    }
            }

            Section("Phone") {
                IconRow("Unlock PIN", icon: "lock.open.fill", tint: .pink, detail: "Kept in your Keychain. Used by Unlock and by agents.") {
                    SecureField("", text: $pin.value, prompt: Text("None"))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 110)
                        .onChange(of: pin.value) { _, v in Keychain.pin = v }
                }
                ToggleRow("Lock it when disconnecting", icon: "lock.fill", tint: .gray, isOn: $lockOnDisconnect)
                ToggleRow("Keep it awake while charging", icon: "cup.and.saucer.fill", tint: .brown, isOn: $stayAwake)
            }

            Section {
                DisclosureGroup("Advanced") {
                    TextField("ADB server", text: $serverSocket, prompt: Text("tcp:127.0.0.1:5037"))
                        .help("Use an adb server on another machine (tunnel its port 5037). Takes effect after relaunching.")
                    TextField("adb", text: $adbPath, prompt: Text(ADBTool.executablePath ?? "not found"))
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { standby.value = model.devices.keepStandbyLinks }
        .onChange(of: clipboardSync) { _, _ in model.controller.restart() }
        .onChange(of: stayAwake) { _, _ in model.controller.restart() }
    }
}

/// The connected phone and how it is connected, live.
struct PhoneHeader: View {
    @ObservedObject var controller: MirrorController

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.35, green: 0.85, blue: 0.55), Color(red: 0.1, green: 0.6, blue: 0.75)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 30, height: 52)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.black.opacity(0.18))
                    .frame(width: 24, height: 44)
                Image(systemName: "face.smiling")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(controller.device?.name ?? "No phone yet").font(.title3.weight(.semibold))
                HStack(spacing: 6) {
                    Circle().fill(status.color).frame(width: 7, height: 7)
                    Text(status.text).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var status: (text: String, color: Color) {
        switch controller.state {
        case .streaming:
            return ("Mirroring over \(controller.activeTransport?.kind.label ?? "ADB")", .green)
        case .connecting(let d), .reconnecting(let d):
            return (d, .orange)
        case .failed(let e):
            return (e, .red)
        case .idle:
            return (controller.device == nil ? "Turn on wireless debugging to pair" : "Not mirroring", .secondary)
        }
    }
}

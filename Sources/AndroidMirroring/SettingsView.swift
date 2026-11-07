import AgentProtocol
import AppKit
import MirrorKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            GeneralSettings(model: model).tabItem { Label("General", systemImage: "gearshape") }
            VideoSettings(model: model).tabItem { Label("Video & Audio", systemImage: "play.rectangle") }
            ConnectionSettings(model: model).tabItem { Label("Connection", systemImage: "antenna.radiowaves.left.and.right") }
            AgentSettings(model: model).tabItem { Label("Agents", systemImage: "sparkles") }
            ShortcutsHelp().tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 560, height: 470)
    }
}

private struct GeneralSettings: View {
    let model: AppModel
    @AppStorage("clipboardSync") private var clipboardSync = true
    @AppStorage("forwardNotifications") private var forwardNotifications = true
    @AppStorage("screenOff") private var screenOff = false
    @AppStorage("keepConnectedWhenClosed") private var keepConnected = true
    @AppStorage("lockOnDisconnect") private var lockOnDisconnect = false
    @AppStorage("trackpadAsTouch") private var trackpadAsTouch = true
    @AppStorage("stayAwake") private var stayAwake = false
    @StateObject private var pin = Box(Keychain.pin ?? "")
    @StateObject private var loginItem = Box(SMAppService.mainApp.status == .enabled)

    var body: some View {
        Form {
            Section {
                Toggle("Open at login (keeps your phone available to you and your agents)", isOn: $loginItem.value)
                    .onChange(of: loginItem.value) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            Log.warn("login item: \(error)")
                        }
                    }
            }
            Section {
                Toggle("Share clipboard between Mac and phone", isOn: $clipboardSync)
                Toggle("Show phone notifications on this Mac", isOn: $forwardNotifications)
                Toggle("Turn off the phone's screen while mirroring", isOn: $screenOff)
                    .help("The phone stays dark and private; mirroring keeps working.")
                Toggle("Two-finger trackpad scrolling acts as a finger swipe", isOn: $trackpadAsTouch)
            }
            Section {
                Toggle("Stay connected when the window is closed (for agents)", isOn: $keepConnected)
                Toggle("Lock the phone when disconnecting", isOn: $lockOnDisconnect)
                Toggle("Keep the phone awake while plugged in", isOn: $stayAwake)
            }
            Section("Unlock") {
                SecureField("Phone PIN (stored in your Keychain)", text: $pin.value)
                    .onSubmit { Keychain.pin = pin.value }
                    .onChange(of: pin.value) { _, v in Keychain.pin = v }
                Text("Used by “Unlock” in the toolbar menu and by agents to wake and unlock the phone. Leave empty to disable.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: clipboardSync) { _, _ in model.controller.restart() }
        .onChange(of: stayAwake) { _, _ in model.controller.restart() }
    }
}

private struct VideoSettings: View {
    let model: AppModel
    @AppStorage("quality") private var quality = "auto"
    @AppStorage("codec") private var codec = "h265"
    @AppStorage("maxFps") private var maxFps = 60
    @AppStorage("audio") private var audio = true
    @AppStorage("showTouches") private var showTouches = false

    var body: some View {
        Form {
            Section {
                Picker("Quality", selection: $quality) {
                    Text("Automatic (adapts to the connection)").tag("auto")
                    Text("Maximum — native resolution, 16 Mbps").tag("high")
                    Text("Balanced — 1920 px, 8 Mbps").tag("balanced")
                    Text("Data saver — 1280 px, 3 Mbps").tag("data")
                }
                Picker("Codec", selection: $codec) {
                    Text("HEVC (H.265) — sharper at the same bitrate").tag("h265")
                    Text("H.264 — maximum compatibility").tag("h264")
                }
                Picker("Frame rate", selection: $maxFps) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                    Text("90 fps").tag(90)
                    Text("120 fps").tag(120)
                }
                Toggle("Play phone audio on this Mac", isOn: $audio)
                    .help("Requires Android 11+. While mirroring, audio plays on the Mac instead of the phone.")
                Toggle("Show touches on the phone", isOn: $showTouches)
            }
            Section {
                Text("Automatic uses native resolution at 12 Mbps on Wi-Fi, 20 Mbps over USB and 1600 px at 6 Mbps over Tailscale or slow links. Decoding is hardware-accelerated with VideoToolbox; frames are displayed the instant they are decoded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: quality) { _, _ in model.controller.restart() }
        .onChange(of: codec) { _, _ in model.controller.restart() }
        .onChange(of: maxFps) { _, _ in model.controller.restart() }
        .onChange(of: audio) { _, _ in model.controller.restart() }
        .onChange(of: showTouches) { _, _ in model.controller.restart() }
    }
}

private struct ConnectionSettings: View {
    let model: AppModel
    @AppStorage("autoSwitchPaths") private var autoSwitch = true
    @AppStorage("adbServerSocket") private var serverSocket = ""
    @AppStorage("adbPath") private var adbPath = ""
    @StateObject private var standby = Box(true)

    var body: some View {
        Form {
            Section {
                Toggle("Switch to a faster connection automatically", isOn: $autoSwitch)
                Toggle("Keep backup connections open (Wi-Fi + Tailscale + USB)", isOn: $standby.value)
                    .onChange(of: standby.value) { _, v in model.devices.keepStandbyLinks = v }
                Text("Android Mirroring remembers every address your phone has been reachable at — its Wi-Fi address, its Tailscale address and USB — keeps them connected in the background, and fails over in about a second if the active one drops. When a faster path comes back (you get home, or plug in a cable) it moves the stream there.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("ADB") {
                TextField("ADB server (default tcp:127.0.0.1:5037)", text: $serverSocket)
                    .help("Use an adb server on another machine, e.g. when the phone is plugged into a different computer (tunnel its port 5037).")
                TextField("adb executable (auto-detected: \(ADBTool.executablePath ?? "not found"))", text: $adbPath)
                Text("Changes to the ADB server take effect after relaunching.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { standby.value = model.devices.keepStandbyLinks }
    }
}

private struct AgentSettings: View {
    let model: AppModel
    @StateObject private var copied = Box<String?>(nil)

    var body: some View {
        Form {
            Section {
                Text("Agents control the phone through the bundled **droidctl** tool — as an MCP server or a CLI. Screenshots come straight from the live video stream (~10 ms) and input uses the same low-latency channel as your mouse, so agents don't need the window to be visible and the phone doesn't need to be locked or idle.")
                    .font(.callout)
            }
            Section("Claude Code") {
                copyRow(model.claudeCodeCommand, key: "cc")
            }
            Section("Any MCP client (claude_desktop_config.json, Cursor, …)") {
                copyRow(model.mcpConfigSnippet, key: "json")
            }
            Section("Command line") {
                copyRow("\"\(model.droidctlPath)\" screenshot -o phone.png\n\"\(model.droidctlPath)\" tap 540 1200\n\"\(model.droidctlPath)\" ui", key: "cli")
                Button("Install droidctl to /usr/local/bin") { installCLI() }
            }
            Section {
                Text("API socket: \(AgentAPI.socketPath)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    private func copyRow(_ text: String, key: String) -> some View {
        HStack(alignment: .top) {
            Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied.value == key ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied.value = key
            }
        }
    }

    private func installCLI() {
        let src = model.droidctlPath.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"mkdir -p /usr/local/bin && ln -sf '\(src)' /usr/local/bin/droidctl\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
    }
}

private struct ShortcutsHelp: View {
    let rows: [(String, String)] = [
        ("⌘1", "Home"), ("⌘2", "Recent apps"), ("⌘3", "Notifications"), ("⌘4", "Quick settings"),
        ("Esc  /  ⌘[  /  right-click", "Back"), ("Middle-click", "Home"),
        ("⌘C / ⌘X / ⌘V", "Copy / cut / paste through the phone clipboard"),
        ("⌘A / ⌘Z", "Select all / undo"), ("⌥⌫  ⌥←  ⌥→", "Word-wise delete and move"),
        ("⌘↑ / ⌘↓", "Volume up / down"), ("⌘R", "Rotate"), ("⌘L", "Lock phone (power button)"),
        ("⌘⇧S", "Screenshot to Desktop"), ("⌘0 / ⌘+ / ⌘−", "Actual size / bigger / smaller"),
        ("⌘-drag", "Move the window"), ("Two-finger scroll", "Swipe (with fling)"), ("Pinch", "Pinch zoom"),
        ("Drop an .apk", "Install it"), ("Drop any file", "Copy to the phone's Downloads"),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(rows, id: \.0) { r in
                    HStack {
                        Text(r.0).font(.system(.body, design: .rounded).weight(.medium)).frame(width: 190, alignment: .leading)
                        Text(r.1).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

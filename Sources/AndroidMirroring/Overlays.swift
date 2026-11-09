import AppKit
import MirrorKit
import SwiftUI

/// Stand-in for @State (the Command Line Tools toolchain lacks the SwiftUI macro plugin).
final class Box<T>: ObservableObject {
    @Published var value: T
    init(_ v: T) { value = v }
}

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowDragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Top-of-window controls that slide in on hover (like iPhone Mirroring).
struct HoverToolbar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var ui: WindowUIState
    @ObservedObject var controller: MirrorController
    let window: () -> NSWindow?

    init(model: AppModel, ui: WindowUIState, window: @escaping () -> NSWindow?) {
        self.model = model
        self.ui = ui
        self.controller = model.controller
        self.window = window
    }

    var body: some View {
        VStack(spacing: 0) {
            if ui.toolbarVisible {
                HStack(spacing: 4) {
                    trafficLights
                    Spacer(minLength: 4)
                    ToolbarButton(symbol: "chevron.backward", help: "Back (Esc, ⌘[)") { model.controller.key(AKey.back) }
                    ToolbarButton(symbol: "circle", help: "Home (⌘1)") { model.controller.key(AKey.home) }
                    ToolbarButton(symbol: "square.on.square", help: "Recent Apps (⌘2)") { model.controller.key(AKey.appSwitch) }
                    Spacer(minLength: 4)
                    pathBadge
                    moreMenu
                }
                .padding(.horizontal, 10)
                .frame(height: MirrorWindowController.toolbarBarHeight)
                .background(WindowDragArea())
                .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08)))
                // Slides up out of the top edge of the phone screen.
                .transition(.offset(y: MirrorWindowController.stripHeight).combined(with: .opacity))
                .onHover { inside in model.windowController?.toolbarHovering(inside) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        // The window's (hidden) title bar would otherwise push the bar down by its height.
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }

    private var trafficLights: some View {
        HStack(spacing: 7) {
            Circle().fill(Color(nsColor: .systemRed)).frame(width: 12, height: 12)
                .onTapGesture { window()?.performClose(nil) }
                .help("Close")
            Circle().fill(Color(nsColor: .systemYellow)).frame(width: 12, height: 12)
                .onTapGesture { window()?.miniaturize(nil) }
                .help("Minimize")
        }
    }

    @ViewBuilder private var pathBadge: some View {
        if let t = controller.activeTransport {
            HStack(spacing: 3) {
                Image(systemName: t.kind.symbol).font(.system(size: 10, weight: .semibold))
                if let ms = t.rttMs { Text("\(Int(ms))ms").font(.system(size: 10, weight: .medium).monospacedDigit()) }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.white.opacity(0.08), in: Capsule())
            .help("Connected via \(t.kind.label) (\(t.serial)) · \(controller.stats.codec) \(Int(controller.stats.fps)) fps · \(String(format: "%.1f", controller.stats.bitrateMbps)) Mbps")
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Notifications") { model.controller.expandNotifications() }
            Button("Quick Settings") { model.controller.expandSettings() }
            Divider()
            Button("Take Screenshot") { model.saveScreenshot(ui: ui) }
            Button("Rotate") { model.controller.rotate() }
            Toggle("Phone Screen Off", isOn: Binding(get: { model.phoneScreenOff }, set: { model.setPhoneScreenOff($0) }))
            Button("Lock Phone") { model.controller.key(AKey.power) }
            Button("Unlock") { model.unlockPhone() }
            Divider()
            Menu("Volume") {
                Button("Volume Up") { model.controller.key(AKey.volumeUp) }
                Button("Volume Down") { model.controller.key(AKey.volumeDown) }
                Button("Mute") { model.controller.key(AKey.volumeMute) }
            }
            if let d = controller.device, d.transports.count > 1 {
                Menu("Connection") {
                    ForEach(d.transports) { t in
                        Button {
                            model.controller.switchTo(serial: t.serial)
                        } label: {
                            Text((t.serial == controller.activeTransport?.serial ? "✓ " : "") + t.label)
                        }
                    }
                }
            }
            Divider()
            Button("Disconnect") { model.disconnect() }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 14))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }
}

struct ToolbarButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 26)
                .background(hover.value ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover.value = $0 }
        .help(help)
    }
}

/// Status overlay: connecting / reconnecting / failed / idle, plus toasts and progress.
struct MirrorOverlay: View {
    @ObservedObject var controller: MirrorController
    @ObservedObject var model: AppModel
    @ObservedObject var ui: WindowUIState

    var body: some View {
        ZStack {
            statusLayer
            VStack {
                Spacer()
                if let p = ui.progress {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(p).font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 10)
                }
                if let t = ui.toast {
                    Text(t)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 28)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var statusLayer: some View {
        switch controller.state {
        case .streaming:
            if controller.frameSize == .zero { card(spinner: true, title: phoneName, detail: "Starting video…") }
        case .connecting(let detail):
            card(spinner: true, title: phoneName, detail: detail)
        case .reconnecting(let detail):
            card(spinner: true, title: "Reconnecting", detail: detail, dim: 0.55)
        case .failed(let msg):
            card(spinner: false, title: "Couldn't connect", detail: msg) {
                Button("Try Again") { model.reconnect() }.buttonStyle(.borderedProminent)
                Button("Choose Phone…") { model.showDevices() }.buttonStyle(.bordered)
            }
        case .idle:
            card(spinner: false, title: "Not connected", detail: model.idleHint) {
                if model.canQuickConnect {
                    Button("Connect") { model.reconnect() }.buttonStyle(.borderedProminent)
                }
                Button("Phones…") { model.showDevices() }.buttonStyle(.bordered)
            }
        }
    }

    private var phoneName: String { controller.device?.name ?? "Android Phone" }

    private func card<Buttons: View>(spinner: Bool, title: String, detail: String, dim: Double = 1,
                                     @ViewBuilder buttons: () -> Buttons = { EmptyView() }) -> some View {
        ZStack {
            Rectangle().fill(.black.opacity(dim))
            VStack(spacing: 14) {
                Image(systemName: "smartphone")
                    .font(.system(size: 42, weight: .thin))
                    .foregroundStyle(.white.opacity(0.85))
                    .symbolEffect(.pulse, isActive: spinner)
                VStack(spacing: 5) {
                    Text(title).font(.system(size: 17, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                }
                if spinner { ProgressView().controlSize(.small) }
                HStack(spacing: 8) { buttons() }.controlSize(.regular)
            }
            .padding(24)
        }
        .transition(.opacity)
    }
}

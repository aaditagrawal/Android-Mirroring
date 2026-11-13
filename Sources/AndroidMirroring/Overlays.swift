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

/// One glass surface for the title bar and outline, with the phone cut out of its center.
struct MirrorChrome: View {
    let screenRadius: CGFloat
    var toolbarOverlaysPhone = false

    var body: some View {
        let outline = Outline(screenRadius: screenRadius, toolbarOverlaysPhone: toolbarOverlaysPhone)
        Group {
            #if compiler(>=6.2)
            if #available(macOS 26, *) {
                Color.clear.glassEffect(.regular, in: outline)
            } else {
                outline.fill(.regularMaterial)
            }
            #else
            outline.fill(.regularMaterial)
            #endif
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct Outline: Shape {
        let screenRadius: CGFloat
        let toolbarOverlaysPhone: Bool

        func path(in rect: CGRect) -> Path {
            let inset = MirrorWindowController.frameInset
            let bar = MirrorWindowController.toolbarBarHeight
            let outer = UnevenRoundedRectangle(topLeadingRadius: 14,
                                               bottomLeadingRadius: screenRadius + inset,
                                               bottomTrailingRadius: screenRadius + inset,
                                               topTrailingRadius: 14)
            var path = outer.path(in: rect)
            let phone = CGRect(x: rect.minX + inset, y: rect.minY + bar,
                               width: rect.width - 2 * inset, height: rect.height - bar - inset)
            let topRadius = toolbarOverlaysPhone ? 0 : screenRadius
            let hole = UnevenRoundedRectangle(topLeadingRadius: topRadius,
                                              bottomLeadingRadius: screenRadius,
                                              bottomTrailingRadius: screenRadius,
                                              topTrailingRadius: topRadius).path(in: phone)
            // Reverse the inner winding so the glass never covers the video beneath the frame.
            path.addPath(hole, transform: CGAffineTransform(a: -1, b: 0, c: 0, d: 1,
                                                           tx: phone.minX + phone.maxX, ty: 0))
            return path
        }
    }
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
                    Spacer(minLength: 8)
                    ToolbarButton(symbol: "chevron.backward", help: "Back (Esc, ⌘[)") { model.controller.key(AKey.back) }
                    ToolbarButton(symbol: "square.grid.3x3.fill", help: "Home (⌘1)") { model.controller.key(AKey.home) }
                    ToolbarButton(symbol: "rectangle.on.rectangle", help: "Recent Apps (⌘2)") { model.controller.key(AKey.appSwitch) }
                    moreMenu
                }
                .padding(.horizontal, 10)
                .frame(height: MirrorWindowController.toolbarBarHeight)
                .background(WindowDragArea())
                .foregroundStyle(.secondary)
                // Slides up out of the top edge of the phone screen.
                .transition(.offset(y: MirrorWindowController.stripHeight).combined(with: .opacity))
                .onHover { inside in model.windowController?.toolbarHovering(inside) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        // The window's (hidden) title bar would otherwise push the bar down by its height.
        .ignoresSafeArea()
    }

    private var trafficLights: some View {
        HStack(spacing: 8) {
            Button { window()?.performClose(nil) } label: {
                Circle().fill(Color(nsColor: .systemRed)).frame(width: 12, height: 12)
            }
                .accessibilityLabel("Close")
                .help("Close")
            Button { window()?.miniaturize(nil) } label: {
                Circle().fill(Color(nsColor: .systemYellow)).frame(width: 12, height: 12)
            }
                .accessibilityLabel("Minimize")
                .help("Minimize")
            Circle().fill(.secondary.opacity(0.2)).frame(width: 12, height: 12)
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
    }

    private var moreMenu: some View {
        Menu {
            if let t = controller.activeTransport {
                Text("\(t.kind.label) · \(controller.stats.codec) · \(Int(controller.stats.fps)) fps")
                if let ms = t.rttMs { Text("Latency: \(Int(ms)) ms") }
                Divider()
            }
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
                .background(hover.value ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover.value = $0 }
        .accessibilityLabel(help)
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

import AgentProtocol
import AppKit
import MirrorKit
import ServiceManagement
import SwiftUI

// MARK: - Picture

struct PictureSettings: View {
    let model: AppModel
    @AppStorage("quality") private var quality = "auto"
    @AppStorage("codec") private var codec = "h265"
    @AppStorage("maxFps") private var maxFps = 0
    @AppStorage("pacing") private var pacing: Pacing = .smooth
    @AppStorage("audio") private var audio = true
    @AppStorage("showTouches") private var showTouches = false

    var body: some View {
        Form {
            Section {
                ChoiceCards(selection: $quality, options: [
                    .init("auto", "Auto", "wand.and.stars", "Fits the link"),
                    .init("high", "Max", "sparkles", "Native, 16 Mbps"),
                    .init("balanced", "Balanced", "circle.lefthalf.filled", "1920 px, 8 Mbps"),
                    .init("data", "Saver", "leaf.fill", "1280 px, 3 Mbps"),
                ])
            } header: {
                Text("Quality")
            }

            Section {
                ChoiceCards(selection: $pacing, options: Pacing.allCases.map { .init($0, $0.title, $0.symbol, $0.caption) })
            } header: {
                Text("Motion")
            } footer: {
                Text("Frames keep the phone's own rhythm. The first frame after a touch is always shown right away.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ToggleRow("Play phone audio here", icon: "speaker.wave.2.fill", tint: .pink, isOn: $audio,
                          detail: "Android 11 or later.")
                ToggleRow("Show touches on the phone", icon: "hand.tap.fill", tint: .orange, isOn: $showTouches)
            }

            Section {
                DisclosureGroup("Advanced") {
                    Picker("Codec", selection: $codec) {
                        Text("HEVC").tag("h265")
                        Text("H.264").tag("h264")
                    }
                    .pickerStyle(.segmented)
                    Picker("Frame rate", selection: $maxFps) {
                        Text("Phone's native rate").tag(0)
                        Divider()
                        ForEach([30, 60, 90, 120], id: \.self) { Text("\($0) fps").tag($0) }
                    }
                }
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

extension Pacing {
    var title: String {
        switch self { case .smooth: "Smooth"; case .balanced: "Balanced"; case .immediate: "Instant" }
    }
    var symbol: String {
        switch self { case .smooth: "water.waves"; case .balanced: "dial.medium.fill"; case .immediate: "bolt.fill" }
    }
    var caption: String {
        switch self { case .smooth: "Silkiest motion"; case .balanced: "A bit of both"; case .immediate: "Lowest latency" }
    }
}

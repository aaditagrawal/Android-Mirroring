import AgentProtocol
import AppKit
import MirrorKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(model: model).tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            PictureSettings(model: model).tabItem { Label("Picture", systemImage: "sparkles.tv") }.tag("picture")
            AgentSettings(model: model).tabItem { Label("Agents", systemImage: "wand.and.stars") }.tag("agents")
            ShortcutsHelp().tabItem { Label("Shortcuts", systemImage: "keyboard") }.tag("shortcuts")
        }
        .frame(width: 520, height: 560)
    }
}

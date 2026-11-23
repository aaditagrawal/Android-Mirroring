import MirrorKit
import SwiftUI

struct FavoriteApp: Codable, Hashable {
    let package: String
    let label: String
}

struct FavoriteAppsView: View {
    let model: AppModel
    let phone: PhoneDevice
    @State private var apps: [PhoneApp]?
    @State private var failed = false
    @State private var query = ""
    @State private var favorites: [FavoriteApp]

    init(model: AppModel, phone: PhoneDevice) {
        self.model = model
        self.phone = phone
        _favorites = State(initialValue: model.favoriteApps(on: phone.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Favorites on \(phone.name)").font(.title2.bold())
            Text("Star apps to open them directly from the Android Mirroring menu bar icon.")
                .foregroundStyle(.secondary)
            if let apps {
                TextField("Search apps", text: $query).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search apps")
                let visible = apps.filter { query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) ||
                    $0.package.localizedCaseInsensitiveContains(query) }
                if visible.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "No apps available" : "No matching apps", systemImage: "magnifyingglass")
                } else {
                    List(visible, id: \.package) { app in
                        let starred = favorites.contains { $0.package == app.package }
                        HStack {
                            Text(app.label)
                            Spacer()
                            Button {
                                if starred { favorites.removeAll { $0.package == app.package } }
                                else { favorites.append(FavoriteApp(package: app.package, label: app.label)) }
                                model.setFavoriteApps(favorites, on: phone.id)
                            } label: {
                                Image(systemName: starred ? "star.fill" : "star")
                                    .foregroundStyle(starred ? Color.accentColor : .secondary)
                                    .frame(width: 28, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(starred ? "Remove \(app.label) from Favorites" : "Add \(app.label) to Favorites")
                        }
                    }
                }
            } else if failed {
                ContentUnavailableView {
                    Label("Couldn’t load apps", systemImage: "iphone.slash")
                } description: {
                    Text("Make sure \(phone.name) is connected, then try again.")
                } actions: {
                    Button("Try Again") { Task { await loadApps() } }
                }
            } else {
                ProgressView("Loading apps…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(width: 430, height: 460)
        .task { await loadApps() }
    }

    @MainActor private func loadApps() async {
        failed = false
        guard model.controller.device?.id == phone.id, let currentSerial = model.controller.serial else {
            failed = true
            return
        }
        let adb = model.controller.adb
        let result = await Task.detached(priority: .userInitiated) {
            try? DeviceQueries(adb: adb, serial: currentSerial).listApps()
        }.value
        guard !Task.isCancelled else { return }
        guard let result else { failed = true; return }
        apps = result.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }
}

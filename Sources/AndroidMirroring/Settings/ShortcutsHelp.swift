import AgentProtocol
import AppKit
import MirrorKit
import ServiceManagement
import SwiftUI

// MARK: - Shortcuts

struct ShortcutsHelp: View {
    private let groups: [(String, [([String], String)])] = [
        ("Navigate", [
            (["⌘1"], "Home"), (["⌘2"], "Recent apps"), (["⌘3"], "Notifications"), (["⌘4"], "Quick settings"),
        ]),
        ("Buttons", [(["Esc", "⌘[", "Right-click"], "Back"), (["Middle-click"], "Home")]),
        ("Touch", [
            (["Two-finger scroll"], "Swipe, with fling"), (["Pinch"], "Pinch zoom"), (["⌘", "drag"], "Move the window"),
        ]),
        ("Text", [
            (["⌘C", "⌘X", "⌘V"], "Copy, cut, paste via the phone"), (["⌘A"], "Select all"), (["⌘Z"], "Undo"),
            (["⌥⌫", "⌥←", "⌥→"], "Word by word"),
        ]),
        ("Phone", [
            (["⌘↑", "⌘↓"], "Volume"), (["⌘R"], "Rotate"), (["⌘L"], "Lock"), (["⌘⇧S"], "Screenshot to Desktop"),
            (["⌘0", "⌘+", "⌘−"], "Actual size, bigger, smaller"),
        ]),
        ("Drop", [(["APK"], "Install it"), (["Any file"], "Copy to Downloads")]),
    ]

    var body: some View {
        Form {
            ForEach(groups, id: \.0) { g in
                Section(g.0) {
                    ForEach(Array(g.1.enumerated()), id: \.offset) { _, row in
                        HStack {
                            Text(row.1)
                            Spacer()
                            HStack(spacing: 4) { ForEach(Array(row.0.enumerated()), id: \.offset) { Keycap($0.element) } }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct Keycap: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium, design: .rounded))
            .padding(.horizontal, 7)
            .frame(minWidth: 26, minHeight: 21)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.25), radius: 0, y: 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
    }
}

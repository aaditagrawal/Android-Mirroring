import AgentProtocol
import AppKit
import MirrorKit
import ServiceManagement
import SwiftUI

// MARK: - Building blocks

/// A rounded, colored symbol tile, like System Settings.
struct IconTile: View {
    let icon: String
    let tint: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(tint.gradient))
    }
}

struct IconRow<Trailing: View>: View {
    let title: String
    let icon: String
    let tint: Color
    let detail: String?
    @ViewBuilder let trailing: Trailing

    init(_ title: String, icon: String, tint: Color, detail: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.icon = icon; self.tint = tint; self.detail = detail; self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            IconTile(icon: icon, tint: tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

struct ToggleRow: View {
    let title: String
    let icon: String
    let tint: Color
    @Binding var isOn: Bool
    var detail: String?

    init(_ title: String, icon: String, tint: Color, isOn: Binding<Bool>, detail: String? = nil) {
        self.title = title; self.icon = icon; self.tint = tint; self._isOn = isOn; self.detail = detail
    }

    var body: some View {
        IconRow(title, icon: icon, tint: tint, detail: detail) {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}

/// A row of tappable cards: one per option, with a symbol and a short caption.
struct ChoiceCards<Value: Hashable>: View {
    struct Option {
        let value: Value, title: String, symbol: String, caption: String
        init(_ value: Value, _ title: String, _ symbol: String, _ caption: String) {
            self.value = value; self.title = title; self.symbol = symbol; self.caption = caption
        }
    }

    @Binding var selection: Value
    let options: [Option]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.value) { o in
                let on = o.value == selection
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = o.value }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: o.symbol)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(on ? Color.accentColor : .secondary)
                            .symbolEffect(.bounce, value: on)
                            .frame(height: 22)
                        Text(o.title).font(.callout.weight(.semibold))
                        Text(o.caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(on ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(on ? Color.accentColor : Color.primary.opacity(0.06), lineWidth: on ? 1.5 : 1))
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }
}

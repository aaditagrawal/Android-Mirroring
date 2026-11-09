import AgentProtocol
import AppKit
import MirrorKit
import ServiceManagement
import SwiftUI

// MARK: - Agents

struct AgentSettings: View {
    let model: AppModel
    @AppStorage("agentSnippet") private var kind = "claude"
    @StateObject private var copied = Box(false)

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    IconTile(icon: "wand.and.stars", tint: .purple, size: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Let an agent drive your phone").font(.headline)
                        Text("Agents see the live stream (~10 ms screenshots) and tap through the same fast channel as your mouse. The window doesn't need to be open.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }

            Section {
                Picker("", selection: $kind) {
                    Text("Claude Code").tag("claude")
                    Text("MCP config").tag("mcp")
                    Text("Command line").tag("cli")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: kind) { _, _ in copied.value = false }

                ZStack(alignment: .topTrailing) {
                    Text(snippet)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .padding(.trailing, 60)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(snippet, forType: .string)
                        withAnimation(.snappy) { copied.value = true }
                    } label: {
                        Label(copied.value ? "Copied" : "Copy", systemImage: copied.value ? "checkmark" : "doc.on.doc")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                    .padding(8)
                }
            }

            Section {
                IconRow("droidctl in your terminal", icon: "terminal.fill", tint: .gray) {
                    Button(model.agentCommandPath == model.droidctlPath ? "Install" : "Installed") { installCLI() }
                        .disabled(model.agentCommandPath != model.droidctlPath)
                }
            } footer: {
                Text(AgentAPI.socketPath).font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    private var snippet: String {
        switch kind {
        case "mcp": return model.mcpConfigSnippet
        case "cli":
            let cmd = model.agentCommandPath == model.droidctlPath ? "\"\(model.droidctlPath)\"" : "droidctl"
            return "\(cmd) screenshot -o phone.png\n\(cmd) tap-text \"Settings\"\n\(cmd) text"
        default: return model.claudeCodeCommand
        }
    }

    private func installCLI() {
        let src = model.droidctlPath.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"mkdir -p /usr/local/bin && ln -sf '\(src)' /usr/local/bin/droidctl\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
    }
}

import LookoutCore
import SwiftUI

/// First-launch setup: installs hooks into Claude Code and Codex configs and asks for notification permission.
struct SetupView: View {
    static let size = CGSize(width: 540, height: 400)

    @ObservedObject var model: AppModel
    var close: () -> Void

    @State private var useClaude = true
    @State private var useCodex = true
    @State private var running = false
    @State private var results: [String] = []
    @State private var claudeInstalled = false
    @State private var codexInstalled = false

    private var claudePresent: Bool { FileManager.default.fileExists(atPath: LookoutPaths.home.appendingPathComponent(".claude").path) }
    private var codexPresent: Bool { FileManager.default.fileExists(atPath: LookoutPaths.home.appendingPathComponent(".codex").path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "binoculars.fill").font(.system(size: 30)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up Lookout").font(.title2.weight(.semibold))
                    Text("Lookout watches your agents through their hook systems. Keep launching them however you like.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                agentToggle(
                    isOn: $useClaude, title: "Claude Code", present: claudePresent, installed: claudeInstalled,
                    detail: "Adds hook entries to ~/.claude/settings.json.")
                agentToggle(
                    isOn: $useCodex, title: "Codex", present: codexPresent, installed: codexInstalled,
                    detail: "Adds hook entries to ~/.codex/hooks.json and marks them trusted in ~/.codex/config.toml via Codex itself.")
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            Text("Existing hooks and settings are kept, and a timestamped backup of each file is saved next to it. Agents that are already running pick up the hooks after a restart. Lookout will also ask to send notifications.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(results, id: \.self) { Text($0).font(.callout).lineLimit(2) }
            }
            Spacer(minLength: 0)

            HStack {
                if claudeInstalled || codexInstalled {
                    Button("Remove Hooks", role: .destructive) { uninstall() }.disabled(running)
                }
                Spacer()
                Button(results.isEmpty ? "Later" : "Done") { close() }.keyboardShortcut(.cancelAction)
                Button("Install Hooks") { Task { await install() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running || !(useClaude && claudePresent || useCodex && codexPresent))
            }
        }
        .padding(20)
        .frame(width: Self.size.width, height: Self.size.height)
        .onAppear(perform: refresh)
    }

    @ViewBuilder
    private func agentToggle(isOn: Binding<Bool>, title: String, present: Bool, installed: Bool, detail: String) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.body.weight(.medium))
                    if installed {
                        Label("Installed", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    } else if !present {
                        Text("Not found").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!present)
    }

    private func refresh() {
        claudeInstalled = model.installer.isInstalled(.claude)
        codexInstalled = model.installer.isInstalled(.codex)
        useClaude = claudePresent
        useCodex = codexPresent
    }

    private func install() async {
        running = true
        results = []
        model.installHookBinary()
        let installer = model.installer

        if useClaude && claudePresent {
            do {
                try installer.install(.claude)
                results.append("✅ Claude Code hooks installed")
            } catch {
                results.append("❌ Claude Code: \(error.localizedDescription)")
            }
        }

        if useCodex && codexPresent {
            do {
                try installer.install(.codex)
                let hooksPath = installer.codexHooksURL.path
                let trusted = try await Task.detached {
                    let path = CodexTrust.shellPath()
                    guard let codex = CodexTrust.findCodex(path: path) else { throw CodexTrustError.codexNotFound }
                    return try CodexTrust.trustLookoutHooks(hooksFile: hooksPath, codexPath: codex, path: path)
                }.value
                results.append(trusted > 0 ? "✅ Codex hooks installed and trusted" : "✅ Codex hooks installed (already trusted)")
            } catch {
                results.append("⚠️ Codex: \(error.localizedDescription) Codex will ask you to review the hooks on its next launch.")
            }
        }

        let granted = await Notifier.shared.requestAuthorization()
        results.append(granted ? "✅ Notifications enabled" : "⚠️ Notifications not allowed — enable them in System Settings › Notifications.")
        refresh()
        running = false
    }

    private func uninstall() {
        results = []
        for source in [AgentSource.claude, .codex] where model.installer.isInstalled(source) {
            do {
                try model.installer.uninstall(source)
                results.append("Removed \(source.displayName) hooks")
            } catch {
                results.append("❌ \(source.displayName): \(error.localizedDescription)")
            }
        }
        refresh()
    }
}

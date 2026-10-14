import LookoutCore
import SwiftUI

/// Setup section for ssh hosts: add (installs the helper and hooks on the host), status, remove.
struct RemoteHostsSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var remotes: RemoteHosts

    @State private var newHost = ""
    @State private var busyHost: String?
    @State private var log: [String] = []

    private let configHosts = RemoteSetup.sshConfigHosts()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Remote Hosts").font(.body.weight(.medium))
            Text("Watch agents on servers over ssh. Needs key-based login (no password prompt) and python3 on the server.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(remotes.hosts, id: \.self) { host in
                HStack(spacing: 8) {
                    Circle().fill(color(remotes.states[host])).frame(width: 8, height: 8)
                    Text(host).font(.callout.weight(.medium))
                    Text(label(remotes.states[host])).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if busyHost == host {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Reinstall") { Task { await install(host) } }.controlSize(.small)
                        Button("Remove") { Task { await remove(host) } }.controlSize(.small)
                    }
                }
            }

            HStack {
                TextField("ssh host, e.g. myserver", text: $newHost)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await add() } }
                if !configHosts.isEmpty {
                    Menu {
                        ForEach(configHosts.filter { !remotes.hosts.contains($0) }, id: \.self) { host in
                            Button(host) { newHost = host }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Hosts from ~/.ssh/config")
                }
                Button("Add") { Task { await add() } }
                    .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty || busyHost != nil)
            }

            ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption).lineLimit(2)
            }
        }
    }

    private func add() async {
        let host = newHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        if await install(host) { newHost = "" }
    }

    @discardableResult
    private func install(_ host: String) async -> Bool {
        busyHost = host
        log = ["Installing on \(host)…"]
        defer { busyHost = nil }
        do {
            log = try await RemoteSetup.install(host: host)
            remotes.add(host)
            remotes.connect(host)
            return true
        } catch {
            log = ["❌ \(host): \(error.localizedDescription)"]
            return false
        }
    }

    private func remove(_ host: String) async {
        busyHost = host
        defer { busyHost = nil }
        do {
            try await RemoteSetup.uninstall(host: host)
            log = ["Removed Lookout's hooks from \(host)"]
        } catch {
            log = ["⚠️ Couldn't remove hooks from \(host) (\(error.localizedDescription)). Stopped watching it anyway."]
        }
        model.removeHost(host)
    }

    private func color(_ state: RemoteHosts.State?) -> Color {
        switch state {
        case .connected: .green
        case .connecting, nil: .yellow
        case .failed: .red
        }
    }

    private func label(_ state: RemoteHosts.State?) -> String {
        switch state {
        case .connected: "Connected"
        case .connecting, nil: "Connecting…"
        case .failed(let message): message
        }
    }
}

/// Installs and removes Lookout's helper on ssh hosts.
enum RemoteSetup {
    struct InstallResult: Decodable {
        var home: String
        var installed: [String]
        var errors: [String: String]
        var codexHooksFile: String
    }

    static func install(host: String) async throws -> [String] {
        guard let script = Bundle.main.url(forResource: "remote-lookout-hook", withExtension: nil),
              let data = try? Data(contentsOf: script) else {
            throw SetupError("server helper missing from Lookout.app")
        }
        let output = try await RemoteHosts.run(host, """
            command -v python3 >/dev/null || { echo "python3 is required on the server" >&2; exit 3; }
            umask 077 && mkdir -p ~/.lookout/bin && cat > ~/.lookout/bin/lookout-hook.tmp \
              && chmod 700 ~/.lookout/bin/lookout-hook.tmp \
              && mv ~/.lookout/bin/lookout-hook.tmp ~/.lookout/bin/lookout-hook \
              && ~/.lookout/bin/lookout-hook --install
            """, input: data)
        guard let line = output.split(separator: "\n").last,
              let result = try? JSONDecoder().decode(InstallResult.self, from: Data(line.utf8)) else {
            throw SetupError("unexpected reply from the server: \(output.prefix(200))")
        }

        var lines: [String] = []
        for source in [AgentSource.claude, .codex] {
            if let error = result.errors[source.rawValue] {
                lines.append("❌ \(host): \(source.displayName): \(error)")
            } else if result.installed.contains(source.rawValue) {
                lines.append("✅ \(host): \(source.displayName) hooks installed")
            }
        }
        if result.installed.isEmpty && result.errors.isEmpty {
            lines.append("⚠️ \(host): neither ~/.claude nor ~/.codex exists yet. Run an agent there once, then Reinstall.")
        }
        if result.installed.contains("codex") {
            do {
                let trusted = try await Task.detached {
                    try CodexTrust.trustLookoutHooks(
                        hooksFile: result.codexHooksFile, home: result.home, executable: "/usr/bin/ssh",
                        arguments: RemoteHosts.sshArguments(host, command: codexAppServer))
                }.value
                lines.append(trusted > 0 ? "✅ \(host): Codex hooks trusted" : "✅ \(host): Codex hooks already trusted")
            } catch {
                lines.append("⚠️ \(host): couldn't trust Codex hooks (\(error.localizedDescription)). Codex will ask you to review them on its next launch.")
            }
        }
        return lines
    }

    /// Starts `codex app-server` on the host. Login shells often lack the PATH that `.zshrc`/`.bashrc`
    /// add, so also look in common install folders and the VS Code extension's bundled codex.
    static let codexAppServer = #"""
        exec "$SHELL" -lc 'command -v codex >/dev/null 2>&1 || PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:$PATH"
        command -v codex >/dev/null 2>&1 || { c=$(find "$HOME/.vscode-server/extensions" -path "*/openai.chatgpt-*/bin/*/codex" -type f 2>/dev/null | tail -1); [ -n "$c" ] && PATH="${c%/codex}:$PATH"; }
        exec codex app-server'
        """#

    static func uninstall(host: String) async throws {
        _ = try await RemoteHosts.run(host, "~/.lookout/bin/lookout-hook --uninstall")
    }

    /// Concrete `Host` aliases from ~/.ssh/config (wildcard patterns skipped).
    static func sshConfigHosts() -> [String] {
        let url = LookoutPaths.home.appendingPathComponent(".ssh/config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var hosts: [String] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard parts.first?.lowercased() == "host" else { continue }
            for alias in parts.dropFirst().map(String.init) where !alias.contains(where: { "*?!".contains($0) }) {
                if !hosts.contains(alias) { hosts.append(alias) }
            }
        }
        return hosts
    }
}

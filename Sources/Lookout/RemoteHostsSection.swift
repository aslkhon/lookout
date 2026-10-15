import LookoutCore
import SwiftUI

/// Setup section for ssh hosts: status of each host's helper and hooks, add/reinstall/remove.
struct RemoteHostsSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var remotes: RemoteHosts

    @State private var newHost = ""
    @State private var busyHost: String?
    @State private var messages: [String: [String]] = [:]

    private let configHosts = RemoteSetup.sshConfigHosts()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SectionTitle(title: "Remote hosts")
                Text("One ssh connection per host, nothing listening. Needs key-based login and python3.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            VStack(spacing: 0) {
                ForEach(remotes.hosts, id: \.self) { host in
                    hostRow(host)
                    Divider()
                }
                addRow
                if let lines = messages[""] {
                    messageLines(lines).padding(.horizontal, 14).padding(.bottom, 10)
                }
            }
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.08)))
        }
    }

    private func hostRow(_ host: String) -> some View {
        let state = remotes.states[host]
        let agents = model.sessions.values.filter { $0.host == host && $0.status != .ended }.count
        let failure: (title: String, hint: String?)? = if case .failed(let error) = state {
            Self.explain(error, host: host)
        } else {
            nil
        }
        return HStack(alignment: .center, spacing: 12) {
            Circle().fill(state.color).frame(width: 8, height: 8).frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(host).fontWeight(.semibold)
                    switch state {
                    case .connected: Text("Connected · \(agents) agent\(agents == 1 ? "" : "s")").foregroundStyle(.secondary)
                    case .connecting, nil: Text("Connecting…").foregroundStyle(.secondary)
                    case .failed: Text("Can't connect · \(failure?.title ?? "")").foregroundStyle(.red)
                    }
                }
                .font(.callout)
                .lineLimit(1)
                if let hint = failure?.hint {
                    Text(.init(hint)).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if state == .connected, let hello = remotes.hellos[host] {
                    chips(hello)
                }
                if let lines = messages[host] { messageLines(lines) }
            }
            Spacer(minLength: 8)
            if busyHost == host {
                ProgressView().controlSize(.small)
            } else {
                if failure != nil {
                    Button("Retry") { remotes.connect(host) }
                } else {
                    Button("Reinstall") { Task { await install(host) } }
                }
                Button("Remove") { Task { await remove(host) } }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private func chips(_ hello: RemoteHello) -> some View {
        HStack(spacing: 5) {
            if let hooks = hello.hooks {
                hookChip("Claude Code hooks", installed: hooks["claude"] ?? false)
                hookChip("Codex hooks", installed: hooks["codex"] ?? false)
            }
            if hello.sha256 == RemoteHosts.bundledHelperSHA256 {
                Chip(text: "helper up to date")
            } else {
                Chip(text: "helper updating…")
            }
        }
    }

    private func hookChip(_ title: String, installed: Bool) -> some View {
        installed ? Chip(text: title, style: .success, systemImage: "checkmark")
                  : Chip(text: "no \(title)", systemImage: "minus")
    }

    private var addRow: some View {
        HStack {
            TextField("Add a host from ~/.ssh/config or user@server", text: $newHost)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await add() } }
            if !configHosts.filter({ !remotes.hosts.contains($0) }).isEmpty {
                Menu {
                    ForEach(configHosts.filter { !remotes.hosts.contains($0) }, id: \.self) { host in
                        Button(host) { newHost = host }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Hosts from ~/.ssh/config")
            }
            if busyHost != nil && !remotes.hosts.contains(busyHost ?? "") {
                ProgressView().controlSize(.small)
            }
            Button("Add") { Task { await add() } }
                .buttonStyle(.borderedProminent)
                .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty || busyHost != nil)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private func messageLines(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A short reason and what to do about it, from ssh's last stderr line.
    static func explain(_ error: String, host: String) -> (title: String, hint: String?) {
        let e = error.lowercased()
        if e.contains("permission denied") {
            return ("ssh asked for a password",
                    "Add your key with `ssh-copy-id \(host)`, then retry. Agents there stay hidden until it connects.")
        }
        if e.contains("could not resolve hostname") {
            return ("unknown host", "Check the name, or add it to ~/.ssh/config.")
        }
        if e.contains("host key verification failed") || e.contains("remote host identification has changed") {
            return ("host key changed", "Run `ssh \(host)` in a terminal to review the new key.")
        }
        if e.contains("timed out") || e.contains("connection refused") || e.contains("no route to host")
            || e.contains("network is unreachable") {
            return ("server unreachable", "Lookout keeps retrying in the background.")
        }
        if e.contains("lookout-hook") && e.contains("no such file") {
            return ("helper not installed", "Click Reinstall to set it up again.")
        }
        return (error, nil)
    }

    private func add() async {
        let host = newHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        if await install(host, key: "") { newHost = "" }
    }

    @discardableResult
    private func install(_ host: String, key: String? = nil) async -> Bool {
        let key = key ?? host
        busyHost = host
        messages[key] = ["Installing on \(host)…"]
        defer { busyHost = nil }
        do {
            let lines = try await RemoteSetup.install(host: host)
            remotes.add(host)
            remotes.connect(host)
            messages[key] = nil
            // Only keep lines worth reading: errors and warnings.
            let notable = lines.filter { !$0.hasPrefix("✅") }
            if !notable.isEmpty { messages[host] = notable }
            return true
        } catch {
            messages[key] = ["❌ \(host): \(error.localizedDescription)"]
            return false
        }
    }

    private func remove(_ host: String) async {
        busyHost = host
        defer { busyHost = nil }
        do {
            try await RemoteSetup.uninstall(host: host)
            messages[""] = ["Removed Lookout's hooks from \(host)"]
        } catch {
            messages[""] = ["⚠️ Couldn't remove hooks from \(host) (\(error.localizedDescription)). Stopped watching it anyway."]
        }
        messages[host] = nil
        model.removeHost(host)
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

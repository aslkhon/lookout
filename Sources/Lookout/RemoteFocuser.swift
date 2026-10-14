import AppKit
import Darwin
import LookoutCore

/// Focusing agents that run on ssh hosts.
extension Focuser {
    static func focusRemote(_ session: AgentSession) {
        guard let host = session.host else { return }
        if session.termProgram == "vscode", focusRemoteVSCode(session, host: host) { return }

        // Plain ssh from a terminal: find the local `ssh` process, then the app hosting it.
        guard let ssh = localSSHProcess(clientPort: session.sshClientPort, host: host),
              let app = ProcessInspector.hostBundleID(of: ssh.pid) else { return }
        if app == ghosttyID, let tty = ProcessInspector.tty(ssh), focusGhostty(tty: tty) { return }
        activate(bundleID: app)
    }

    // MARK: VS Code Remote-SSH

    static func focusRemoteVSCode(_ session: AgentSession, host: String) -> Bool {
        let ancestors = session.ancestors ?? session.agentPID.map { [$0] } ?? []
        if let match = VSCodeRegistry.match(host: host, ancestors: ancestors),
           let bundleID = editorBundleID(appRoot: match.window.appRoot) {
            if let terminal = match.terminal { VSCodeRegistry.requestFocus(terminal: terminal, in: match.window) }
            if let folders = match.window.remoteFolders, folders.count == 1 {
                runEditorCLI(bundleID: bundleID, ["--folder-uri", folders[0]])
            } else {
                activate(bundleID: bundleID)
            }
            return true
        }
        // Without the extension: a saved Remote-SSH folder window on this host containing the agent's cwd.
        for (bundleID, support) in vscodeFamily.sorted(by: { $0.key < $1.key })
        where NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil {
            if let uri = savedRemoteFolder(containing: session.cwd, host: host, support: support) {
                runEditorCLI(bundleID: bundleID, ["--folder-uri", uri])
                return true
            }
        }
        return false
    }

    /// `vscode-remote://ssh-remote+<host>/path` of a saved window whose folder contains `cwd`.
    static func savedRemoteFolder(containing cwd: String, host: String, support: String) -> String? {
        savedWindowEntries(support: support)
            .compactMap { $0["folder"] as? String }
            .compactMap { uri -> (String, String)? in
                guard let components = URLComponents(string: uri), components.scheme == "vscode-remote",
                      let authority = components.percentEncodedHost,
                      SSHHost.matches(authority: authority, host: host) else { return nil }
                return (uri, components.path)
            }
            .filter { cwd == $0.1 || cwd.hasPrefix($0.1 + "/") }
            .max { $0.1.count < $1.1.count }?.0
    }

    /// "/Applications/Visual Studio Code.app/Contents/Resources/app" → "com.microsoft.VSCode".
    static func editorBundleID(appRoot: String) -> String? {
        guard let range = appRoot.range(of: ".app/") else { return nil }
        return Bundle(path: String(appRoot[..<range.lowerBound]) + ".app")?.bundleIdentifier
    }

    // MARK: Terminal ssh

    /// The interactive `ssh` process carrying the agent's session: matched by the TCP source port
    /// the server saw (`$SSH_CONNECTION`), else any ssh with a terminal whose arguments name the host.
    static func localSSHProcess(clientPort: Int?, host: String) -> ProcessInspector.Info? {
        let ssh = ProcessInspector.allPIDs().compactMap(ProcessInspector.info).filter { $0.comm == "ssh" }
        if let clientPort, let pid = sshPID(localPort: clientPort, among: ssh.map(\.pid)),
           let info = ssh.first(where: { $0.pid == pid }) {
            return info
        }
        let target = SSHHost.name(host)
        return ssh.first { info in
            ProcessInspector.tty(info) != nil
                && ProcessInspector.arguments(info.pid).dropFirst().contains { SSHHost.name($0) == target }
        }
    }

    /// Which of `pids` has an established TCP connection from `localPort`.
    static func sshPID(localPort: Int, among pids: [pid_t]) -> pid_t? {
        guard !pids.isEmpty else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-p", pids.map(String.init).joined(separator: ","),
                             "-iTCP", "-sTCP:ESTABLISHED", "-Fpn"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        var current: pid_t?
        for line in text.split(separator: "\n") {
            if line.hasPrefix("p") {
                current = pid_t(line.dropFirst())
            } else if line.hasPrefix("n"), let arrow = line.range(of: "->") {
                let local = line[line.index(after: line.startIndex)..<arrow.lowerBound]
                if let colon = local.lastIndex(of: ":"), Int(local[local.index(after: colon)...]) == localPort {
                    return current
                }
            }
        }
        return nil
    }

    /// Ghostty can't say which terminal owns a tty, so tag it: set a unique title through the tty,
    /// find the terminal showing it, put the old title back, and focus that terminal.
    static func focusGhostty(tty: String) -> Bool {
        guard let before = ghosttyTerminals() else { return false }
        let fd = Darwin.open(tty, O_WRONLY | O_NOCTTY)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        func setTitle(_ title: String) {
            let bytes = Array("\u{1b}]2;\(title)\u{07}".utf8)
            _ = Darwin.write(fd, bytes, bytes.count)
        }

        let marker = "lookout-\(UUID().uuidString.prefix(8))"
        setTitle(marker)
        var id: String?
        for _ in 0..<20 where id == nil { // Ghostty applies titles asynchronously
            usleep(100_000)
            id = ghosttyTerminals()?.first { $0.count > 2 && $0[2] == marker }?[0]
        }
        setTitle(before.first { $0.first == id && $0.count > 2 }?[2] ?? "")
        guard let id else { return false }
        return focusGhosttyTerminal(id: id)
    }
}


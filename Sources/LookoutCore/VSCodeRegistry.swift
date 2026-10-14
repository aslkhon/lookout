import Foundation

/// Live window state published by the Lookout VS Code extension (Extensions/vscode).
public enum VSCodeRegistry {
    public struct Window: Decodable, Equatable, Sendable {
        /// Extension host PID; identifies the window.
        public var pid: Int32
        public var appRoot: String
        /// e.g. "ssh-remote+myserver" for Remote-SSH windows (extension ≥ 0.2.0).
        public var remoteAuthority: String?
        /// `vscode-remote://…` folder URIs of a remote window.
        public var remoteFolders: [String]?
        /// Saved `.code-workspace` file; nil for single-folder and untitled multi-root windows.
        public var workspaceFile: String?
        public var folders: [String]
        /// Shell PIDs of the window's integrated terminals.
        public var terminals: [Int32]
    }

    public struct Match: Equatable, Sendable {
        public var window: Window
        /// The terminal's shell PID, when the agent runs in an integrated terminal (not an extension).
        public var terminal: Int32?
    }

    static var windowsDir: URL { LookoutPaths.root.appendingPathComponent("vscode/windows") }
    static var requestsDir: URL { LookoutPaths.root.appendingPathComponent("vscode/requests") }

    /// Windows whose extension host is still running.
    public static func windows() -> [Window] {
        let files = (try? FileManager.default.contentsOfDirectory(at: windowsDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let window = try? JSONDecoder().decode(Window.self, from: data) else { return nil }
            guard ProcessInspector.isAlive(window.pid) else {
                try? FileManager.default.removeItem(at: url) // window closed without cleaning up
                return nil
            }
            return window
        }
    }

    /// The window (and terminal) hosting `agentPID`, found by walking its process ancestors.
    public static func match(agentPID: Int32, windows: [Window] = windows()) -> Match? {
        match(ancestors: ProcessInspector.ancestors(of: agentPID), windows: windows.filter { $0.remoteAuthority == nil })
    }

    /// The Remote-SSH window and terminal hosting an agent on `host`, given the agent's ancestor PIDs
    /// on that host. Windows connected to a different host are ignored, since PIDs only mean
    /// something per machine.
    public static func match(host: String, ancestors: [Int32], windows: [Window] = windows()) -> Match? {
        let remote = windows.filter { window in
            guard let authority = window.remoteAuthority else { return false }
            return SSHHost.matches(authority: authority, host: host)
        }
        return match(ancestors: ancestors, windows: remote)
    }

    static func match(ancestors: [Int32], windows: [Window]) -> Match? {
        for pid in ancestors {
            for window in windows {
                if window.terminals.contains(pid) { return Match(window: window, terminal: pid) }
                if window.pid == pid { return Match(window: window, terminal: nil) } // agent run by an extension
            }
        }
        return nil
    }

    /// Asks the window's extension to reveal the terminal.
    public static func requestFocus(terminal: Int32, in window: Window) {
        let body = Data(#"{"terminal":\#(terminal)}"#.utf8)
        try? FileManager.default.createDirectory(at: requestsDir, withIntermediateDirectories: true)
        try? body.write(to: requestsDir.appendingPathComponent(String(window.pid)), options: .atomic)
    }
}

import AppKit
import LookoutCore

/// Brings the window/terminal hosting an agent to the front.
@MainActor
enum Focuser {
    static let ghosttyID = "com.mitchellh.ghostty"

    /// VS Code–family bundle ids → their Application Support folder name.
    static let vscodeFamily: [String: String] = [
        "com.microsoft.VSCode": "Code",
        "com.microsoft.VSCodeInsiders": "Code - Insiders",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.vscodium": "VSCodium",
    ]

    static func focus(_ session: AgentSession) {
        if session.host != nil { return focusRemote(session) }
        // In tmux: make the pane current, then bring up the terminal showing that tmux client.
        if session.termProgram == "tmux", let tty = session.tty, let client = selectTmuxPane(tty: tty) {
            guard let app = appBundleID(owning: client.pid) ?? session.hostBundleID else { return }
            if !focusTab(bundleID: app, tty: client.tty) { activate(bundleID: app) }
            return
        }
        guard let bundleID = session.hostBundleID else { return }
        if bundleID == ghosttyID, focusGhostty(cwd: session.cwd) { return }
        if let tty = session.tty, focusTab(bundleID: bundleID, tty: tty) { return }
        if let support = vscodeFamily[bundleID] {
            // Exact window and terminal from the Lookout extension, else best guess by folder.
            let match = session.agentPID.flatMap { VSCodeRegistry.match(agentPID: $0) }
            if let match, let terminal = match.terminal {
                VSCodeRegistry.requestFocus(terminal: terminal, in: match.window)
            }
            let window = match.map { vscodeWindow(for: $0.window, support: support) }
                ?? vscodeWindow(containing: session.cwd, support: support)
            switch window {
            case .folder(let folder)?: open(folder: folder, bundleID: bundleID)
            case .workspace(let config)?: openWorkspace(config, bundleID: bundleID)
            case nil: activate(bundleID: bundleID)
            }
            return
        }
        activate(bundleID: bundleID)
    }

    // MARK: Ghostty (AppleScript, Ghostty ≥ 1.3)

    /// Focuses the Ghostty terminal whose working directory matches `cwd`.
    static func focusGhostty(cwd: String) -> Bool {
        guard let terminals = ghosttyTerminals(), let id = pickGhosttyTerminal(terminals, cwd: cwd) else { return false }
        return focusGhosttyTerminal(id: id)
    }

    /// Every Ghostty terminal as [id, working directory, title].
    static func ghosttyTerminals() -> [[String]]? {
        let listScript = """
        set sep to character id 9 -- not `tab`: inside the tell block that names Ghostty's tab class
        tell application id "\(ghosttyID)"
            set out to ""
            repeat with t in terminals
                set wd to ""
                set nm to ""
                try
                    set wd to working directory of t
                end try
                try
                    set nm to name of t
                end try
                set out to out & (id of t) & sep & wd & sep & nm & linefeed
            end repeat
            return out
        end tell
        """
        guard let listing = runAppleScript(listScript) else { return nil }
        return listing.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }

    static func focusGhosttyTerminal(id: String) -> Bool {
        let focusScript = """
        tell application id "\(ghosttyID)"
            repeat with t in terminals
                if id of t is "\(id)" then
                    focus t
                    exit repeat
                end if
            end repeat
            activate
        end tell
        """
        return runAppleScript(focusScript) != nil
    }

    /// Among terminals in `cwd`, prefer one whose title isn't a bare path (i.e. a program like Claude set it).
    static func pickGhosttyTerminal(_ rows: [[String]], cwd: String) -> String? {
        let target = normalize(cwd)
        let matches = rows.filter { $0.count >= 2 && normalize($0[1]) == target }
        let titled = matches.first { row in
            let name = row.count > 2 ? row[2] : ""
            return !name.isEmpty && !name.hasPrefix("/") && !name.hasPrefix("~")
        }
        return (titled ?? matches.first)?.first
    }

    // MARK: VS Code family

    enum VSCodeWindow: Equatable {
        case folder(URL)
        /// Multi-root workspace window, identified by its config file.
        case workspace(URL)
    }

    /// How to bring a window reported by the extension to the front.
    static func vscodeWindow(for window: VSCodeRegistry.Window, support: String) -> VSCodeWindow? {
        if let file = window.workspaceFile { return .workspace(URL(fileURLWithPath: file)) }
        if window.folders.count == 1 { return .folder(URL(fileURLWithPath: window.folders[0])) }
        // Untitled multi-root workspace: the extension can't see its config path, but storage.json can.
        let folders = Set(window.folders.map(normalize))
        guard !folders.isEmpty else { return nil }
        return savedWindows(support: support).first { Set($0.folders.map(normalize)) == folders }?.window
    }

    /// Finds the open window whose folder (or one of whose workspace folders) contains `cwd`.
    static func vscodeWindow(containing cwd: String, support: String) -> VSCodeWindow? {
        let target = normalize(cwd)
        return savedWindows(support: support)
            .flatMap { saved in saved.folders.map { ($0, saved.window) } }
            .filter { let f = normalize($0.0); return target == f || target.hasPrefix(f + "/") }
            .max { $0.0.count < $1.0.count }?.1
    }

    /// Open windows and their local folders, from VS Code's persisted window state. It's written
    /// with a delay, so the Lookout extension's live registry is preferred when available.
    static func savedWindows(support: String) -> [(folders: [String], window: VSCodeWindow)] {
        savedWindowEntries(support: support).compactMap { window in
            if let folder = (window["folder"] as? String).flatMap(URL.init(string:)), folder.isFileURL {
                return ([folder.path], .folder(folder))
            }
            if let ws = window["workspaceIdentifier"] as? [String: Any],
               let config = (ws["configURIPath"] as? String).flatMap(URL.init(string:)), config.isFileURL {
                return (workspaceFolders(config), .workspace(config))
            }
            return nil
        }
    }

    /// Raw `windowsState` entries (open windows plus the last active one) from storage.json.
    static func savedWindowEntries(support: String) -> [[String: Any]] {
        let storage = LookoutPaths.home
            .appendingPathComponent("Library/Application Support/\(support)/User/globalStorage/storage.json")
        guard let data = FileManager.default.contents(atPath: storage.path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = root["windowsState"] as? [String: Any] else { return [] }
        var windows = state["openedWindows"] as? [[String: Any]] ?? []
        if let last = state["lastActiveWindow"] as? [String: Any] { windows.append(last) }
        return windows
    }

    /// Local folder paths listed in a workspace config (JSON with comments; paths may be relative).
    static func workspaceFolders(_ config: URL) -> [String] {
        guard let data = FileManager.default.contents(atPath: config.path),
              let root = try? JSONSerialization.jsonObject(with: data, options: .json5Allowed) as? [String: Any],
              let folders = root["folders"] as? [[String: Any]] else { return [] }
        let base = config.deletingLastPathComponent()
        return folders.compactMap { folder in
            if let path = folder["path"] as? String {
                return path.hasPrefix("/") ? path : base.appendingPathComponent(path).standardizedFileURL.path
            }
            if let uri = (folder["uri"] as? String).flatMap(URL.init(string:)), uri.isFileURL { return uri.path }
            return nil
        }
    }

    /// Opening an already-open folder makes VS Code focus that window.
    static func open(folder: URL, bundleID: String) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.open([folder], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Workspace windows must be opened through the app's own CLI: VS Code treats files opened via
    /// macOS (Finder/NSWorkspace) as plain files, but recognizes workspace configs passed on the
    /// command line, focusing the window that already has the workspace open.
    static func openWorkspace(_ config: URL, bundleID: String) {
        runEditorCLI(bundleID: bundleID, [config.path])
    }

    /// Runs the editor's own CLI against the main app, falling back to activating it.
    static func runEditorCLI(bundleID: String, _ arguments: [String]) {
        guard let cli = VSCodeExtension.cli(bundleID: bundleID) else { return activate(bundleID: bundleID) }
        let process = Process()
        process.executableURL = cli
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["VSCODE_IPC_HOOK_CLI"] = nil // talk to the main app, not a terminal's window
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { activate(bundleID: bundleID) }
    }

    // MARK: Fallback

    static func activate(bundleID: String) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: config)
    }

    // MARK: Helpers

    static func normalize(_ path: String) -> String {
        var p = (path as NSString).expandingTildeInPath
        p = URL(fileURLWithPath: p).resolvingSymlinksInPath().path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error), error == nil else {
            if let error { NSLog("Lookout AppleScript error: \(error)") }
            return nil
        }
        return result.stringValue ?? ""
    }
}

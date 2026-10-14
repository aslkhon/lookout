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
        guard let bundleID = session.hostBundleID else { return }
        if bundleID == ghosttyID, focusGhostty(cwd: session.cwd) { return }
        if let support = vscodeFamily[bundleID], let folder = vscodeWindowFolder(containing: session.cwd, support: support) {
            open(folder: folder, bundleID: bundleID)
            return
        }
        activate(bundleID: bundleID)
    }

    // MARK: Ghostty (AppleScript, Ghostty ≥ 1.3)

    /// Focuses the Ghostty terminal whose working directory matches `cwd`.
    static func focusGhostty(cwd: String) -> Bool {
        let listScript = """
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
                set out to out & (id of t) & tab & wd & tab & nm & linefeed
            end repeat
            return out
        end tell
        """
        guard let listing = runAppleScript(listScript) else { return false }
        let terminals = listing.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        guard let id = pickGhosttyTerminal(terminals, cwd: cwd) else { return false }

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

    /// Finds the open window folder that contains `cwd`, from VS Code's persisted window state.
    static func vscodeWindowFolder(containing cwd: String, support: String) -> URL? {
        let storage = LookoutPaths.home
            .appendingPathComponent("Library/Application Support/\(support)/User/globalStorage/storage.json")
        guard let data = FileManager.default.contents(atPath: storage.path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = root["windowsState"] as? [String: Any] else { return nil }

        var windows = state["openedWindows"] as? [[String: Any]] ?? []
        if let last = state["lastActiveWindow"] as? [String: Any] { windows.append(last) }
        let folders = windows.compactMap { ($0["folder"] as? String).flatMap(URL.init(string:)) }.filter(\.isFileURL)

        let target = normalize(cwd)
        return folders
            .filter { let f = normalize($0.path); return target == f || target.hasPrefix(f + "/") }
            .max { $0.path.count < $1.path.count }
    }

    /// Opening an already-open folder makes VS Code focus that window.
    static func open(folder: URL, bundleID: String) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.open([folder], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
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

    private static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error), error == nil else {
            if let error { NSLog("Lookout AppleScript error: \(error)") }
            return nil
        }
        return result.stringValue ?? ""
    }
}

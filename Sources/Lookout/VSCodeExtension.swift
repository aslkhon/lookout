import AppKit
import LookoutCore

/// Installs the bundled Lookout extension (lookout-vscode.vsix) into VS Code–family editors.
enum VSCodeExtension {
    static let id = "aslkhon.lookout-vscode"
    /// Version of the bundled vsix; scripts/package-vscode.sh checks it against package.json.
    static let version = "0.2.0"

    /// Bundle id → extensions folder (relative to home).
    static let extensionDirs: [String: String] = [
        "com.microsoft.VSCode": ".vscode/extensions",
        "com.microsoft.VSCodeInsiders": ".vscode-insiders/extensions",
        "com.todesktop.230313mzl4w4u92": ".cursor/extensions",
        "com.vscodium": ".vscode-oss/extensions",
    ]

    /// Installed editors, as (display name, bundle id).
    static var editors: [(name: String, bundleID: String)] {
        extensionDirs.keys.sorted().compactMap { id in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            return (url.deletingPathExtension().lastPathComponent, id)
        }
    }

    static func isInstalled(bundleID: String) -> Bool {
        installedFolders(bundleID: bundleID).contains { $0.hasPrefix(id + "-") }
    }

    /// Version of the installed extension, if any.
    static func installedVersion(bundleID: String) -> String? {
        installedFolders(bundleID: bundleID).filter { $0.hasPrefix(id + "-") }
            .map { String($0.dropFirst(id.count + 1)) }
            .max { $0.compare($1, options: .numeric) == .orderedAscending }
    }

    /// Installed, but not the version bundled with this Lookout.
    static func isOutdated(bundleID: String) -> Bool {
        isInstalled(bundleID: bundleID) && !installedFolders(bundleID: bundleID).contains("\(id)-\(version)")
    }

    /// Updates the extension in editors that have an older version, e.g. after Lookout itself updated.
    static func upgradeInstalled() {
        let outdated = editors.filter { isOutdated(bundleID: $0.bundleID) }
        guard !outdated.isEmpty else { return }
        Task.detached {
            for editor in outdated { try? install(bundleID: editor.bundleID) }
        }
    }

    private static func installedFolders(bundleID: String) -> [String] {
        guard let dir = extensionDirs[bundleID] else { return [] }
        let path = LookoutPaths.home.appendingPathComponent(dir).path
        return (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    /// The editor's own command-line tool, e.g. `…/Visual Studio Code.app/Contents/Resources/app/bin/code`.
    static func cli(bundleID: String) -> URL? {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let bin = app.appendingPathComponent("Contents/Resources/app/bin")
        let name = (try? FileManager.default.contentsOfDirectory(atPath: bin.path))?
            .filter { !$0.contains("tunnel") }.sorted().first
        return name.map { bin.appendingPathComponent($0) }
    }

    static func install(bundleID: String) throws {
        guard let vsix = Bundle.main.url(forResource: "lookout-vscode", withExtension: "vsix") else {
            throw SetupError("extension package missing from Lookout.app")
        }
        try run(bundleID: bundleID, ["--install-extension", vsix.path, "--force"])
    }

    static func uninstall(bundleID: String) throws {
        try run(bundleID: bundleID, ["--uninstall-extension", id])
    }

    /// Runs the editor CLI against the main app (not a terminal's window) and waits for it.
    static func run(bundleID: String, _ arguments: [String]) throws {
        guard let cli = cli(bundleID: bundleID) else { throw SetupError("command-line tool not found") }
        let process = Process()
        process.executableURL = cli
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["VSCODE_IPC_HOOK_CLI"] = nil
        process.environment = env
        let stderr = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .split(separator: "\n").last { !$0.contains("DeprecationWarning") && !$0.contains("trace-deprecation") }
            throw SetupError(message.map(String.init) ?? "exit status \(process.terminationStatus)")
        }
    }
}

struct SetupError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

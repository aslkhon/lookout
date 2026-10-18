import Foundation

public enum InstallerError: LocalizedError {
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path): "Could not parse \(path). Fix or move it, then retry."
        }
    }
}

/// Adds/removes Lookout's hook entries in `~/.claude/settings.json` and `~/.codex/hooks.json`.
/// Other hooks in those files are left untouched; a timestamped backup is written before each change.
public struct HookInstaller {
    public static let marker = "lookout-hook"

    static let claudeEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                               "PostToolUseFailure", "PermissionRequest", "Notification", "Stop", "SessionEnd"]
    static let claudeToolEvents: Set<String> = ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest"]
    static let codexEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                              "PermissionRequest", "Stop", "Interrupt", "SessionEnd"]

    public var home: URL
    public var hookBinaryPath: String

    public init(home: URL = LookoutPaths.home, hookBinaryPath: String = LookoutPaths.hookBinary.path) {
        self.home = home
        self.hookBinaryPath = hookBinaryPath
    }

    public var claudeSettingsURL: URL { home.appendingPathComponent(".claude/settings.json") }
    public var codexHooksURL: URL { home.appendingPathComponent(".codex/hooks.json") }

    public func configURL(for source: AgentSource) -> URL {
        source == .claude ? claudeSettingsURL : codexHooksURL
    }

    public func command(for source: AgentSource) -> String {
        "\(hookBinaryPath) \(source.rawValue)"
    }

    // MARK: File operations

    public func isInstalled(_ source: AgentSource) -> Bool {
        guard let root = try? readJSON(configURL(for: source)),
              let hooks = root["hooks"] as? [String: Any] else { return false }
        let cmd = command(for: source)
        return events(for: source).allSatisfy { event in
            Self.commands(in: hooks[event]).contains(cmd)
        }
    }

    var statusLine: StatusLineWrapper { StatusLineWrapper(home: home, hookBinaryPath: hookBinaryPath) }

    /// Reinstalls hooks set up by an older version: one whose PermissionRequest hook timed out
    /// after 10 s, or a Claude install without the status line wrapper.
    public func upgradeInstalled() {
        for source in AgentSource.allCases where isInstalled(source) {
            guard let root = try? readJSON(configURL(for: source)),
                  let hooks = root["hooks"] as? [String: Any],
                  events(for: source).contains("PermissionRequest") else { continue }
            if source == .claude, !statusLine.isInstalled(in: root) { try? install(source); continue }
            let entries = (hooks["PermissionRequest"] as? [Any] ?? []).flatMap {
                (($0 as? [String: Any])?["hooks"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            }
            let timeouts = entries.filter(Self.isLookout).map { $0["timeout"] as? Int }
            if timeouts != [600] { try? install(source) }
        }
    }

    /// Number of Lookout hook entries in the agent's config.
    public func entryCount(_ source: AgentSource) -> Int {
        guard let root = try? readJSON(configURL(for: source)),
              let hooks = root["hooks"] as? [String: Any] else { return 0 }
        return hooks.values.reduce(0) { $0 + Self.commands(in: $1).filter { $0.contains(Self.marker) }.count }
    }

    public func install(_ source: AgentSource) throws {
        let url = configURL(for: source)
        var root = try readJSON(url)
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        root["hooks"] = Self.addingLookout(to: hooks, events: events(for: source), command: command(for: source),
                                           matcherEvents: source == .claude ? Self.claudeToolEvents : [])
        if source == .claude { root = try statusLine.installing(into: root) } // for plan limits
        try writeJSON(root, to: url)
    }

    public func uninstall(_ source: AgentSource) throws {
        let url = configURL(for: source)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var root = try readJSON(url)
        if source == .claude { root = statusLine.removing(from: root) }
        guard let hooks = root["hooks"] as? [String: Any] else { try writeJSON(root, to: url); return }
        let cleaned = Self.removingLookout(from: hooks)
        root["hooks"] = cleaned.isEmpty ? nil : cleaned
        try writeJSON(root, to: url)
    }

    func events(for source: AgentSource) -> [String] {
        source == .claude ? Self.claudeEvents : Self.codexEvents
    }

    // MARK: Pure transforms

    /// Returns `hooks` with exactly one Lookout entry per event (any previous Lookout entries are replaced).
    static func addingLookout(to hooks: [String: Any], events: [String], command: String,
                              matcherEvents: Set<String>) -> [String: Any] {
        var result = removingLookout(from: hooks)
        for event in events {
            // A permission request waits up to 590 s for an answer from Lookout.
            let timeout = event == "PermissionRequest" ? 600 : 10
            var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": timeout]]]
            if matcherEvents.contains(event) { group["matcher"] = "*" }
            result[event] = (result[event] as? [Any] ?? []) + [group]
        }
        return result
    }

    /// Strips every hook whose command references `lookout-hook`, dropping groups/events left empty.
    static func removingLookout(from hooks: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { result[event] = value; continue }
            let kept: [Any] = groups.compactMap { item in
                guard var group = item as? [String: Any], let entries = group["hooks"] as? [Any] else { return item }
                let remaining = entries.filter { !isLookout($0) }
                if remaining.isEmpty && !entries.isEmpty { return nil }
                group["hooks"] = remaining
                return group
            }
            if !kept.isEmpty { result[event] = kept }
        }
        return result
    }

    static func isLookout(_ entry: Any) -> Bool {
        ((entry as? [String: Any])?["command"] as? String)?.contains(marker) ?? false
    }

    static func commands(in eventValue: Any?) -> [String] {
        (eventValue as? [Any] ?? []).flatMap { group -> [String] in
            ((group as? [String: Any])?["hooks"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["command"] as? String }
        }
    }

    // MARK: JSON IO

    func readJSON(_ url: URL) throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [:] }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallerError.unreadable(url.path)
        }
        return obj
    }

    func writeJSON(_ obj: [String: Any], to url: URL) throws {
        let url = url.resolvingSymlinksInPath() // keep dotfile symlinks intact
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).lookout-backup-\(stamp)")
            try? fm.copyItem(at: url, to: backup)
        }
        var data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }
}

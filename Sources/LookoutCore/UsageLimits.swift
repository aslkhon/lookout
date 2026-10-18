import Foundation

/// One rate-limit window of an agent's plan: how much of it is used and when it resets.
public struct UsageLimit: Codable, Equatable, Sendable {
    public var windowMinutes: Int
    public var usedPercent: Double
    public var resetsAt: Date

    public init(windowMinutes: Int, usedPercent: Double, resetsAt: Date) {
        self.windowMinutes = windowMinutes
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    /// "5h", "Week", or the window in hours.
    public var name: String {
        switch windowMinutes {
        case 300: "5h"
        case 10080: "Week"
        default: "\(windowMinutes / 60)h"
        }
    }

    /// A window that has reset since it was read starts from zero.
    public func current(now: Date = Date()) -> UsageLimit {
        guard now >= resetsAt else { return self }
        let window = TimeInterval(windowMinutes * 60)
        let passed = (now.timeIntervalSince(resetsAt) / window).rounded(.down) + 1
        return UsageLimit(windowMinutes: windowMinutes, usedPercent: 0, resetsAt: resetsAt + passed * window)
    }
}

/// Plan limits. Claude Code hands them only to the status line command, so Lookout wraps that
/// command (see `StatusLineWrapper`) and saves them; Codex writes them into its session files.
public enum UsageLimits {
    public static var claudeFile: URL { LookoutPaths.root.appendingPathComponent("claude-limits.json") }

    /// From Claude Code's status line input: `rate_limits.five_hour` and `.seven_day`.
    public static func claude(statusLine input: [String: Any]) -> [UsageLimit] {
        guard let limits = input["rate_limits"] as? [String: Any] else { return [] }
        return [("five_hour", 300), ("seven_day", 10080)].compactMap { key, minutes in
            guard let window = limits[key] as? [String: Any],
                  let used = (window["used_percentage"] as? NSNumber)?.doubleValue,
                  let reset = (window["resets_at"] as? NSNumber)?.doubleValue else { return nil }
            return UsageLimit(windowMinutes: minutes, usedPercent: used, resetsAt: Date(timeIntervalSince1970: reset))
        }
    }

    /// From a Codex rollout's `token_count` event: `payload.rate_limits.primary` and `.secondary`.
    public static func codex(rolloutLine line: Data) -> [UsageLimit]? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              let limits = payload["rate_limits"] as? [String: Any] else { return nil }
        return ["primary", "secondary"].compactMap { key in
            guard let window = limits[key] as? [String: Any],
                  let minutes = (window["window_minutes"] as? NSNumber)?.intValue,
                  let used = (window["used_percent"] as? NSNumber)?.doubleValue,
                  let reset = (window["resets_at"] as? NSNumber)?.doubleValue else { return nil }
            return UsageLimit(windowMinutes: minutes, usedPercent: used, resetsAt: Date(timeIntervalSince1970: reset))
        }
        .sorted { $0.windowMinutes < $1.windowMinutes }
    }

    public static func loadClaude(from url: URL = claudeFile) -> [UsageLimit] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        return (try? JSONDecoder().decode([UsageLimit].self, from: data)) ?? []
    }

    /// The newest limits in the most recently written Codex session, reading only the file's tail.
    public static func loadCodex(home: URL = LookoutPaths.home, tail: Int = 256 << 10) -> [UsageLimit] {
        let root = home.appendingPathComponent(".codex/sessions")
        let fm = FileManager.default
        // Sessions sit in year/month/day folders; only the newest day folders need looking at.
        func newest(_ url: URL, _ count: Int) -> [URL] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(count).map { $0 }
        }
        let days = newest(root, 1).flatMap { newest($0, 2) }.flatMap { newest($0, 3) }
        let files = days.flatMap { newest($0, .max) }.filter { $0.pathExtension == "jsonl" }
            .compactMap { url in
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { (url, $0) }
            }
            .sorted { $0.1 > $1.1 }
        for (url, _) in files.prefix(5) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let end = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: end > UInt64(tail) ? end - UInt64(tail) : 0)
            guard let data = try? handle.readToEnd() else { continue }
            let marker = Data("\"rate_limits\"".utf8)
            for line in data.split(separator: UInt8(ascii: "\n")).reversed() where line.range(of: marker) != nil {
                if let limits = codex(rolloutLine: Data(line)), !limits.isEmpty { return limits }
            }
        }
        return []
    }
}

/// Puts `lookout-hook statusline` in front of the user's Claude status line command. The original
/// `statusLine` setting is kept in `~/.lookout/statusline.json`; the wrapper runs it unchanged.
public struct StatusLineWrapper {
    public var home: URL
    public var hookBinaryPath: String

    public init(home: URL = LookoutPaths.home, hookBinaryPath: String = LookoutPaths.hookBinary.path) {
        self.home = home
        self.hookBinaryPath = hookBinaryPath
    }

    public var command: String { "\(hookBinaryPath) statusline" }
    public var originalURL: URL { home.appendingPathComponent(".lookout/statusline.json") }

    /// The wrapped command, or nil when there was none.
    public static func originalCommand(at url: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: url.path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["command"] as? String
    }

    public func isInstalled(in settings: [String: Any]) -> Bool {
        (settings["statusLine"] as? [String: Any])?["command"] as? String == command
    }

    /// Settings with the wrapper in place; saves the original status line first.
    public func installing(into settings: [String: Any]) throws -> [String: Any] {
        guard !isInstalled(in: settings) else { return settings }
        let original = settings["statusLine"] as? [String: Any] ?? [:]
        try FileManager.default.createDirectory(at: originalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: original, options: [.prettyPrinted, .sortedKeys]).write(to: originalURL)
        var result = settings
        var line = original
        line["type"] = "command"
        line["command"] = command
        result["statusLine"] = line
        return result
    }

    /// Settings with the original status line back.
    public func removing(from settings: [String: Any]) -> [String: Any] {
        guard isInstalled(in: settings) else { return settings }
        var result = settings
        let data = FileManager.default.contents(atPath: originalURL.path) ?? Data()
        let original = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        result["statusLine"] = original.isEmpty ? nil : original
        try? FileManager.default.removeItem(at: originalURL)
        return result
    }
}

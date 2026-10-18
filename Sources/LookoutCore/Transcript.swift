import Foundation

/// One line of an agent's conversation: a prompt, a reply or a tool call.
public struct TranscriptEntry: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case user, assistant, tool }

    public var id: Int
    public var kind: Kind
    public var text: String
    public var date: Date?
}

/// Reads the recent conversation from the files Claude Code and Codex keep on disk:
/// `~/.claude/projects/<dir>/<session>.jsonl` and `~/.codex/sessions/<date>/rollout-…<session>….jsonl`.
public enum Transcript {
    /// The transcript file of a session on this Mac, if it can be found.
    public static func url(for session: AgentSession, home: URL = LookoutPaths.home) -> URL? {
        guard session.host == nil else { return nil }
        let fm = FileManager.default
        switch session.source {
        case .claude:
            let projects = home.appendingPathComponent(".claude/projects")
            let dirs = (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
            return dirs.lazy.map { $0.appendingPathComponent("\(session.sessionID).jsonl") }
                .first { fm.fileExists(atPath: $0.path) }
        case .codex:
            let root = home.appendingPathComponent(".codex/sessions")
            let files = (fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])?
                .compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "jsonl" }
            guard session.sessionID.hasPrefix("pid:") else {
                return files.first { $0.lastPathComponent.contains(session.sessionID) }
            }
            // No hook yet, so no thread id: the rollout Codex holds open, or else the newest one
            // for the same folder written while this process was running.
            if let open = session.agentPID.flatMap(openRollout) { return open }
            guard let started = session.startedAt else { return nil }
            return files
                .compactMap { url in modified(url).map { (url, $0) } }
                .filter { $0.1 >= started }
                .sorted { $0.1 > $1.1 }
                .first { rolloutCwd($0.0) == session.cwd }?.0
        }
    }

    /// The last `limit` entries of a transcript. Reads backwards a chunk at a time, up to `maxBytes`,
    /// since lines holding screenshots or long tool output can be megabytes each; those are skipped.
    /// Entry ids come from each line's byte offset, so they stay the same as the file grows.
    public static func load(_ url: URL, source: AgentSource, limit: Int = 40,
                            chunk: Int = 1 << 20, maxBytes: Int = 32 << 20, maxLine: Int = 256 << 10) -> [TranscriptEntry] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        var offset = (try? handle.seekToEnd()) ?? 0
        var newestFirst: [[TranscriptEntry]] = []
        var count = 0
        var read = 0
        var partial = Data() // the start of a line that began before the chunk read last
        while offset > 0, read < maxBytes, count < limit {
            let size = min(UInt64(chunk), offset)
            offset -= size
            try? handle.seek(toOffset: offset)
            guard let data = try? handle.read(upToCount: Int(size)) else { break }
            read += data.count
            let joined = data + partial
            var parts = joined.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            partial = offset > 0 ? Data(parts.removeFirst()) : Data()
            for part in parts.reversed() where !part.isEmpty && part.count <= maxLine {
                let line = Int(offset) + part.startIndex - joined.startIndex
                let found = entries(in: Data(part), source: source).prefix(64).enumerated().map { i, e in // ids are offset * 64 + i
                    TranscriptEntry(id: line * 64 + i, kind: e.kind, text: e.text, date: e.date)
                }
                count += found.count
                newestFirst.append(found)
            }
        }
        return Array(newestFirst.reversed().flatMap { $0 }.suffix(limit))
    }

    /// The output of `lookout-hook --transcript` on an ssh host: "<byte offset>\t<json>" lines.
    public static func parseRemote(_ output: Data, source: AgentSource, limit: Int = 40) -> [TranscriptEntry] {
        let found = output.split(separator: UInt8(ascii: "\n")).flatMap { line -> [TranscriptEntry] in
            guard let tab = line.firstIndex(of: UInt8(ascii: "\t")),
                  let offset = Int(String(decoding: line[..<tab], as: UTF8.self)),
                  (0..<Int.max / 64).contains(offset) else { return [] } // the host's output isn't trusted
            return entries(in: Data(line[line.index(after: tab)...]), source: source).prefix(64).enumerated().map { i, e in
                TranscriptEntry(id: offset * 64 + i, kind: e.kind, text: e.text, date: e.date)
            }
        }
        return Array(found.suffix(limit))
    }

    /// The "usage\t<json>" line `lookout-hook --transcript` ends with, if the host's helper is new enough.
    public static func parseRemoteUsage(_ output: Data) -> TokenUsage? {
        let prefix = Data("usage\t".utf8)
        guard let line = output.split(separator: UInt8(ascii: "\n")).last(where: { $0.starts(with: prefix) }),
              let object = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(prefix.count))) as? [String: Any]
        else { return nil }
        let count = { (key: String) in max(0, object[key] as? Int ?? 0) } // the host's output isn't trusted
        return TokenUsage(input: count("input"), cacheRead: count("cache_read"), cacheWrite: count("cache_write"), output: count("output"))
    }

    public static func parse(_ lines: [Data], source: AgentSource) -> [TranscriptEntry] {
        lines.flatMap { entries(in: $0, source: source) }
            .enumerated().map { TranscriptEntry(id: $0.offset, kind: $0.element.kind, text: $0.element.text, date: $0.element.date) }
    }

    private typealias Found = (kind: TranscriptEntry.Kind, text: String, date: Date?)

    private static func entries(in line: Data, source: AgentSource) -> [Found] {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return [] }
        let date = (object["timestamp"] as? String).flatMap(parseDate)
        return (source == .claude ? claudeEntries(object) : codexEntries(object)).compactMap { kind, text in
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : (kind, String(text.prefix(4000)), date)
        }
    }

    // MARK: Claude Code

    private static func claudeEntries(_ object: [String: Any]) -> [(TranscriptEntry.Kind, String)] {
        guard let type = object["type"] as? String, type == "user" || type == "assistant",
              object["isMeta"] as? Bool != true, object["isSidechain"] as? Bool != true,
              let message = object["message"] as? [String: Any] else { return [] }
        if let text = message["content"] as? String {
            return type == "user" && isInjected(text) ? [] : [(type == "user" ? .user : .assistant, text)]
        }
        let blocks = message["content"] as? [[String: Any]] ?? []
        return blocks.compactMap { block in
            switch block["type"] as? String {
            case "text":
                guard let text = block["text"] as? String, !(type == "user" && isInjected(text)) else { return nil }
                return (type == "user" ? .user : .assistant, text)
            case "tool_use":
                guard let name = block["name"] as? String else { return nil }
                return (.tool, toolSummary(name, block["input"] as? [String: Any] ?? [:]))
            default:
                return nil // thinking, tool results, images
            }
        }
    }

    /// Text Claude Code adds to the user's turn: command output, reminders, task notifications.
    private static func isInjected(_ text: String) -> Bool {
        text.hasPrefix("<") || text.hasPrefix("Caveat:")
    }

    // MARK: Codex

    private static func codexEntries(_ object: [String: Any]) -> [(TranscriptEntry.Kind, String)] {
        guard object["type"] as? String == "event_msg", let payload = object["payload"] as? [String: Any] else { return [] }
        switch payload["type"] as? String {
        case "user_message": // older rollouts
            return (payload["message"] as? String).map { [(.user, $0)] } ?? []
        case "agent_message":
            return (payload["message"] as? String).map { [(.assistant, $0)] } ?? []
        case "item_completed":
            guard let item = payload["item"] as? [String: Any] else { return [] }
            switch item["type"] as? String {
            case "UserMessage": return [(.user, texts(item))]
            case "AgentMessage": return [(.assistant, texts(item))]
            case "CommandExecution":
                let parsed = (item["parsed_cmd"] as? [[String: Any]])?.first?["cmd"] as? String
                let command = parsed ?? (item["command"] as? [String])?.last ?? ""
                return [(.tool, "Bash: \(command)")]
            case "FileChange":
                let paths = (item["changes"] as? [String: Any])?.keys.map { ($0 as NSString).lastPathComponent }.sorted() ?? []
                return [(.tool, "Edit: \(paths.joined(separator: ", "))")]
            default: return []
            }
        default:
            return []
        }
    }

    private static func texts(_ item: [String: Any]) -> String {
        (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// The rollout file a running Codex process has open.
    private static func openRollout(pid: Int32) -> URL? {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-p", String(pid), "-Fn"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = FileHandle.nullDevice
        guard (try? lsof.run()) != nil else { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        lsof.waitUntilExit()
        return output.split(separator: "\n")
            .first { $0.hasPrefix("n") && $0.contains("/.codex/sessions/") && $0.hasSuffix(".jsonl") }
            .map { URL(fileURLWithPath: String($0.dropFirst())) }
    }

    // MARK: Helpers

    private static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// The working directory in a rollout's first line (`session_meta`).
    private static func rolloutCwd(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 256 << 10),
              let line = head.split(separator: UInt8(ascii: "\n")).first,
              let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return nil }
        return payload["cwd"] as? String
    }

    /// "Bash: npm test", "Read: Sources/App.swift"; same keys as the hook's tool summary.
    static func toolSummary(_ name: String, _ input: [String: Any]) -> String {
        for key in ["command", "file_path", "path", "url", "pattern", "description"] {
            if let value = input[key] as? String, !value.isEmpty {
                let short = key == "file_path" || key == "path" ? (value as NSString).lastPathComponent : value
                return "\(name): \(short)"
            }
        }
        return name
    }

    private static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

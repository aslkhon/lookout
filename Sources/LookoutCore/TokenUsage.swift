import Foundation

/// Tokens an agent's session has used, from its transcript.
public struct TokenUsage: Equatable, Sendable {
    /// Uncached input.
    public var input = 0
    public var cacheRead = 0
    public var cacheWrite = 0
    public var output = 0

    public init(input: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, output: Int = 0) {
        self.input = input; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite; self.output = output
    }

    public var total: Int { input + cacheRead + cacheWrite + output }

    /// "17.2M tokens · 97% cached · 84k out".
    public var summary: String {
        let prompt = input + cacheRead + cacheWrite
        var parts = ["\(Self.short(total)) tokens"]
        if prompt > 0, cacheRead > 0 { parts.append("\(cacheRead * 100 / prompt)% cached") }
        parts.append("\(Self.short(output)) out")
        return parts.joined(separator: " · ")
    }

    /// "950", "84k", "17.2M".
    public static func short(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        if n < 1_000_000 { return "\(n / 1000)k" }
        return String(format: "%.1fM", Double(n) / 1_000_000)
    }

    /// Takes in one transcript line. Claude: an assistant message's usage, once per message (each content
    /// block's line repeats it, one after another). Codex: `token_count` events carry running totals.
    mutating func add(line: Data, source: AgentSource, lastID: inout String?) {
        let markers = source == .claude ? Self.claudeMarkers : Self.codexMarkers
        guard markers.allSatisfy({ line.range(of: $0) != nil }), // most lines have no usage; skip parsing them
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        switch source {
        case .claude:
            guard object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { return }
            let id = message["id"] as? String
            if id != nil, id == lastID { return }
            lastID = id
            input += usage["input_tokens"] as? Int ?? 0
            cacheRead += usage["cache_read_input_tokens"] as? Int ?? 0
            cacheWrite += usage["cache_creation_input_tokens"] as? Int ?? 0
            output += usage["output_tokens"] as? Int ?? 0
        case .codex:
            guard let payload = object["payload"] as? [String: Any], payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let usage = info["total_token_usage"] as? [String: Any] else { return }
            let cached = usage["cached_input_tokens"] as? Int ?? 0
            self = TokenUsage(input: max(0, (usage["input_tokens"] as? Int ?? 0) - cached), cacheRead: cached,
                              cacheWrite: usage["cache_write_input_tokens"] as? Int ?? 0,
                              output: usage["output_tokens"] as? Int ?? 0)
        }
    }

    private static let claudeMarkers = [Data(#""type":"assistant""#.utf8), Data(#""usage""#.utf8)]
    private static let codexMarkers = [Data(#""token_count""#.utf8)]
}

/// Running token totals per transcript file; each call reads only what was appended since the last.
public actor TokenTally {
    private var files: [URL: (offset: UInt64, usage: TokenUsage, lastID: String?)] = [:]

    public init() {}

    public func usage(of url: URL, source: AgentSource) -> TokenUsage {
        var state = files[url] ?? (0, TokenUsage(), nil)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return state.usage }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        if end < state.offset { state = (0, TokenUsage(), nil) } // rewritten
        try? handle.seek(toOffset: state.offset)
        while state.offset < end, let data = try? handle.read(upToCount: 4 << 20), !data.isEmpty {
            // Whole lines only: the last one may still be being written.
            guard let last = data.lastIndex(of: UInt8(ascii: "\n")) else { break }
            for line in data[...last].split(separator: UInt8(ascii: "\n")) {
                state.usage.add(line: Data(line), source: source, lastID: &state.lastID)
            }
            state.offset += UInt64(last - data.startIndex + 1)
            try? handle.seek(toOffset: state.offset)
        }
        files[url] = state
        return state.usage
    }
}

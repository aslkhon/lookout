import Foundation

/// Tokens an agent's session has used, from its transcript.
public struct TokenUsage: Equatable, Sendable {
    /// Uncached input.
    public var input = 0
    public var cacheRead = 0
    public var cacheWrite = 0
    public var output = 0
    /// Estimated API cost in USD; nil once a model without a known price shows up.
    public var cost: Double? = 0
    /// Codex's model, from its `turn_context` lines; its token counts are priced with it.
    var codexModel: String?

    public init(input: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, output: Int = 0, cost: Double? = 0) {
        self.input = input; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite; self.output = output
        self.cost = cost
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

    /// "950", "84k", "17.2M", "2.1B".
    public static func short(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        if n < 1_000_000 { return "\(n / 1000)k" }
        if n < 1_000_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        return String(format: "%.1fB", Double(n) / 1_000_000_000)
    }

    /// Takes in one transcript line. Claude: an assistant message's usage, once per message (each content
    /// block's line repeats it, one after another). Codex: `token_count` events carry running totals.
    mutating func add(line: Data, source: AgentSource, lastID: inout String?) {
        guard source == .claude || source == .codex else { return } // the others' transcripts aren't read
        // Most lines have no usage; skip parsing them.
        let wanted = source == .claude ? Self.claudeMarkers.allSatisfy { line.range(of: $0) != nil }
            : Self.codexMarkers.contains { line.range(of: $0) != nil }
        guard wanted, let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        switch source {
        case .claude:
            guard object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { return }
            let id = message["id"] as? String
            if id != nil, id == lastID { return }
            lastID = id
            let tokens = Self.claudeTokens(usage)
            input += tokens.input
            cacheRead += tokens.cacheRead
            cacheWrite += tokens.cacheWrite5m + tokens.cacheWrite1h
            output += tokens.output
            let model = message["model"] as? String ?? ""
            if model == "<synthetic>" { return } // Claude Code's own placeholder replies, no API call
            cost = cost.flatMap { total in Pricing.cost(model: model, tokens).map { total + $0 } }
        case .codex:
            guard let payload = object["payload"] as? [String: Any] else { return }
            if object["type"] as? String == "turn_context" { codexModel = payload["model"] as? String; return }
            guard payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let usage = info["total_token_usage"] as? [String: Any] else { return }
            let cached = usage["cached_input_tokens"] as? Int ?? 0
            let model = codexModel
            self = TokenUsage(input: max(0, (usage["input_tokens"] as? Int ?? 0) - cached), cacheRead: cached,
                              cacheWrite: usage["cache_write_input_tokens"] as? Int ?? 0,
                              output: usage["output_tokens"] as? Int ?? 0)
            codexModel = model
            cost = model.flatMap { Pricing.cost(model: $0, ModelTokens(input: input, cacheWrite5m: cacheWrite, cacheRead: cacheRead, output: output)) }
        case .gemini, .opencode:
            break
        }
    }

    /// An assistant message's tokens; cache writes without a 5m/1h split count as 5-minute ones.
    static func claudeTokens(_ usage: [String: Any]) -> ModelTokens {
        let written = usage["cache_creation_input_tokens"] as? Int ?? 0
        let split = usage["cache_creation"] as? [String: Any]
        let hour = min(written, split?["ephemeral_1h_input_tokens"] as? Int ?? 0)
        return ModelTokens(input: usage["input_tokens"] as? Int ?? 0, cacheWrite5m: written - hour, cacheWrite1h: hour,
                           cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0, output: usage["output_tokens"] as? Int ?? 0)
    }

    private static let claudeMarkers = [Data(#""type":"assistant""#.utf8), Data(#""usage""#.utf8)]
    private static let codexMarkers = [Data(#""token_count""#.utf8), Data(#""turn_context""#.utf8)]
}

/// Running token totals per transcript file; each call reads only what was appended since the last.
public actor TokenTally {
    private var files: [URL: (offset: UInt64, usage: TokenUsage, lastID: String?)] = [:]
    private let chunk: Int

    public init(chunk: Int = 4 << 20) {
        self.chunk = chunk
    }

    public func usage(of url: URL, source: AgentSource) -> TokenUsage {
        var state = files[url] ?? (0, TokenUsage(), nil)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return state.usage }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        if end < state.offset { state = (0, TokenUsage(), nil) } // rewritten
        try? handle.seek(toOffset: state.offset)
        while state.offset < end, let data = try? handle.read(upToCount: chunk), !data.isEmpty {
            // Whole lines only: the last one may still be being written.
            guard let last = data.lastIndex(of: UInt8(ascii: "\n")) else {
                // A line longer than a chunk (a screenshot) holds no usage: skip past it, or stop
                // if it's still being written.
                guard data.count == chunk, let next = nextLine(handle) else { break }
                state.offset = next
                try? handle.seek(toOffset: state.offset)
                continue
            }
            for line in data[...last].split(separator: UInt8(ascii: "\n")) {
                state.usage.add(line: Data(line), source: source, lastID: &state.lastID)
            }
            state.offset += UInt64(last - data.startIndex + 1)
            try? handle.seek(toOffset: state.offset)
        }
        files[url] = state
        return state.usage
    }

    /// The offset just after the next line break, reading on from the handle's position.
    private func nextLine(_ handle: FileHandle) -> UInt64? {
        while let data = try? handle.read(upToCount: chunk), !data.isEmpty {
            if let i = data.firstIndex(of: UInt8(ascii: "\n")) {
                return (try? handle.offset()).map { $0 - UInt64(data.endIndex - i - 1) }
            }
        }
        return nil
    }
}

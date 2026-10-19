import Foundation

/// One agent's tokens and estimated API cost on one day.
public struct DayUsage: Codable, Equatable, Sendable {
    public var tokens = 0
    /// Of the tokens with a known price.
    public var cost = 0.0
    /// Tokens of models without a known price, so not in `cost`.
    public var unpriced = 0

    public init(tokens: Int = 0, cost: Double = 0, unpriced: Int = 0) {
        self.tokens = tokens; self.cost = cost; self.unpriced = unpriced
    }

    public static func + (a: DayUsage, b: DayUsage) -> DayUsage {
        DayUsage(tokens: a.tokens + b.tokens, cost: a.cost + b.cost, unpriced: a.unpriced + b.unpriced)
    }
}

/// Tokens and cost per day and agent, from every Claude Code and Codex transcript on this Mac (subagents'
/// too). Each line's usage goes to the day of its timestamp. Totals per file are kept in
/// ~/.lookout/usage-days.json, so only files that changed are read again.
public enum UsageHistory {
    public static var cacheURL: URL { LookoutPaths.root.appendingPathComponent("usage-days.json") }

    /// "2026-10-19" → agent → usage, local days.
    public typealias Days = [String: [AgentSource: DayUsage]]

    struct FileEntry: Codable {
        var size: UInt64
        var modified: Date
        var source: AgentSource
        var days: [String: DayUsage]
    }

    /// Days from `since` on. Reads changed transcripts, so call it off the main thread.
    public static func load(since: Date, home: URL = LookoutPaths.home, cache: URL = cacheURL) -> Days {
        var entries = (try? Data(contentsOf: cache)).flatMap { try? JSONDecoder().decode([String: FileEntry].self, from: $0) } ?? [:]
        var seen: Set<String> = []
        let roots: [(AgentSource, URL)] = [(.claude, home.appendingPathComponent(".claude/projects")),
                                           (.codex, home.appendingPathComponent(".codex/sessions"))]
        var changed = false
        for (source, root) in roots {
            let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys)?.compactMap { $0 as? URL } ?? []
            for url in files {
                guard url.pathExtension == "jsonl", let values = try? url.resourceValues(forKeys: Set(keys)),
                      let modified = values.contentModificationDate, modified >= since else { continue }
                let size = UInt64(values.fileSize ?? 0)
                seen.insert(url.path)
                if let entry = entries[url.path], entry.size == size, entry.modified == modified { continue }
                entries[url.path] = FileEntry(size: size, modified: modified, source: source, days: scan(url, source: source))
                changed = true
            }
        }
        // Files older than the period aren't looked at, but keep them for a longer period later.
        let stale = entries.keys.filter { !seen.contains($0) && !FileManager.default.fileExists(atPath: $0) }
        for path in stale { entries[path] = nil }
        if changed || !stale.isEmpty, let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: cache, options: .atomic)
        }
        let first = dayString(since)
        var days: Days = [:]
        for entry in entries.values {
            for (day, usage) in entry.days where day >= first {
                days[day, default: [:]][entry.source, default: DayUsage()] = days[day]?[entry.source].map { $0 + usage } ?? usage
            }
        }
        return days
    }

    /// One transcript's usage per day.
    static func scan(_ url: URL, source: AgentSource) -> [String: DayUsage] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? handle.close() }
        var days: [String: DayUsage] = [:]
        var usage = TokenUsage()
        var lastID: String?
        var codexCost: Double? = 0
        var partial = Data()
        func take(_ line: Data) {
            let before = usage.total
            if source == .claude { usage.cost = 0 } // so it's this line's cost, or nil for an unknown model
            usage.add(line: line, source: source, lastID: &lastID)
            let tokens = usage.total - before
            guard tokens > 0, let day = timestamp(line).map(dayString) else { return }
            var cost = usage.cost
            if source == .codex { // running totals: the change since the last count
                cost = usage.cost.flatMap { now in codexCost.map { max(0, now - $0) } }
                codexCost = usage.cost
            }
            days[day, default: DayUsage()] = days[day, default: DayUsage()]
                + DayUsage(tokens: tokens, cost: cost ?? 0, unpriced: cost == nil ? tokens : 0)
        }
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            var data = partial + chunk
            guard let last = data.lastIndex(of: UInt8(ascii: "\n")) else { partial = data; continue }
            for line in data[...last].split(separator: UInt8(ascii: "\n")) { take(Data(line)) }
            data.removeSubrange(...last)
            partial = data
        }
        if !partial.isEmpty { take(partial) }
        return days
    }

    /// The line's `"timestamp":"…"`, read without parsing the whole line again.
    static func timestamp(_ line: Data) -> Date? {
        guard let key = line.range(of: Data(#""timestamp":""#.utf8)),
              let end = line[key.upperBound...].firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        let text = String(decoding: line[key.upperBound..<end], as: UTF8.self)
        return isoFractional.date(from: text) ?? iso.date(from: text)
    }

    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let iso = ISO8601DateFormatter()

    /// The local day, e.g. "2026-10-19".
    public static func dayString(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

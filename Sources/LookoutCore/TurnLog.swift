import Foundation

/// One finished turn: an agent worked on a prompt for `duration` seconds.
public struct TurnRecord: Codable, Equatable, Sendable {
    public var end: Date
    public var project: String
    public var source: AgentSource
    public var host: String?
    public var duration: TimeInterval

    public init(end: Date, project: String, source: AgentSource, host: String?, duration: TimeInterval) {
        self.end = end; self.project = project; self.source = source; self.host = host; self.duration = duration
    }
}

/// A project's turns over some period.
public struct ProjectUsage: Equatable, Sendable, Identifiable {
    public var project: String
    public var turns: Int
    public var time: TimeInterval

    public var id: String { project }
    public var averageTurn: TimeInterval { turns > 0 ? time / Double(turns) : 0 }
}

/// Finished turns, one JSON line each, in ~/.lookout/turns.jsonl: the history behind usage stats.
public enum TurnLog {
    public static var url: URL { LookoutPaths.root.appendingPathComponent("turns.jsonl") }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func append(_ record: TurnRecord, to url: URL = url) {
        guard var line = try? encoder.encode(record) else { return }
        line.append(UInt8(ascii: "\n"))
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    /// Turns that ended at or after `since`.
    public static func load(from url: URL = url, since: Date) -> [TurnRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: UInt8(ascii: "\n"))
            .compactMap { try? decoder.decode(TurnRecord.self, from: Data($0)) }
            .filter { $0.end >= since }
    }

    /// Per project, the busiest first.
    public static func byProject(_ records: [TurnRecord]) -> [ProjectUsage] {
        Dictionary(grouping: records, by: \.project)
            .map { ProjectUsage(project: $0.key, turns: $0.value.count, time: $0.value.reduce(0) { $0 + $1.duration }) }
            .sorted { ($0.time, $1.project) > ($1.time, $0.project) }
    }
}

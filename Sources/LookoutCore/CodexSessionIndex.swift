import Foundation

/// Codex's thread names, from `~/.codex/session_index.jsonl` (one line per naming; the last one wins).
public enum CodexSessionIndex {
    public static let defaultURL = LookoutPaths.home.appendingPathComponent(".codex/session_index.jsonl")

    public static func name(for sessionID: String, in file: URL = defaultURL) -> String? {
        guard let data = FileManager.default.contents(atPath: file.path) else { return nil }
        return name(for: sessionID, index: data)
    }

    static func name(for sessionID: String, index: Data) -> String? {
        struct Entry: Decodable {
            var id: String
            var thread_name: String?
        }
        for line in index.split(separator: 0x0A).reversed() {
            guard let entry = try? JSONDecoder().decode(Entry.self, from: line), entry.id == sessionID else { continue }
            let name = entry.thread_name?.trimmingCharacters(in: .whitespacesAndNewlines)
            return name?.isEmpty == false ? name : nil
        }
        return nil
    }
}

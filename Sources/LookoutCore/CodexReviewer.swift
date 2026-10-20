import Foundation
import SQLite3

/// Codex's auto-reviewer (`approvals_reviewer = "auto_review"`) answers permission requests itself, after
/// the PermissionRequest hook has already fired. Each review runs in a "guardian" thread that Codex's
/// state database lists, and whose rollout names the session it reviews for.
public enum CodexReviewer {
    public static let defaultDir = LookoutPaths.home.appendingPathComponent(".codex")

    /// Whether `sessionID`'s reviewer has worked since `date`: then a request from then on isn't the user's.
    public static func reviewed(_ sessionID: String, since date: Date, codexDir: URL = defaultDir) -> Bool {
        guard let db = newestDatabase(in: codexDir) else { return false }
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2(db.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return false }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT rollout_path FROM threads WHERE source LIKE '%guardian%' AND updated_at >= ?"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        sqlite3_bind_int64(statement, 1, Int64(date.timeIntervalSince1970.rounded(.down)))
        let parent = Data("\"parent_thread_id\":\"\(sessionID)\"".utf8)
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0),
                  let file = FileHandle(forReadingAtPath: String(cString: text)) else { continue }
            defer { try? file.close() }
            // The session meta comes first, its ids before the long instructions.
            if let head = try? file.read(upToCount: 2048), head.range(of: parent) != nil { return true }
        }
        return false
    }

    /// `state_5.sqlite` today; the number goes up with Codex's schema.
    private static func newestDatabase(in dir: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") }
            .max { $0.compare($1, options: .numeric) == .orderedAscending }
            .map { dir.appendingPathComponent($0) }
    }
}

import Foundation
import SQLite3
import Testing
@testable import LookoutCore

struct CodexReviewerTests {
    @Test func findsTheSessionsRecentReview() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func rollout(_ name: String, parent: String) throws -> String {
            let url = dir.appendingPathComponent(name)
            try Data(#"{"type":"session_meta","payload":{"id":"\#(name)","parent_thread_id":"\#(parent)","base_instructions":"…"}}"#.utf8).write(to: url)
            return url.path
        }
        let mine = try rollout("guardian-a", parent: "session-a")
        let other = try rollout("guardian-b", parent: "session-b")
        var db: OpaquePointer?
        #expect(sqlite3_open(dir.appendingPathComponent("state_5.sqlite").path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, """
            CREATE TABLE threads (id TEXT, rollout_path TEXT, source TEXT, updated_at INTEGER);
            INSERT INTO threads VALUES ('a', '\(mine)', '{"subagent":{"other":"guardian"}}', 1000);
            INSERT INTO threads VALUES ('b', '\(other)', '{"subagent":{"other":"guardian"}}', 2000);
            INSERT INTO threads VALUES ('c', '\(mine)', 'cli', 3000);
            """, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        #expect(CodexReviewer.reviewed("session-a", since: Date(timeIntervalSince1970: 1000), codexDir: dir))
        #expect(!CodexReviewer.reviewed("session-a", since: Date(timeIntervalSince1970: 1001), codexDir: dir))
        #expect(CodexReviewer.reviewed("session-b", since: Date(timeIntervalSince1970: 1500), codexDir: dir))
        #expect(!CodexReviewer.reviewed("session-c", since: Date(timeIntervalSince1970: 0), codexDir: dir))
        #expect(!CodexReviewer.reviewed("session-a", since: .distantPast, codexDir: dir.appendingPathComponent("none")))
    }
}

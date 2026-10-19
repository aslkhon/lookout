import Foundation
import Testing
@testable import LookoutCore

struct UsageHistoryTests {
    let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("lookout-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/projects/-app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex/sessions/2026/10/19"), withIntermediateDirectories: true)
    }

    /// Noon UTC, so it's the same day in any time zone the tests run in... except the far ones.
    func day(_ iso: String) -> String { UsageHistory.dayString(ISO8601DateFormatter().date(from: iso)!) }

    @Test func splitsByDayAndAgent() throws {
        let claude = [
            // One message over two lines counts once.
            #"{"type":"assistant","timestamp":"2026-10-18T12:00:00.000Z","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":1000,"output_tokens":100}}}"#,
            #"{"type":"assistant","timestamp":"2026-10-18T12:00:01.000Z","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":1000,"output_tokens":100}}}"#,
            #"{"type":"user","timestamp":"2026-10-19T12:00:00.000Z","message":{"content":"hi"}}"#,
            #"{"type":"assistant","timestamp":"2026-10-19T12:00:05.000Z","message":{"id":"m2","model":"claude-opus-5-5","usage":{"input_tokens":2000,"output_tokens":0}}}"#,
            #"{"type":"assistant","timestamp":"2026-10-19T12:00:09.000Z","message":{"id":"m3","model":"some-new-model","usage":{"input_tokens":500,"output_tokens":0}}}"#,
        ]
        try (claude.joined(separator: "\n") + "\n").write(to: home.appendingPathComponent(".claude/projects/-app/s1.jsonl"), atomically: true, encoding: .utf8)
        let codex = [
            #"{"timestamp":"2026-10-18T12:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#,
            #"{"timestamp":"2026-10-18T12:00:10.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":0}}}}"#,
            #"{"timestamp":"2026-10-19T12:00:10.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":3000,"cached_input_tokens":0,"output_tokens":0}}}}"#,
        ]
        try codex.joined(separator: "\n").write(to: home.appendingPathComponent(".codex/sessions/2026/10/19/rollout-x.jsonl"), atomically: true, encoding: .utf8)

        let cache = home.appendingPathComponent("cache.json")
        let days = UsageHistory.load(since: .distantPast, home: home, cache: cache)
        let d18 = day("2026-10-18T12:00:00Z"), d19 = day("2026-10-19T12:00:00Z")
        // Opus 5.5: $4 in, $20 out per million.
        #expect(days[d18]?[.claude] == DayUsage(tokens: 1100, cost: 0.006))
        #expect(days[d19]?[.claude] == DayUsage(tokens: 2500, cost: 0.008, unpriced: 500))
        // Codex totals: 1000, then 2000 more. $1.75 per million in.
        #expect(days[d18]?[.codex]?.tokens == 1000)
        #expect(days[d19]?[.codex]?.tokens == 2000)
        #expect(abs((days[d19]?[.codex]?.cost ?? 0) - 0.0035) < 1e-9)

        // From the cache the second time, with the same result.
        #expect(FileManager.default.fileExists(atPath: cache.path))
        #expect(UsageHistory.load(since: .distantPast, home: home, cache: cache) == days)
    }
}

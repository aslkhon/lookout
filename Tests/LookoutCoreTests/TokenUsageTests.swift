import Foundation
import Testing
@testable import LookoutCore

struct TokenUsageTests {
    private let claude = [
        #"{"type":"user","message":{"role":"user","content":"hi"}}"#,
        #"{"type":"assistant","message":{"id":"m1","content":[{"type":"thinking"}],"usage":{"input_tokens":10,"cache_read_input_tokens":900,"cache_creation_input_tokens":90,"output_tokens":50}}}"#,
        #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":10,"cache_read_input_tokens":900,"cache_creation_input_tokens":90,"output_tokens":50}}}"#,
        #"{"type":"assistant","message":{"id":"m2","content":[],"usage":{"input_tokens":5,"cache_read_input_tokens":1000,"cache_creation_input_tokens":0,"output_tokens":1500}}}"#,
    ]

    private func write(_ lines: [String], trailingNewline: Bool = true) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID()).jsonl")
        try (lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func claudeCountsEachMessageOnce() async throws {
        let url = try write(claude)
        defer { try? FileManager.default.removeItem(at: url) }
        let usage = await TokenTally().usage(of: url, source: .claude)
        #expect(usage == TokenUsage(input: 15, cacheRead: 1900, cacheWrite: 90, output: 1550, cost: nil)) // no model in the fixture, so no price
        #expect(usage.summary == "3k tokens · 94% cached · 1k out")
    }

    @Test func readsOnlyWhatWasAppended() async throws {
        let url = try write(Array(claude.prefix(2)), trailingNewline: false) // the last line is still being written
        defer { try? FileManager.default.removeItem(at: url) }
        let tally = TokenTally()
        #expect(await tally.usage(of: url, source: .claude).total == 0)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + claude[2...].joined(separator: "\n") + "\n").utf8))
        try handle.close()
        #expect(await tally.usage(of: url, source: .claude).total == 3555)
    }

    @Test func skipsLinesLongerThanAChunk() async throws {
        let huge = #"{"type":"user","message":{"content":""# + String(repeating: "x", count: 3000) + #""}}"#
        let url = try write([claude[0], huge, huge] + claude[1...])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(await TokenTally(chunk: 1024).usage(of: url, source: .claude) == TokenUsage(input: 15, cacheRead: 1900, cacheWrite: 90, output: 1550, cost: nil))
    }

    @Test func codexTakesTheLatestRunningTotal() async throws {
        let url = try write([
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":60,"output_tokens":7}}}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":null}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":17150265,"cached_input_tokens":16648960,"cache_write_input_tokens":0,"output_tokens":83613}}}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let usage = await TokenTally().usage(of: url, source: .codex)
        #expect(usage == TokenUsage(input: 501305, cacheRead: 16648960, output: 83613, cost: nil))
        #expect(usage.summary == "17.2M tokens · 97% cached · 83k out")
    }
}

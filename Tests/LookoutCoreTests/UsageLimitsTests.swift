import Foundation
import Testing
@testable import LookoutCore

struct UsageLimitsTests {
    @Test func claudeLimitsFromStatusLine() {
        let input: [String: Any] = ["rate_limits": [
            "five_hour": ["used_percentage": 46, "resets_at": 1_792_344_000],
            "seven_day": ["used_percentage": 55.5, "resets_at": 1_792_580_400],
        ]]
        #expect(UsageLimits.claude(statusLine: input) == [
            UsageLimit(windowMinutes: 300, usedPercent: 46, resetsAt: Date(timeIntervalSince1970: 1_792_344_000)),
            UsageLimit(windowMinutes: 10080, usedPercent: 55.5, resetsAt: Date(timeIntervalSince1970: 1_792_580_400)),
        ])
        #expect(UsageLimits.claude(statusLine: ["model": "x"]).isEmpty)
    }

    @Test func codexLimitsFromRollout() {
        let line = #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":2.0,"window_minutes":10080,"resets_at":1792874879},"secondary":{"used_percent":40,"window_minutes":300,"resets_at":1792000000}}}}"#
        let limits = UsageLimits.codex(rolloutLine: Data(line.utf8))
        #expect(limits?.map(\.name) == ["5h", "Week"])
        #expect(limits?.last?.usedPercent == 2)
    }

    @Test func codexLimitsFromNewestSession() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("lookout-limits-\(UUID().uuidString)")
        let day = home.appendingPathComponent(".codex/sessions/2026/10/17")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let older = #"{"payload":{"rate_limits":{"primary":{"used_percent":1,"window_minutes":10080,"resets_at":1792874879}}}}"#
        let newer = #"{"payload":{"rate_limits":{"primary":{"used_percent":7,"window_minutes":10080,"resets_at":1792874879}}}}"#
        try "\(older)\n\(newer)\n{\"payload\":{\"type\":\"agent_message\"}}\n"
            .write(to: day.appendingPathComponent("rollout-a.jsonl"), atomically: true, encoding: .utf8)
        #expect(UsageLimits.loadCodex(home: home).first?.usedPercent == 7)
    }

    @Test func aResetWindowStartsFromZero() {
        let reset = Date(timeIntervalSince1970: 1_000_000)
        let limit = UsageLimit(windowMinutes: 300, usedPercent: 80, resetsAt: reset)
        #expect(limit.current(now: reset - 1) == limit)
        let after = limit.current(now: reset + 60)
        #expect(after.usedPercent == 0)
        #expect(after.resetsAt == reset + 5 * 3600)
    }

    @Test func statusLineWrapperKeepsTheOriginal() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("lookout-sl-\(UUID().uuidString)")
        let wrapper = StatusLineWrapper(home: home, hookBinaryPath: "/x/lookout-hook")
        let settings: [String: Any] = ["model": "opus", "statusLine": ["type": "command", "command": "bash ~/sl.sh", "padding": 0]]
        let wrapped = try wrapper.installing(into: settings)
        let line = try #require(wrapped["statusLine"] as? [String: Any])
        #expect(line["command"] as? String == "/x/lookout-hook statusline")
        #expect(line["padding"] as? Int == 0)
        #expect(StatusLineWrapper.originalCommand(at: wrapper.originalURL) == "bash ~/sl.sh")
        #expect(NSDictionary(dictionary: try wrapper.installing(into: wrapped)).isEqual(to: wrapped)) // idempotent
        let restored = wrapper.removing(from: wrapped)
        #expect(NSDictionary(dictionary: restored).isEqual(to: settings))
    }

    @Test func statusLineWrapperWithoutAnOriginal() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("lookout-sl-\(UUID().uuidString)")
        let wrapper = StatusLineWrapper(home: home, hookBinaryPath: "/x/lookout-hook")
        let wrapped = try wrapper.installing(into: ["model": "opus"])
        #expect(StatusLineWrapper.originalCommand(at: wrapper.originalURL) == nil)
        #expect(wrapper.removing(from: wrapped)["statusLine"] == nil)
    }
}

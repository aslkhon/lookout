import Foundation
import Testing
@testable import LookoutCore

struct AwaySummaryTests {
    private let left = Date(timeIntervalSince1970: 1_000_000)

    private func session(_ project: String, _ status: AgentStatus, minutes: Double, stalled: Bool = false) -> AgentSession {
        var s = AgentSession(source: .claude, sessionID: UUID().uuidString, cwd: "/code/\(project)", status: status,
                             statusSince: left + minutes * 60, lastEventAt: left)
        s.stalled = stalled
        return s
    }

    @Test func countsWhatChangedSinceLeaving() {
        let text = AwaySummary.text(for: [
            session("webshop", .finished, minutes: 5),
            session("docs", .finished, minutes: 20),
            session("api", .needsApproval, minutes: 30),
            session("old", .finished, minutes: -10), // finished before leaving
            session("busy", .working, minutes: 1),
            session("ml", .working, minutes: -5, stalled: true),
        ], since: left)
        #expect(text == "2 finished · 1 needs you · 1 went quiet — api, ml, webshop, docs")
    }

    @Test func nothingHappened() {
        #expect(AwaySummary.text(for: [session("a", .working, minutes: 3), session("b", .idle, minutes: 4)], since: left) == nil)
    }
}

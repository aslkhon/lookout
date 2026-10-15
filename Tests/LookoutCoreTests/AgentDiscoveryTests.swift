import Foundation
import Testing
@testable import LookoutCore

struct AgentDiscoveryTests {
    @Test func mapsClaudeStatuses() {
        #expect(AgentDiscovery.claudeStatus("busy", waitingFor: nil).0 == .working)
        #expect(AgentDiscovery.claudeStatus("idle", waitingFor: nil).0 == .idle)
        #expect(AgentDiscovery.claudeStatus("waiting", waitingFor: nil).0 == .needsApproval)
        #expect(AgentDiscovery.claudeStatus("waiting", waitingFor: .string("question")).0 == .needsInput)
        #expect(AgentDiscovery.claudeStatus("something-new", waitingFor: nil).0 == nil)
    }

    @Test func parsesClaudeSessionFile() throws {
        let json = #"{"pid":75246,"sessionId":"abc","cwd":"/Users/me/Developer/daftar","kind":"interactive","name":"daftar-3f","status":"idle","statusUpdatedAt":1792004478000,"peerFeatures":["x"]}"#
        let file = try JSONDecoder().decode(AgentDiscovery.ClaudeSessionFile.self, from: Data(json.utf8))
        let agent = AgentDiscovery.agent(from: file, tty: "/dev/ttys004", hostBundleID: "com.mitchellh.ghostty")
        #expect(agent.sessionID == "abc")
        #expect(agent.status == .idle)
        #expect(agent.name == "daftar-3f")
        #expect(agent.detail == nil)
        #expect(agent.statusSince == Date(timeIntervalSince1970: 1792004478))
    }

    @Test func scanFindsThisMachinesAgents() {
        // Smoke test: never crashes, and any Claude agent it reports has a live session file.
        for agent in AgentDiscovery.scan() where agent.source == .claude {
            #expect(agent.sessionID != nil)
        }
    }
}

struct DiscoveredSessionTests {
    @Test func codexWithoutSessionIDUsesPlaceholderKey() {
        let agent = DiscoveredAgent(source: .codex, pid: 91100, cwd: "/p/analytics", tty: "/dev/ttys011")
        let s = SessionReducer.apply(agent, to: nil)
        #expect(s.id == agent.placeholderKey)
        #expect(s.status == .idle)
        #expect(s.agentPID == 91100)
    }

    @Test func statusChangeResetsSince() {
        let t0 = Date(timeIntervalSince1970: 100), t1 = Date(timeIntervalSince1970: 200)
        var agent = DiscoveredAgent(source: .claude, pid: 1, sessionID: "a", cwd: "/p", status: .idle, statusSince: t0)
        let idle = SessionReducer.apply(agent, to: nil)
        agent.status = .working; agent.statusSince = t1
        let working = SessionReducer.apply(agent, to: idle)
        #expect(idle.statusSince == t0)
        #expect(working.status == .working && working.statusSince == t1)
    }
}

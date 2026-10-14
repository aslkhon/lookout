import Foundation
import Testing
@testable import LookoutCore

struct RemoteProtocolTests {
    func parse(_ line: String) -> RemoteMessage? {
        RemoteMessage.parse(Data(line.utf8), host: "unicon")
    }

    @Test func parsesHello() {
        guard case .hello(let home, let sha)? = parse(#"{"type": "hello", "version": 1, "home": "/home/dev", "sha256": "ab12"}"#) else {
            Issue.record("not a hello"); return
        }
        #expect(home == "/home/dev")
        #expect(sha == "ab12")
        // Helpers from before self-updating send no hash.
        guard case .hello(_, nil)? = parse(#"{"type": "hello", "version": 1, "home": "/home/dev"}"#) else {
            Issue.record("old hello not parsed"); return
        }
    }

    @Test func eventsAreTaggedWithHost() {
        let line = #"{"type": "event", "envelope": {"source": "claude", "context": {"agentPID": 220, "ancestors": [220, 218], "tty": "/dev/pts/1", "term": "xterm-256color", "termProgram": null, "sshClientPort": 65116, "timestamp": 1792007503.69}, "payload": {"session_id": "gamma-1", "hook_event_name": "PermissionRequest", "cwd": "/home/dev/proj-gamma", "tool_name": "Bash", "tool_input": {"command": "terraform apply"}}}}"#
        guard case .event(let envelope)? = parse(line) else { Issue.record("not an event"); return }
        #expect(envelope.host == "unicon")
        #expect(envelope.context.ancestors == [220, 218])
        #expect(envelope.context.sshClientPort == 65116)
    }

    @Test func agentsSnapshot() {
        let line = #"{"type": "agents", "agents": [{"sessionId": "gamma-1", "cwd": "/home/dev/proj-gamma", "status": "waiting", "waitingFor": null, "kind": "interactive", "name": null, "statusUpdatedAt": 1792007751000, "agentPID": 220, "ancestors": [220, 218], "tty": "/dev/pts/1", "term": "xterm-256color", "termProgram": "vscode", "sshClientPort": 65116, "source": "claude"}, {"cwd": "/home/dev/x", "agentPID": 300, "source": "claude"}, {"cwd": "/home/dev/y", "agentPID": 400, "tty": "/dev/pts/2", "source": "codex"}], "alive": [220, 300, 400, 500]}"#
        guard case .agents(let agents, let alive)? = parse(line) else { Issue.record("not agents"); return }
        // The Claude record without a session id is dropped; Codex agents never have one.
        #expect(agents.map(\.pid) == [220, 400])
        #expect(agents.allSatisfy { $0.host == "unicon" })
        #expect(agents[0].status == .needsApproval)
        #expect(agents[0].termProgram == "vscode")
        #expect(agents[0].ancestors == [220, 218])
        #expect(alive == [220, 300, 400, 500])
    }

    @Test func ignoresUnknownAndGarbage() {
        #expect(parse(#"{"type": "future-thing"}"#) == nil)
        #expect(parse("Welcome to Ubuntu!") == nil)
    }

    @Test func sessionsAreKeyedPerHost() {
        let local = DiscoveredAgent(source: .codex, pid: 400, cwd: "/p", tty: nil)
        var remote = local
        remote.host = "unicon"
        // Same PID on two machines must not collide.
        #expect(local.key != remote.key)
        #expect(local.placeholderKey != remote.placeholderKey)
    }
}

struct CodexSessionIndexTests {
    let index = Data("""
        {"id":"a","thread_name":"Calculate average LUFS","updated_at":"2026-03-05T06:07:08Z"}
        {"id":"b","thread_name":"Explain last commit","updated_at":"2026-03-05T06:07:08Z"}
        {"id":"a","thread_name":"Renamed thread","updated_at":"2026-03-06T06:07:08Z"}
        {"id":"c","thread_name":"  ","updated_at":"2026-03-06T06:07:08Z"}
        not json
        """.utf8)

    @Test func latestNameWins() {
        #expect(CodexSessionIndex.name(for: "a", index: index) == "Renamed thread")
        #expect(CodexSessionIndex.name(for: "b", index: index) == "Explain last commit")
    }

    @Test func blankOrMissing() {
        #expect(CodexSessionIndex.name(for: "c", index: index) == nil)
        #expect(CodexSessionIndex.name(for: "zzz", index: index) == nil)
    }

    @Test func remoteNameReachesSession() {
        var envelope = HookEnvelope(source: .codex, context: HookContext(agentPID: 1),
                                    payload: HookPayload(sessionID: "a", hookEventName: "Stop"))
        envelope.context.sessionName = "Review logs"
        #expect(SessionReducer.apply(envelope, to: nil).name == "Review logs")
    }
}

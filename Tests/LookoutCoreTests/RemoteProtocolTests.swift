import Foundation
import Testing
@testable import LookoutCore

struct RemoteProtocolTests {
    func parse(_ line: String) -> RemoteMessage? {
        RemoteMessage.parse(Data(line.utf8), host: "unicon")
    }

    @Test func parsesHello() {
        guard case .hello(let home)? = parse(#"{"type": "hello", "version": 1, "home": "/home/dev"}"#) else {
            Issue.record("not a hello"); return
        }
        #expect(home == "/home/dev")
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

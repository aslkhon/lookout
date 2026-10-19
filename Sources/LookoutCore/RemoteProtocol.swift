import Foundation

/// First line from a server's helper.
public struct RemoteHello: Decodable, Sendable, Equatable {
    public var home: String
    /// `sha256` of the helper script itself; nil from helpers older than Lookout 0.1.4.
    public var sha256: String?
    /// Whether Lookout's hooks are in the server's Claude Code / Codex configs (helpers ≥ 0.1.5).
    public var hooks: [String: Bool]?
}

/// Lines printed by `lookout-hook --watch` on a server (see Remote/lookout-hook).
public enum RemoteMessage: Sendable {
    case hello(RemoteHello)
    case event(HookEnvelope)
    /// Running agents, and every agent PID still alive (including ones only known from hooks).
    case agents([DiscoveredAgent], alive: Set<Int32>)

    public static func parse(_ line: Data, host: String) -> RemoteMessage? {
        guard let head = try? JSONDecoder().decode(Head.self, from: line) else { return nil }
        switch head.type {
        case "hello":
            return (try? JSONDecoder().decode(RemoteHello.self, from: line)).map { .hello($0) }
        case "event":
            guard var envelope = (try? JSONDecoder().decode(Event.self, from: line))?.envelope else { return nil }
            envelope.host = host
            return .event(envelope)
        case "agents":
            guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: line) else { return nil }
            return .agents(snapshot.agents.compactMap { $0.agent(host: host) }, alive: Set(snapshot.alive))
        default:
            return nil
        }
    }

    private struct Head: Decodable { var type: String }

    private struct Event: Decodable { var envelope: HookEnvelope }
    private struct Snapshot: Decodable {
        var agents: [Record]
        var alive: [Int32]
    }

    /// A Claude session file's fields (for Claude) plus the process context the server adds.
    struct Record: Decodable {
        var source: AgentSource
        var agentPID: Int32
        var sessionId: String?
        var cwd: String
        var status: String?
        var waitingFor: JSONValue?
        var kind: String?
        var name: String?
        var statusUpdatedAt: Double?
        var tty: String?
        var ancestors: [Int32]?
        var term: String?
        var termProgram: String?
        var sshClientPort: Int?
        var branch: String?
        var startedAt: Double?

        func agent(host: String) -> DiscoveredAgent? {
            var agent: DiscoveredAgent
            switch source {
            case .claude:
                guard let sessionId else { return nil }
                let file = AgentDiscovery.ClaudeSessionFile(
                    pid: agentPID, sessionId: sessionId, cwd: cwd, status: status, waitingFor: waitingFor,
                    kind: kind, name: name, statusUpdatedAt: statusUpdatedAt)
                agent = AgentDiscovery.agent(from: file, tty: tty, hostBundleID: nil)
            case .codex:
                agent = DiscoveredAgent(source: .codex, pid: agentPID, cwd: cwd, tty: tty)
            case .gemini, .opencode:
                return nil // not on ssh hosts yet
            }
            agent.host = host
            agent.ancestors = ancestors
            agent.term = term
            agent.termProgram = termProgram
            agent.sshClientPort = sshClientPort
            agent.branch = branch
            agent.startedAt = startedAt.map { Date(timeIntervalSince1970: $0) }
            return agent
        }
    }
}

import Foundation

/// An agent found by scanning the machine rather than through a hook event.
public struct DiscoveredAgent: Equatable, Sendable {
    public var source: AgentSource
    /// ssh host alias; nil for this Mac.
    public var host: String?
    public var pid: Int32
    /// Known for Claude (from its session file); nil for Codex until a hook reports it.
    public var sessionID: String?
    public var cwd: String
    /// nil when the agent doesn't expose its state (Codex).
    public var status: AgentStatus?
    public var statusSince: Date?
    public var detail: String?
    public var tty: String?
    public var hostBundleID: String?
    // Remote agents only (see HookContext).
    public var ancestors: [Int32]?
    public var term: String?
    public var termProgram: String?
    public var sshClientPort: Int?

    public init(source: AgentSource, host: String? = nil, pid: Int32, sessionID: String? = nil, cwd: String,
                status: AgentStatus? = nil, statusSince: Date? = nil, detail: String? = nil, tty: String? = nil,
                hostBundleID: String? = nil) {
        self.source = source; self.host = host; self.pid = pid; self.sessionID = sessionID; self.cwd = cwd
        self.status = status; self.statusSince = statusSince; self.detail = detail; self.tty = tty
        self.hostBundleID = hostBundleID
    }

    public var key: String { AgentSession.key(source: source, sessionID: sessionID ?? "pid:\(pid)", host: host) }

    /// Key used before a hook gives us the real session id.
    public var placeholderKey: String { AgentSession.key(source: source, sessionID: "pid:\(pid)", host: host) }
}

/// Finds running agents so Lookout shows them even when they've been idle since before it launched.
public enum AgentDiscovery {
    /// `~/.claude/sessions/<pid>.json`, written and kept current by Claude Code.
    struct ClaudeSessionFile: Decodable {
        var pid: Int32
        var sessionId: String
        var cwd: String
        var status: String?
        var waitingFor: JSONValue?
        var kind: String?
        var name: String?
        var statusUpdatedAt: Double?
    }

    public static func scan(home: URL = LookoutPaths.home) -> [DiscoveredAgent] {
        claudeAgents(sessionsDir: home.appendingPathComponent(".claude/sessions")) + codexAgents()
    }

    static func claudeAgents(sessionsDir: URL) -> [DiscoveredAgent] {
        let files = (try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder().decode(ClaudeSessionFile.self, from: data),
                  ProcessInspector.isAlive(file.pid),
                  ProcessInspector.executablePath(file.pid).contains("claude") // guard against PID reuse
            else { return nil }
            return agent(from: file, tty: ProcessInspector.info(file.pid).flatMap(ProcessInspector.tty),
                         hostBundleID: ProcessInspector.hostBundleID(of: file.pid))
        }
    }

    static func agent(from file: ClaudeSessionFile, tty: String?, hostBundleID: String?) -> DiscoveredAgent {
        let (status, waiting) = claudeStatus(file.status, waitingFor: file.waitingFor)
        let detail = waiting ?? file.name.map { file.kind == "bg" ? "Background · \($0)" : $0 }
        return DiscoveredAgent(
            source: .claude, pid: file.pid, sessionID: file.sessionId, cwd: file.cwd,
            status: status, statusSince: file.statusUpdatedAt.map { Date(timeIntervalSince1970: $0 / 1000) },
            detail: detail, tty: tty, hostBundleID: hostBundleID)
    }

    /// Claude's session status is "busy", "idle", or "waiting" (a permission/question dialog is open).
    static func claudeStatus(_ status: String?, waitingFor: JSONValue?) -> (AgentStatus?, String?) {
        switch status {
        case "busy": return (.working, nil)
        case "idle": return (.idle, nil)
        case "waiting":
            if case .string(let what)? = waitingFor {
                let lower = what.lowercased()
                let isQuestion = lower.contains("question") || lower.contains("input")
                return (isQuestion ? .needsInput : .needsApproval, what)
            }
            return (.needsApproval, "Waiting for you")
        default: return (nil, nil)
        }
    }

    /// Interactive Codex CLIs: native `codex` processes attached to a terminal.
    static func codexAgents() -> [DiscoveredAgent] {
        ProcessInspector.allPIDs().compactMap { pid in
            guard let info = ProcessInspector.info(pid), info.comm == "codex",
                  let tty = ProcessInspector.tty(info),
                  let cwd = ProcessInspector.cwd(pid) else { return nil }
            return DiscoveredAgent(source: .codex, pid: pid, sessionID: nil, cwd: cwd, status: nil,
                                   detail: nil, tty: tty,
                                   hostBundleID: ProcessInspector.hostBundleID(of: pid))
        }
    }
}

extension SessionReducer {
    /// Session state for an agent found by scanning. Only used for sessions without hook events.
    public static func apply(_ agent: DiscoveredAgent, to existing: AgentSession?, now: Date = Date()) -> AgentSession {
        var s = existing ?? AgentSession(
            source: agent.source, host: agent.host, sessionID: agent.sessionID ?? "pid:\(agent.pid)", cwd: agent.cwd,
            status: .idle, statusSince: agent.statusSince ?? now, lastEventAt: now)
        let status = agent.status ?? .idle
        if status != s.status { s.statusSince = agent.statusSince ?? now }
        s.status = status
        s.detail = agent.detail
        s.cwd = agent.cwd
        s.agentPID = agent.pid
        s.tty = agent.tty
        s.hostBundleID = agent.hostBundleID ?? s.hostBundleID
        s.ancestors = agent.ancestors ?? s.ancestors
        s.term = agent.term ?? s.term
        s.termProgram = agent.termProgram ?? s.termProgram
        s.sshClientPort = agent.sshClientPort ?? s.sshClientPort
        return s
    }
}

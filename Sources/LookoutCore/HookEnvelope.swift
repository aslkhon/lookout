import Foundation

public enum AgentSource: String, Codable, Sendable, CaseIterable {
    case claude, codex

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// What `lookout-hook` sends over the socket: the agent's raw hook payload
/// plus context about the process and terminal it came from.
public struct HookEnvelope: Codable, Sendable {
    public var source: AgentSource
    public var context: HookContext
    public var payload: HookPayload
    /// The ssh host the event came from; nil for this Mac. Set by Lookout, not sent by hooks.
    public var host: String?

    public init(source: AgentSource, context: HookContext, payload: HookPayload, host: String? = nil) {
        self.source = source
        self.context = context
        self.payload = payload
        self.host = host
    }
}

public struct HookContext: Codable, Sendable {
    /// PID of the `claude` / `codex` process, used for liveness checks.
    public var agentPID: Int32?
    public var tty: String?
    public var termProgram: String?
    /// `__CFBundleIdentifier` inherited from the hosting app (Ghostty, VS Code, ...).
    public var hostBundleID: String?
    public var timestamp: Double
    // Sent by the server-side hook (Remote/lookout-hook), where Lookout can't inspect processes itself.
    /// The agent PID followed by its parents.
    public var ancestors: [Int32]?
    /// `$TERM`, e.g. "xterm-ghostty"; ssh forwards it while TERM_PROGRAM usually isn't.
    public var term: String?
    /// Source port of the ssh connection (from `$SSH_CONNECTION`), identifying the local `ssh` process.
    public var sshClientPort: Int?
    /// Codex thread name, looked up on the server.
    public var sessionName: String?
    /// Git branch of the agent's directory and the agent's start time, from the server.
    public var branch: String?
    public var startedAt: Double?
    /// A Claude PermissionRequest hook waiting on its connection for Allow or Deny from Lookout.
    public var awaitsDecision: Bool?
    /// The same, on an ssh host: the hook waits for Lookout to write the answer to ~/.lookout/decisions/<id>.
    public var decisionID: String?

    public init(agentPID: Int32? = nil, tty: String? = nil, termProgram: String? = nil,
                hostBundleID: String? = nil, timestamp: Double = Date().timeIntervalSince1970,
                ancestors: [Int32]? = nil, term: String? = nil, sshClientPort: Int? = nil) {
        self.agentPID = agentPID
        self.tty = tty
        self.termProgram = termProgram
        self.hostBundleID = hostBundleID
        self.timestamp = timestamp
        self.ancestors = ancestors
        self.term = term
        self.sshClientPort = sshClientPort
    }
}

/// The subset of the Claude Code / Codex hook payload Lookout cares about.
/// Both CLIs share this shape; unknown fields are ignored.
public struct HookPayload: Codable, Sendable {
    public var sessionID: String
    public var hookEventName: String
    public var cwd: String?
    public var toolName: String?
    public var toolInput: [String: JSONValue]?
    public var notificationType: String?
    public var message: String?
    public var prompt: String?
    public var lastAssistantMessage: String?
    /// Set on events from inside a Claude subagent, and on SubagentStart/SubagentStop.
    public var agentID: String?
    public var agentType: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case hookEventName = "hook_event_name"
        case cwd
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case notificationType = "notification_type"
        case message
        case prompt
        case lastAssistantMessage = "last_assistant_message"
        case agentID = "agent_id"
        case agentType = "agent_type"
    }

    public init(sessionID: String, hookEventName: String, cwd: String? = nil, toolName: String? = nil,
                toolInput: [String: JSONValue]? = nil, notificationType: String? = nil,
                message: String? = nil, prompt: String? = nil, lastAssistantMessage: String? = nil,
                agentID: String? = nil, agentType: String? = nil) {
        self.sessionID = sessionID
        self.hookEventName = hookEventName
        self.cwd = cwd
        self.toolName = toolName
        self.toolInput = toolInput
        self.notificationType = notificationType
        self.message = message
        self.prompt = prompt
        self.lastAssistantMessage = lastAssistantMessage
        self.agentID = agentID
        self.agentType = agentType
    }

    /// Short human description of the tool call, e.g. "Bash: npm test".
    public var toolSummary: String? {
        toolCall.map { call in call.argument.map { "\(call.name): \($0)" } ?? call.name }
    }

    public var toolCall: ToolCall? {
        guard let toolName else { return nil }
        let keys = ["command", "file_path", "path", "url", "pattern", "description"]
        for key in keys {
            if case .string(let value)? = toolInput?[key], !value.isEmpty {
                return ToolCall(name: toolName, argument: value)
            }
        }
        return ToolCall(name: toolName, argument: nil)
    }
}

/// Minimal JSON value so arbitrary `tool_input` objects decode.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

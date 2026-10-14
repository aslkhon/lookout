import Foundation

public enum AgentStatus: String, Codable, Sendable, CaseIterable {
    case needsApproval, needsInput, working, finished, idle, ended

    public var label: String {
        switch self {
        case .needsApproval: "Needs approval"
        case .needsInput: "Needs input"
        case .working: "Working"
        case .finished: "Finished"
        case .idle: "Idle"
        case .ended: "Ended"
        }
    }

    public var needsAttention: Bool { self == .needsApproval || self == .needsInput }

    /// Sort order in the menu: things needing you first.
    public var rank: Int { Self.allCases.firstIndex(of: self)! }
}

public struct AgentSession: Identifiable, Sendable, Equatable {
    public var id: String { Self.key(source: source, sessionID: sessionID, host: host) }
    public var source: AgentSource
    /// ssh host alias the agent runs on; nil for this Mac.
    public var host: String?
    public var sessionID: String
    public var cwd: String
    public var status: AgentStatus
    public var statusSince: Date
    public var lastEventAt: Date
    /// What the agent is waiting on or last said, e.g. "Bash: npm test".
    public var detail: String?
    /// The last prompt the user submitted, as a title for the session.
    public var lastPrompt: String?
    public var agentPID: Int32?
    public var tty: String?
    public var termProgram: String?
    public var hostBundleID: String?
    // Remote agents only (see HookContext).
    public var ancestors: [Int32]?
    public var term: String?
    public var sshClientPort: Int?

    public var projectName: String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    public static func key(source: AgentSource, sessionID: String, host: String? = nil) -> String {
        (host.map { "\($0)/" } ?? "") + "\(source.rawValue):\(sessionID)"
    }
}

/// Pure state machine: hook events in, session state out.
public enum SessionReducer {
    /// Tools that block on a question to the user.
    static let questionTools: Set<String> = ["AskUserQuestion", "request_user_input"]

    public static func apply(_ envelope: HookEnvelope, to existing: AgentSession?, now: Date = Date()) -> AgentSession {
        let p = envelope.payload
        let ctx = envelope.context
        var s = existing ?? AgentSession(
            source: envelope.source, host: envelope.host, sessionID: p.sessionID, cwd: p.cwd ?? "~",
            status: .idle, statusSince: now, lastEventAt: now)
        s.sessionID = p.sessionID // a placeholder found by scanning gets its real id

        if let cwd = p.cwd { s.cwd = cwd }
        s.agentPID = ctx.agentPID ?? s.agentPID
        s.tty = ctx.tty ?? s.tty
        s.termProgram = ctx.termProgram ?? s.termProgram
        s.hostBundleID = ctx.hostBundleID ?? s.hostBundleID
        s.ancestors = ctx.ancestors ?? s.ancestors
        s.term = ctx.term ?? s.term
        s.sshClientPort = ctx.sshClientPort ?? s.sshClientPort
        s.lastEventAt = now
        if let prompt = p.prompt, !prompt.isEmpty { s.lastPrompt = prompt }

        guard let (status, detail) = transition(p, current: existing?.status) else { return s }
        if status != s.status || existing == nil { s.statusSince = now }
        s.status = status
        s.detail = detail
        return s
    }

    /// New status and detail for an event, or nil when the event doesn't change status.
    static func transition(_ p: HookPayload, current: AgentStatus?) -> (AgentStatus, String?)? {
        switch p.hookEventName {
        case "SessionStart":
            return current == nil ? (.idle, nil) : nil
        case "UserPromptSubmit":
            return (.working, nil)
        case "PreToolUse":
            if let tool = p.toolName, questionTools.contains(tool) {
                return (.needsInput, questionText(p) ?? "Asked a question")
            }
            return (.working, p.toolSummary)
        case "PostToolUse", "PostToolUseFailure":
            return (.working, p.toolSummary)
        case "PermissionRequest":
            return (.needsApproval, p.toolSummary)
        case "Notification":
            switch p.notificationType {
            case "permission_prompt":
                return current == .needsApproval ? nil : (.needsApproval, p.message)
            case "elicitation_dialog":
                return (.needsInput, p.message)
            case "idle_prompt":
                // Waiting on the user; covers turns that ended without a Stop (e.g. Esc).
                return current == .working ? (.finished, p.message) : nil
            default:
                return nil
            }
        case "Stop":
            return (.finished, p.lastAssistantMessage.map(firstLine))
        case "Interrupt":
            return (.idle, "Interrupted")
        case "SessionEnd":
            return (.ended, nil)
        default:
            return nil
        }
    }

    /// Whether moving from `old` to `new` deserves a notification.
    public static func shouldNotify(from old: AgentStatus?, to new: AgentStatus) -> Bool {
        guard old != new else { return false }
        return new == .needsApproval || new == .needsInput || new == .finished
    }

    private static func questionText(_ p: HookPayload) -> String? {
        if case .array(let qs)? = p.toolInput?["questions"],
           case .object(let q)? = qs.first,
           case .string(let text)? = q["question"] {
            return text
        }
        return nil
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return String(line.prefix(200))
    }
}

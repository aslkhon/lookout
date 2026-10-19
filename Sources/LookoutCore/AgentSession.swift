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

public struct ToolCall: Sendable, Equatable {
    public var name: String
    /// The command, path or URL it acts on.
    public var argument: String?
}

/// A Claude subagent the session started and that hasn't stopped yet.
public struct Subagent: Identifiable, Sendable, Equatable {
    public var id: String
    /// "Explore", "general-purpose", or a custom agent's name.
    public var type: String
    /// The task it was given, from the parent's Agent tool call.
    public var description: String?
    public var startedAt: Date
    /// The tool call it's running.
    public var tool: ToolCall?
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
    /// Working, but no hook event for `SessionReducer.stallAfter`: a hung command, or just a long one.
    public var stalled = false
    /// What the agent is waiting on or last said, e.g. "Bash: npm test".
    public var detail: String?
    /// The last prompt the user submitted, as a title for the session.
    public var lastPrompt: String?
    /// The agent's own name for the session (Claude session name, Codex thread name).
    public var name: String?
    /// The tool call the agent is running or waiting on.
    public var tool: ToolCall?
    /// Subagents still running; background ones can outlast the parent's turn.
    public var subagents: [Subagent] = []
    /// Descriptions of Agent tool calls whose subagent hasn't started yet, oldest first.
    var pendingSubagentTasks: [String] = []
    /// The subagent whose permission request or question the session is waiting on.
    var attentionAgentID: String?
    public var branch: String?
    /// When the agent process started.
    public var startedAt: Date?
    /// Start of the current (or last) turn, and how long the last finished turn took.
    public var turnStartedAt: Date?
    public var lastTurnDuration: TimeInterval?
    public var agentPID: Int32?
    public var tty: String?
    public var termProgram: String?
    public var hostBundleID: String?
    // Remote agents only (see HookContext).
    public var ancestors: [Int32]?
    public var term: String?
    public var sshClientPort: Int?

    public var projectName: String {
        // Not URL(fileURLWithPath:): it lstat()s the path, and remote paths under /home hit the automounter.
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    public static func key(source: AgentSource, sessionID: String, host: String? = nil) -> String {
        (host.map { "\($0)/" } ?? "") + "\(source.rawValue):\(sessionID)"
    }
}

/// Pure state machine: hook events in, session state out.
public enum SessionReducer {
    /// Tools that block on a question to the user.
    static let questionTools: Set<String> = ["AskUserQuestion", "request_user_input", "ask_user"]

    public static func apply(_ envelope: HookEnvelope, to existing: AgentSession?, now: Date = Date()) -> AgentSession {
        let p = envelope.payload.normalized(for: envelope.source)
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
        s.name = ctx.sessionName ?? s.name
        s.branch = ctx.branch ?? s.branch
        s.startedAt = ctx.startedAt.map { Date(timeIntervalSince1970: $0) } ?? s.startedAt
        s.lastEventAt = now
        s.stalled = false
        // Claude Code also submits background-task results as prompts; those aren't the user's.
        if let prompt = p.prompt, !prompt.isEmpty, !prompt.hasPrefix("<task-notification>") { s.lastPrompt = prompt }

        if p.hookEventName == "SessionEnd" { s.subagents = []; s.pendingSubagentTasks = [] }
        if trackSubagents(p, in: &s, now: now) { return s }

        guard let (status, detail) = transition(p, current: existing?.status) else { return s }
        if status != s.status || existing == nil { s.statusSince = now }
        let wasActive = existing.map { $0.status == .working || $0.status.needsAttention } ?? false
        if (status == .working || status.needsAttention) && !wasActive { s.turnStartedAt = now }
        if status == .finished, wasActive, let start = s.turnStartedAt { s.lastTurnDuration = now.timeIntervalSince(start) }
        s.status = status
        s.detail = detail
        s.tool = toolEvents.contains(p.hookEventName) ? p.toolCall : nil
        s.attentionAgentID = status.needsAttention ? p.agentID : nil
        return s
    }

    static let subagentTools: Set<String> = ["Agent", "Task"]

    /// Keeps `subagents` up to date. True for a subagent's own tool events, which leave the parent's
    /// status alone; its permission requests and notifications still need the user, so they go through.
    static func trackSubagents(_ p: HookPayload, in s: inout AgentSession, now: Date) -> Bool {
        switch p.hookEventName {
        case "PreToolUse" where p.agentID == nil && subagentTools.contains(p.toolName ?? ""):
            // SubagentStart doesn't say which call started it; they start in the order they're made.
            var task = ""
            if case .string(let text)? = p.toolInput?["description"] { task = text }
            s.pendingSubagentTasks = Array((s.pendingSubagentTasks + [task]).suffix(20))
        case "SubagentStart":
            // Claude Code also starts untyped helpers of its own; those aren't the user's subagents.
            guard let id = p.agentID, let type = p.agentType, !type.isEmpty, !s.subagents.contains(where: { $0.id == id })
            else { return true }
            let task = s.pendingSubagentTasks.isEmpty ? nil : s.pendingSubagentTasks.removeFirst()
            s.subagents = Array((s.subagents + [Subagent(id: id, type: type, description: task?.isEmpty == false ? task : nil,
                                                         startedAt: now)]).suffix(50))
            return true
        case "SubagentStop":
            s.subagents.removeAll { $0.id == p.agentID }
            resumeAfterSubagentRequest(p, in: &s, now: now)
            return true
        case "UserPromptSubmit":
            s.pendingSubagentTasks = []
        case "PreToolUse", "PostToolUse", "PostToolUseFailure":
            guard let id = p.agentID else {
                if p.hookEventName != "PreToolUse", subagentTools.contains(p.toolName ?? "") {
                    // A call that never started a subagent (refused, unknown type) mustn't label the next one.
                    var task = ""
                    if case .string(let text)? = p.toolInput?["description"] { task = text }
                    if let i = s.pendingSubagentTasks.firstIndex(of: task) { s.pendingSubagentTasks.remove(at: i) }
                }
                return false
            }
            resumeAfterSubagentRequest(p, in: &s, now: now)
            if let i = s.subagents.firstIndex(where: { $0.id == id }) {
                s.subagents[i].tool = p.hookEventName == "PreToolUse" ? p.toolCall : nil
            }
            return true
        default:
            break
        }
        return false
    }

    /// A subagent that carries on after asking was answered, in the terminal or here: the session is working again.
    static func resumeAfterSubagentRequest(_ p: HookPayload, in s: inout AgentSession, now: Date) {
        guard s.status.needsAttention, let id = p.agentID, s.attentionAgentID == id else { return }
        s.status = .working
        s.statusSince = now
        s.detail = nil
        s.tool = nil
        s.attentionAgentID = nil
    }

    /// How long a working agent can go without a hook event before it's flagged.
    public static let stallAfter: TimeInterval = 10 * 60

    public static func isStalled(_ s: AgentSession, now: Date = Date()) -> Bool {
        s.status == .working && now.timeIntervalSince(s.lastEventAt) >= stallAfter
    }

    static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest"]

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
            // Claude asks its questions through a permission request too.
            if let tool = p.toolName, questionTools.contains(tool) {
                return (.needsInput, questionText(p) ?? "Asked a question")
            }
            if p.toolName == PlanReview.tool { return (.needsApproval, "Plan ready for review") }
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

import AppKit
import LookoutCore
import os

let log = Logger(subsystem: "io.github.aslkhon.lookout", category: "events")

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var sessions: [String: AgentSession] = [:]
    @Published var serverError: String?
    /// Plan limits, from Claude's status line and Codex's session files.
    @Published private(set) var claudeLimits: [UsageLimit] = []
    @Published private(set) var codexLimits: [UsageLimit] = []
    private var codexLimitsRead: Date?

    var limits: [(source: AgentSource, limits: [UsageLimit])] {
        [(AgentSource.claude, claudeLimits), (.codex, codexLimits)].filter { !$0.1.isEmpty }
    }
    /// A project for the dashboard to show when it next opens (from a compact-mode card).
    @Published var showProject: String?

    let installer = HookInstaller()
    let remotes = RemoteHosts()
    private var server: EventServer?
    private var livenessTimer: Timer?
    /// Permission hooks waiting for Allow or Deny, by session. Each request has its own id, so a click on
    /// a stale notification or button can't answer a newer request it never showed.
    @Published private var approvals: [String: (request: UUID, pending: any PendingApproval, questions: [AgentQuestion], plan: String?)] = [:]
    /// Sessions that have sent hook events; their status comes from hooks, not discovery.
    private var hookDriven: Set<String> = []

    /// How long ended sessions stay in the list.
    private let endedRetention: TimeInterval = 10 * 60

    var sortedSessions: [AgentSession] {
        sessions.values.sorted {
            ($0.status.rank, $1.statusSince) < ($1.status.rank, $0.statusSince)
        }
    }

    var attentionCount: Int { sessions.values.filter { $0.status.needsAttention }.count }

    var needsSetup: Bool { !installer.isInstalled(.claude) && !installer.isInstalled(.codex) }

    func start() {
        if Demo.isOn {
            sessions = Dictionary(uniqueKeysWithValues: Demo.sessions().map { ($0.id, $0) })
            return
        }
        installHookBinary()
        installer.upgradeInstalled()
        VSCodeExtension.upgradeInstalled()
        let server = EventServer(path: LookoutPaths.socket.path) { data, responder in
            let envelope: HookEnvelope
            do {
                envelope = try JSONDecoder().decode(HookEnvelope.self, from: data)
            } catch {
                log.error("Undecodable hook message: \(error.localizedDescription, privacy: .public)")
                return
            }
            let waiting = envelope.context.awaitsDecision == true ? responder : nil
            Task { @MainActor in AppModel.shared.handle(envelope, responder: waiting) }
        }
        do {
            try server.start()
            self.server = server
        } catch {
            serverError = "Couldn't listen on \(LookoutPaths.socket.path): \(error.localizedDescription)"
        }

        livenessTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.refresh() }
        }
        refresh()
        remotes.onMessage = { host, message in AppModel.shared.handleRemote(host: host, message) }
        remotes.start()
        Notifier.shared.onActivate = { [weak self] id in
            guard let session = self?.sessions[id] else { return }
            Focuser.focus(session)
        }
        Notifier.shared.onDecide = { [weak self] id, request, decision in self?.decide(id, request: request, decision) }
    }

    func handle(_ envelope: HookEnvelope, responder: Responder? = nil) {
        if SelfTest.shared.claim(envelope.payload.sessionID) { return }
        let key = AgentSession.key(source: envelope.source, sessionID: envelope.payload.sessionID, host: envelope.host)
        hookDriven.insert(key)
        // A Codex agent found by scanning becomes this session once its hooks report in.
        let placeholder = envelope.context.agentPID.map {
            AgentSession.key(source: envelope.source, sessionID: "pid:\($0)", host: envelope.host)
        }
        let old = sessions[key] ?? placeholder.flatMap { sessions.removeValue(forKey: $0) }
        var new = SessionReducer.apply(envelope, to: old)
        if envelope.source == .codex, envelope.host == nil,
           let name = CodexSessionIndex.name(for: envelope.payload.sessionID) {
            new.name = name // remote hooks look this up on the server
        }
        sessions[key] = new
        // Hold a waiting permission hook until the user answers here; once answered anywhere, let it go.
        let pending: (any PendingApproval)? = responder
            ?? envelope.host.flatMap { RemoteHosts.Approval(host: $0, id: envelope.context.decisionID) }
        if let pending {
            let p = envelope.payload
            let questions = AgentQuestion.parse(p.toolInput, tool: p.toolName)
            let plan = PlanReview.plan(p.toolInput, tool: p.toolName)
            approvals.updateValue((UUID(), pending, questions, plan), forKey: key)?.pending.answer(nil)
        } else if !new.status.needsAttention {
            approvals.removeValue(forKey: key)?.pending.answer(nil)
        }
        if new.status == .finished, let old, old.status == .working || old.status.needsAttention,
           let duration = new.lastTurnDuration {
            TurnLog.append(TurnRecord(end: Date(), project: new.projectName, source: new.source, host: new.host, duration: duration))
        }
        log.debug("\(key, privacy: .public) \(envelope.payload.hookEventName, privacy: .public) → \(new.status.rawValue, privacy: .public) pid=\(new.agentPID.map(String.init) ?? "nil", privacy: .public)")
        // A held request always gets its own notification, also when it replaces an earlier one.
        if SessionReducer.shouldNotify(from: old?.status, to: new.status) || pending != nil {
            Notifier.shared.post(for: new, request: approvals[key]?.request)
        } else if old?.status != new.status {
            Notifier.shared.clear(sessionID: key)
        }
    }

    /// Answers this agent's current permission request, when Lookout holds one.
    func decider(for session: AgentSession) -> ((PermissionDecision) -> Void)? {
        guard let request = approvals[session.id]?.request else { return nil }
        return { [weak self] in self?.decide(session.id, request: request, $0) }
    }

    /// The questions in this agent's held request, if it's asking some.
    func questions(for session: AgentSession) -> [AgentQuestion] { approvals[session.id]?.questions ?? [] }

    /// The plan in this agent's held request, if it's asking to leave plan mode.
    func plan(for session: AgentSession) -> String? { approvals[session.id]?.plan }

    func decide(_ key: String, request: UUID, _ decision: PermissionDecision) {
        guard approvals[key]?.request == request else { return } // already answered, or replaced by a newer request
        approvals.removeValue(forKey: key)?.pending.answer(decision)
    }

    func focus(_ session: AgentSession) {
        Focuser.focus(session)
    }

    /// Stops watching `host` and drops its sessions.
    func removeHost(_ host: String) {
        remotes.remove(host)
        for (key, session) in sessions where session.host == host {
            sessions[key] = nil
            hookDriven.remove(key)
            Notifier.shared.clear(sessionID: key)
        }
    }

    func clearEnded() {
        sessions = sessions.filter { $0.value.status != .ended }
    }

    private func refresh() {
        checkLiveness()
        checkStalls()
        KeepAwake.shared.update(working: sessions.values.contains { $0.status == .working && !$0.stalled })
        updateLocalDetails()
        // Codex's limits only change while it runs, so its files are read again after its events.
        let readCodex = codexLimitsRead.map { read in
            sessions.values.contains { $0.source == .codex && $0.host == nil && $0.lastEventAt > read }
        } ?? true
        if readCodex { codexLimitsRead = Date() }
        Task.detached(priority: .utility) {
            let found = AgentDiscovery.scan()
            let claude = UsageLimits.loadClaude()
            let codex = readCodex ? UsageLimits.loadCodex() : nil
            await MainActor.run { AppModel.shared.merge(found); AppModel.shared.setLimits(claude: claude, codex: codex) }
        }
    }

    private func setLimits(claude: [UsageLimit], codex: [UsageLimit]?) {
        if claude != claudeLimits { claudeLimits = claude }
        if let codex, codex != codexLimits { codexLimits = codex }
    }

    /// Flags working agents that have gone quiet, and notifies once; their next hook event clears it.
    /// Only hook-driven ones: for agents found by scanning, `lastEventAt` is just when they were found.
    private func checkStalls() {
        for (key, session) in sessions where hookDriven.contains(key) && !session.stalled && SessionReducer.isStalled(session) {
            sessions[key]?.stalled = true
            sessions[key].map { Notifier.shared.post(for: $0) }
        }
    }

    /// Adds running agents that haven't sent a hook event (e.g. idle since before Lookout started).
    func handleRemote(host: String, _ message: RemoteMessage) {
        switch message {
        case .hello:
            break
        case .event(let envelope):
            handle(envelope)
        case .agents(let found, let alive):
            merge(found, host: host)
            for (key, session) in sessions where session.host == host && session.status != .ended {
                if let pid = session.agentPID, !alive.contains(pid) { end(key) }
            }
        }
    }

    private func end(_ key: String) {
        approvals.removeValue(forKey: key)?.pending.answer(nil)
        guard var session = sessions[key] else { return }
        session.status = .ended
        session.statusSince = Date()
        sessions[key] = session
        Notifier.shared.clear(sessionID: key)
    }

    private func merge(_ found: [DiscoveredAgent], host: String? = nil) {
        let knownPIDs = Set(sessions.values.filter { $0.status != .ended && $0.host == host }.compactMap(\.agentPID))
        for agent in found {
            let key = agent.key
            if hookDriven.contains(key) {
                // Hooks own the status; still pick up process details only a scan knows (remote ancestors).
                if agent.host != nil, var session = sessions[key] {
                    session.ancestors = agent.ancestors ?? session.ancestors
                    session.branch = agent.branch ?? session.branch
                    session.startedAt = agent.startedAt ?? session.startedAt
                    if sessions[key] != session { sessions[key] = session }
                }
                continue
            }
            if sessions[key] == nil, knownPIDs.contains(agent.pid) { continue }
            let old = sessions[key]
            let new = SessionReducer.apply(agent, to: old)
            guard new != old else { continue }
            sessions[key] = new
            if old != nil, SessionReducer.shouldNotify(from: old?.status, to: new.status) {
                Notifier.shared.post(for: new)
            }
        }
    }

    /// Branch and start time of agents on this Mac (remote ones come from their host's helper).
    private func updateLocalDetails() {
        for (key, session) in sessions where session.host == nil && session.status != .ended {
            var updated = session
            updated.branch = GitInfo.branch(of: session.cwd)
            if updated.startedAt == nil, let pid = session.agentPID {
                updated.startedAt = ProcessInspector.info(pid)?.startedAt
            }
            if updated != session { sessions[key] = updated }
        }
    }

    private func checkLiveness() {
        let now = Date()
        for (key, session) in sessions {
            if session.status == .ended {
                if now.timeIntervalSince(session.statusSince) > endedRetention { sessions[key] = nil }
            } else if session.host == nil, let pid = session.agentPID, !Self.isAlive(pid) {
                end(key) // remote sessions are checked by their host's snapshots
            }
        }
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Copies the bundled hook binary to a stable, space-free path that the agent configs reference.
    func installHookBinary() {
        guard let bundled = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("lookout-hook"),
              FileManager.default.fileExists(atPath: bundled.path) else { return }
        let dest = LookoutPaths.hookBinary
        let fm = FileManager.default
        if fm.contentsEqual(atPath: bundled.path, andPath: dest.path) { return }
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let tmp = dest.appendingPathExtension("tmp")
            try? fm.removeItem(at: tmp)
            try fm.copyItem(at: bundled, to: tmp)
            _ = try fm.replaceItemAt(dest, withItemAt: tmp)
        } catch {
            serverError = "Couldn't install hook binary: \(error.localizedDescription)"
        }
    }
}

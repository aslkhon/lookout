import AppKit
import LookoutCore
import os

let log = Logger(subsystem: "io.github.aslkhon.lookout", category: "events")

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var sessions: [String: AgentSession] = [:]
    @Published var serverError: String?

    let installer = HookInstaller()
    let remotes = RemoteHosts()
    private var server: EventServer?
    private var livenessTimer: Timer?
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
        installHookBinary()
        VSCodeExtension.upgradeInstalled()
        let server = EventServer(path: LookoutPaths.socket.path) { data in
            let envelope: HookEnvelope
            do {
                envelope = try JSONDecoder().decode(HookEnvelope.self, from: data)
            } catch {
                log.error("Undecodable hook message: \(error.localizedDescription, privacy: .public)")
                return
            }
            Task { @MainActor in AppModel.shared.handle(envelope) }
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
    }

    func handle(_ envelope: HookEnvelope) {
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
        log.debug("\(key, privacy: .public) \(envelope.payload.hookEventName, privacy: .public) → \(new.status.rawValue, privacy: .public) pid=\(new.agentPID.map(String.init) ?? "nil", privacy: .public)")
        if SessionReducer.shouldNotify(from: old?.status, to: new.status) {
            Notifier.shared.post(for: new)
        } else if old?.status != new.status {
            Notifier.shared.clear(sessionID: key)
        }
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
        Task.detached(priority: .utility) {
            let found = AgentDiscovery.scan()
            await MainActor.run { AppModel.shared.merge(found) }
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
                if agent.host != nil, var session = sessions[key], session.ancestors != agent.ancestors {
                    session.ancestors = agent.ancestors
                    sessions[key] = session
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

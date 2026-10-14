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
        Notifier.shared.onActivate = { [weak self] id in
            guard let session = self?.sessions[id] else { return }
            Focuser.focus(session)
        }
    }

    func handle(_ envelope: HookEnvelope) {
        let key = AgentSession.key(source: envelope.source, sessionID: envelope.payload.sessionID)
        hookDriven.insert(key)
        // A Codex agent found by scanning becomes this session once its hooks report in.
        let placeholder = envelope.context.agentPID.map { "\(envelope.source.rawValue):pid:\($0)" }
        let old = sessions[key] ?? placeholder.flatMap { sessions.removeValue(forKey: $0) }
        let new = SessionReducer.apply(envelope, to: old)
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
    private func merge(_ found: [DiscoveredAgent]) {
        let knownPIDs = Set(sessions.values.filter { $0.status != .ended }.compactMap(\.agentPID))
        for agent in found {
            let key = agent.sessionID.map { AgentSession.key(source: agent.source, sessionID: $0) } ?? agent.placeholderKey
            if hookDriven.contains(key) { continue }
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
            } else if let pid = session.agentPID, !Self.isAlive(pid) {
                var ended = session
                ended.status = .ended
                ended.statusSince = now
                sessions[key] = ended
                Notifier.shared.clear(sessionID: key)
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

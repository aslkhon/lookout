import AppKit
import LookoutCore

/// Notices when the user steps away (screen locked or display asleep) and, on their return,
/// posts one notification summing up what the agents did meanwhile.
@MainActor
final class AwayWatcher {
    static let shared = AwayWatcher()

    /// Shorter absences aren't worth a summary: the notifications are still on screen.
    private let minimumAway: TimeInterval = 5 * 60
    private var awaySince: Date?
    private var locked = false

    func start() {
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.locked = true; self.leave() }
        }
        distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.locked = false; self.back() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.leave() }
        }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if !self.locked { self.back() } } // locked: wait for the unlock
        }
    }

    private func leave() {
        if awaySince == nil { awaySince = Date() }
    }

    private func back() {
        guard let since = awaySince else { return }
        awaySince = nil
        let away = Date().timeIntervalSince(since)
        guard away >= minimumAway else { return }
        Notifier.shared.postSummary(sessions: Array(AppModel.shared.sessions.values), since: since, away: away)
    }
}

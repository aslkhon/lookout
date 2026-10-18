import AppKit
import LookoutCore
import UserNotifications

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Called with a session id when the user clicks a notification.
    var onActivate: ((String) -> Void)?
    /// Called with a session id when the user clicks Allow or Deny on an approval notification.
    var onDecide: ((String, UUID, PermissionDecision) -> Void)?

    private static let approvalCategory = "approval"

    private var center: UNUserNotificationCenter { .current() }

    /// UserDefaults key for the sound picked in Setup: "Default", "None" or a macOS sound name.
    static let soundKey = "notificationSound"

    /// Quiet hours from Setup: on or off, and the window in minutes after midnight.
    static let quietKey = "quietHours"
    static let quietStartKey = "quietHoursStart"
    static let quietEndKey = "quietHoursEnd"
    static let defaultQuietStart = 22 * 60
    static let defaultQuietEnd = 8 * 60

    /// The sounds in /System/Library/Sounds, e.g. "Glass" and "Ping".
    static let systemSounds: [String] = ((try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? [])
        .map { ($0 as NSString).deletingPathExtension }
        .sorted()

    private var sound: UNNotificationSound? {
        switch UserDefaults.standard.string(forKey: Self.soundKey) ?? "Default" {
        case "Default": .default
        case "None": nil
        case let name: UNNotificationSound(named: UNNotificationSoundName(name))
        }
    }

    override init() {
        super.init()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(
            identifier: Self.approvalCategory,
            // Only on an unlocked Mac.
            actions: [UNNotificationAction(identifier: PermissionDecision.allow.rawValue, title: "Allow", options: .authenticationRequired),
                      UNNotificationAction(identifier: PermissionDecision.deny.rawValue, title: "Deny",
                                           options: [.destructive, .authenticationRequired])],
            intentIdentifiers: [])])
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Quiet hours, or a muted project. The menu bar and windows still show who needs you.
    private func silenced(_ session: AgentSession) -> Bool {
        muted(session) || quietNow
    }

    private func muted(_ session: AgentSession) -> Bool {
        UserDefaults.standard.bool(forKey: ProjectStyle.mutedKey(session.projectName))
    }

    private var quietNow: Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.quietKey) else { return false }
        let quiet = QuietHours(start: defaults.object(forKey: Self.quietStartKey) as? Int ?? Self.defaultQuietStart,
                               end: defaults.object(forKey: Self.quietEndKey) as? Int ?? Self.defaultQuietEnd)
        return quiet.contains(Date())
    }

    /// `request`: Lookout holds the agent's permission request, so the notification gets Allow and Deny for it.
    func post(for session: AgentSession, request: UUID? = nil) {
        guard !silenced(session) else { return }
        let content = UNMutableNotificationContent()
        switch session.status {
        case .needsApproval:
            content.title = "\(session.projectName) needs approval"
            content.body = session.detail ?? "Waiting for permission"
        case .needsInput:
            content.title = "\(session.projectName) has a question"
            content.body = session.detail ?? "Waiting for your input"
        case .working where session.stalled:
            content.title = "\(session.projectName) has gone quiet"
            content.body = "No activity for \(Int(SessionReducer.stallAfter / 60)) minutes" + (session.detail.map { " · \($0)" } ?? "")
        case .finished:
            content.title = "\(session.projectName) finished"
            content.body = session.detail ?? session.lastPrompt ?? "Turn complete"
        default:
            return
        }
        content.subtitle = session.source.displayName
        content.sound = sound
        content.userInfo = ["sessionID": session.id]
        if let request {
            content.categoryIdentifier = Self.approvalCategory
            content.userInfo["request"] = request.uuidString
        }
        // Reusing the session id replaces any earlier notification for the same agent.
        center.add(UNNotificationRequest(identifier: session.id, content: content, trigger: nil))
    }

    /// "While you were away": one notification for everything that happened, minus muted projects.
    /// Clicking it opens the dashboard.
    func postSummary(sessions: [AgentSession], since: Date, away: TimeInterval) {
        guard !quietNow, let text = AwaySummary.text(for: sessions.filter { !muted($0) }, since: since) else { return }
        let content = UNMutableNotificationContent()
        content.title = "While you were away · \(Format.duration(away))"
        content.body = text
        content.sound = sound
        content.userInfo = ["summary": true]
        center.add(UNNotificationRequest(identifier: "lookout-away", content: content, trigger: nil))
    }

    func isAuthorized() async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    func postTest() {
        let content = UNMutableNotificationContent()
        content.title = "Lookout notifications work"
        content.body = "You'll hear from Lookout when an agent needs approval, asks a question or finishes."
        content.sound = sound
        center.add(UNNotificationRequest(identifier: "lookout-test", content: content, trigger: nil))
    }

    func clear(sessionID: String) {
        center.removeDeliveredNotifications(withIdentifiers: [sessionID])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if info["summary"] != nil {
            await MainActor.run { NSApp.activate(); AppDelegate.openDashboard?() }
        }
        guard let id = info["sessionID"] as? String else { return }
        if let decision = PermissionDecision(rawValue: response.actionIdentifier),
           let request = (info["request"] as? String).flatMap(UUID.init(uuidString:)) {
            await MainActor.run { onDecide?(id, request, decision) }
        } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            await MainActor.run { onActivate?(id) }
        }
    }
}

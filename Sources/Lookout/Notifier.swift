import Foundation
import LookoutCore
import UserNotifications

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Called with a session id when the user clicks a notification.
    var onActivate: ((String) -> Void)?

    private var center: UNUserNotificationCenter { .current() }

    /// UserDefaults key for the sound picked in Setup: "Default", "None" or a macOS sound name.
    static let soundKey = "notificationSound"

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
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func post(for session: AgentSession) {
        let content = UNMutableNotificationContent()
        switch session.status {
        case .needsApproval:
            content.title = "\(session.projectName) needs approval"
            content.body = session.detail ?? "Waiting for permission"
        case .needsInput:
            content.title = "\(session.projectName) has a question"
            content.body = session.detail ?? "Waiting for your input"
        case .finished:
            content.title = "\(session.projectName) finished"
            content.body = session.detail ?? session.lastPrompt ?? "Turn complete"
        default:
            return
        }
        content.subtitle = session.source.displayName
        content.sound = sound
        content.userInfo = ["sessionID": session.id]
        // Reusing the session id replaces any earlier notification for the same agent.
        center.add(UNNotificationRequest(identifier: session.id, content: content, trigger: nil))
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
        guard let id = response.notification.request.content.userInfo["sessionID"] as? String else { return }
        await MainActor.run { onActivate?(id) }
    }
}

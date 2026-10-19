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

    /// Phone alerts through Bark: the key (or the URL the Bark app copies), whether finished turns
    /// are sent too, and whether only while you're away from the Mac (the default).
    static let barkKey = "barkKey"
    static let barkFinishedKey = "barkFinished"
    static let barkAwayKey = "barkOnlyAway"

    /// The sounds in /System/Library/Sounds, e.g. "Glass" and "Ping".
    static let systemSounds: [String] = ((try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? [])
        .map { ($0 as NSString).deletingPathExtension }
        .sorted()

    /// The kinds of notification that can each have their own sound, per agent.
    enum SoundEvent: String, CaseIterable {
        case approval, question, finished

        var label: String {
            switch self {
            case .approval: "Approval or plan"
            case .question: "Question"
            case .finished: "Finished"
            }
        }

        init?(_ status: AgentStatus) {
            switch status {
            case .needsApproval: self = .approval
            case .needsInput: self = .question
            case .finished: self = .finished
            default: return nil
            }
        }
    }

    /// UserDefaults key for one agent's sound for one event; missing or "" uses the main sound.
    static func soundKey(_ source: AgentSource, _ event: SoundEvent) -> String {
        "\(soundKey).\(source.rawValue).\(event.rawValue)"
    }

    private var sound: UNNotificationSound? { Self.sound(named: UserDefaults.standard.string(forKey: Self.soundKey) ?? "Default") }

    private func sound(for session: AgentSession) -> UNNotificationSound? { Self.sound(named: soundName(for: session)) }

    private func soundName(for session: AgentSession) -> String {
        guard !session.stalled, let event = SoundEvent(session.status),
              let name = UserDefaults.standard.string(forKey: Self.soundKey(session.source, event)), !name.isEmpty
        else { return UserDefaults.standard.string(forKey: Self.soundKey) ?? "Default" }
        return name
    }

    /// The notification's sound without the notification, for the notch.
    private func play(_ name: String) {
        switch name {
        case "Default": NSSound.beep()
        case "None": break
        case let name: NSSound(named: NSSound.Name(name))?.play()
        }
    }

    private static func sound(named name: String) -> UNNotificationSound? {
        switch name {
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
            actions: [UNNotificationAction(identifier: PermissionDecision.allow.wire, title: "Allow", options: .authenticationRequired),
                      UNNotificationAction(identifier: PermissionDecision.deny.wire, title: "Deny",
                                           options: [.destructive, .authenticationRequired])],
            intentIdentifiers: [])])
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Quiet hours, presenting, or a muted project. The menu bar and windows still show who needs you.
    private func silenced(_ session: AgentSession) -> Bool {
        muted(session) || quietNow || presentingNow
    }

    private var presentingNow: Bool { Presenting.enabled && Presenting.now }

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
        case .needsApproval where session.tool?.name == PlanReview.tool:
            content.title = "\(session.projectName) has a plan"
            content.body = "Ready for review"
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
        // The notch shows it instead of a banner, with the same sound.
        if ViewModes.shared.mode == .notch, let notch = AppDelegate.shared?.notchPanel {
            play(soundName(for: session))
            notch.peek()
            alertPhone(session, title: content.title, body: "\(content.subtitle): \(content.body)")
            return
        }
        content.sound = sound(for: session)
        content.userInfo = ["sessionID": session.id]
        if let request {
            // Not for questions, nor plans: Claude ignores a hook's allow for a plan.
            if session.status == .needsApproval, session.tool?.name != PlanReview.tool {
                content.categoryIdentifier = Self.approvalCategory
            }
            content.userInfo["request"] = request.uuidString
        }
        // Reusing the session id replaces any earlier notification for the same agent.
        center.add(UNNotificationRequest(identifier: session.id, content: content, trigger: nil))
        alertPhone(session, title: content.title, body: "\(content.subtitle): \(content.body)")
    }

    private func alertPhone(_ session: AgentSession, title: String, body: String) {
        let defaults = UserDefaults.standard
        guard let bark = Bark(defaults.string(forKey: Self.barkKey) ?? "") else { return }
        if session.status == .finished, !defaults.bool(forKey: Self.barkFinishedKey) { return }
        if defaults.object(forKey: Self.barkAwayKey) as? Bool ?? true, !AwayWatcher.shared.isAway { return }
        Task { await Self.push(bark, title: title, body: body, urgent: session.status.needsAttention || session.stalled) }
    }

    /// Nil once Bark took it, else what went wrong.
    @discardableResult
    nonisolated static func push(_ bark: Bark, title: String, body: String, urgent: Bool) async -> String? {
        do {
            let (data, response) = try await URLSession.shared.data(for: bark.request(title: title, body: body, urgent: urgent))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if Bark.accepted(data, status: status) { return nil }
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            log.error("Bark push failed: \(status) \(message ?? "", privacy: .public)")
            return "Bark said \(status)" + (message.map { ": \($0)" } ?? "")
        } catch {
            log.error("Bark push failed: \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
    }

    /// "While you were away": one notification for everything that happened, minus muted projects.
    /// Clicking it opens the dashboard.
    func postSummary(sessions: [AgentSession], since: Date, away: TimeInterval) {
        guard !quietNow, !presentingNow, let text = AwaySummary.text(for: sessions.filter { !muted($0) }, since: since) else { return }
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
        if let decision = PermissionDecision(wire: response.actionIdentifier),
           let request = (info["request"] as? String).flatMap(UUID.init(uuidString:)) {
            await MainActor.run { onDecide?(id, request, decision) }
        } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            await MainActor.run { onActivate?(id) }
        }
    }
}

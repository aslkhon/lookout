import AppKit
import LookoutCore

/// Setup's Self-Test: checks each link between an agent and Lookout, including a test event sent
/// through the installed hook the way an agent would.
@MainActor
final class SelfTest: ObservableObject {
    struct Check: Identifiable {
        enum Level { case ok, warning, failed, info }
        var title: String
        var level: Level
        var detail: String
        var id: String { title }
    }

    static let shared = SelfTest()

    @Published private(set) var checks: [Check] = []
    @Published private(set) var running = false
    @Published private(set) var ranAt: Date?

    /// Session ids of test events; AppModel hands them here instead of showing them as agents.
    static let sessionPrefix = "lookout-self-test-"
    private var awaited: Set<String> = []
    private var received: [String: Date] = [:]

    /// True if this event is a self-test's; it's then consumed. Only the run waiting for it keeps it.
    func claim(_ sessionID: String) -> Bool {
        guard sessionID.hasPrefix(Self.sessionPrefix) else { return false }
        if awaited.contains(sessionID) { received[sessionID] = Date() }
        return true
    }

    func run(model: AppModel, remotes: RemoteHosts) async {
        guard !running else { return }
        running = true
        defer { running = false; ranAt = Date() }
        var results = [hookBinary(), await eventDelivery(model: model)]
        for source in AgentSource.allCases where agentPresent(source) {
            results.append(hooks(source, installer: model.installer))
        }
        if agentPresent(.claude) { results.append(statusLine(installer: model.installer)) }
        results.append(await notifications())
        results += automation()
        results += remotes.hosts.map { host in
            let state = remotes.states[host]
            return switch state {
            case .connected: Check(title: "ssh \(host)", level: .ok, detail: "Connected")
            case .failed: Check(title: "ssh \(host)", level: .failed, detail: state.label)
            case .connecting, nil: Check(title: "ssh \(host)", level: .warning, detail: "Still connecting")
            }
        }
        checks = results
    }

    /// Plain text of the last run, for a bug report.
    var report: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let mark: [Check.Level: String] = [.ok: "✓", .warning: "!", .failed: "✗", .info: "·"]
        return (["Lookout \(version) self-test, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"]
            + checks.map { "\(mark[$0.level]!) \($0.title): \($0.detail)" }).joined(separator: "\n")
    }

    // MARK: Checks

    private func agentPresent(_ source: AgentSource) -> Bool {
        FileManager.default.fileExists(atPath: LookoutPaths.home.appendingPathComponent(source == .claude ? ".claude" : ".codex").path)
    }

    private func hookBinary() -> Check {
        let title = "Hook program"
        let path = LookoutPaths.hookBinary.path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return Check(title: title, level: .failed, detail: "Missing at \(path). Relaunch Lookout to put it back.")
        }
        if let bundled = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("lookout-hook").path,
           FileManager.default.fileExists(atPath: bundled),
           !FileManager.default.contentsEqual(atPath: bundled, andPath: path) {
            return Check(title: title, level: .warning, detail: "Older than this Lookout. Relaunch Lookout to update it.")
        }
        return Check(title: title, level: .ok, detail: path)
    }

    /// Runs the installed hook with a test payload and waits for it to arrive.
    private func eventDelivery(model: AppModel) async -> Check {
        let title = "Events reach Lookout"
        let id = Self.sessionPrefix + UUID().uuidString
        let payload = #"{"session_id":"\#(id)","hook_event_name":"Notification","cwd":"/","message":"Lookout self-test"}"#
        awaited.insert(id)
        defer { awaited.remove(id); received[id] = nil }
        let sent = Date()
        let exited = await Task.detached { () -> Int32? in
            let process = Process()
            process.executableURL = LookoutPaths.hookBinary
            process.arguments = ["claude"]
            let stdin = Pipe()
            process.standardInput = stdin
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            try? stdin.fileHandleForWriting.write(contentsOf: Data(payload.utf8))
            try? stdin.fileHandleForWriting.close()
            process.waitUntilExit()
            return process.terminationStatus
        }.value
        guard exited != nil else { return Check(title: title, level: .failed, detail: "Couldn't run the hook program.") }
        for _ in 0..<30 where received[id] == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard let arrived = received.removeValue(forKey: id) else {
            return Check(title: title, level: .failed,
                         detail: "A test event sent through the hook never arrived." + (model.serverError.map { " \($0)" } ?? ""))
        }
        return Check(title: title, level: .ok, detail: String(format: "A test event arrived in %.2f s", arrived.timeIntervalSince(sent)))
    }

    private func hooks(_ source: AgentSource, installer: HookInstaller) -> Check {
        let title = "\(source.displayName) hooks"
        let url = installer.configURL(for: source)
        if let data = FileManager.default.contents(atPath: url.path), !data.isEmpty,
           (try? JSONSerialization.jsonObject(with: data)) == nil {
            return Check(title: title, level: .failed, detail: "\(url.path) isn't valid JSON, so the agent can't read its hooks.")
        }
        guard installer.isInstalled(source) else {
            return Check(title: title, level: .failed, detail: "Not installed. Install them under Agents.")
        }
        return Check(title: title, level: .ok, detail: "Installed in \(url.path)")
    }

    private func statusLine(installer: HookInstaller) -> Check {
        let title = "Claude plan limits"
        let settings = FileManager.default.contents(atPath: installer.configURL(for: .claude).path)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        guard StatusLineWrapper(hookBinaryPath: installer.hookBinaryPath).isInstalled(in: settings) else {
            return Check(title: title, level: .warning, detail: "The status line isn't wrapped, so limits can't be read. Reinstall Claude Code's hooks under Agents.")
        }
        guard let saved = try? UsageLimits.claudeFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            return Check(title: title, level: .info, detail: "None yet: they arrive with Claude Code's next status line update.")
        }
        let ago = Format.ago(saved, now: Date())
        return Check(title: title, level: .ok, detail: "Last updated \(ago == "now" ? "just now" : "\(ago) ago")")
    }

    private func notifications() async -> Check {
        await Notifier.shared.isAuthorized()
            ? Check(title: "Notifications", level: .ok, detail: "Allowed")
            : Check(title: "Notifications", level: .failed, detail: "Not allowed. Turn them on in System Settings › Notifications › Lookout.")
    }

    /// Jumping to a tab needs Automation for the terminal. Checked without asking, for running terminals.
    private func automation() -> [Check] {
        let terminals = [Focuser.terminalID, Focuser.itermID, Focuser.ghosttyID]
        return NSWorkspace.shared.runningApplications.compactMap { app -> Check? in
            guard let id = app.bundleIdentifier, terminals.contains(id) else { return nil }
            let name = app.localizedName ?? id
            var target = AEDesc()
            defer { AEDisposeDesc(&target) }
            let created = id.withCString { AECreateDesc(typeApplicationBundleID, $0, strlen($0), &target) }
            guard created == noErr else { return nil }
            let status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
            let title = "Control \(name)"
            return switch Int(status) {
            case Int(noErr): Check(title: title, level: .ok, detail: "Allowed, so Lookout can jump to the agent's tab")
            case errAEEventNotPermitted:
                Check(title: title, level: .failed,
                      detail: "Denied. Allow Lookout under System Settings › Privacy & Security › Automation › \(name).")
            default: Check(title: title, level: .info, detail: "Not asked yet; macOS asks the first time Lookout jumps to a tab.")
            }
        }
    }
}

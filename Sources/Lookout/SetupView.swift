import AppKit
import LookoutCore
import ServiceManagement
import SwiftUI

/// Setup: what's installed on this Mac and on each ssh host, with install/reinstall/remove for each.
/// On first launch the footer's Install sets up everything available in one go.
struct SetupView: View {
    static let size = CGSize(width: 640, height: 780)

    enum Tab: String, CaseIterable {
        case agents = "Agents", hosts = "Remote Hosts", notifications = "Notifications", general = "General"
    }

    @ObservedObject var model: AppModel
    @ObservedObject var remotes: RemoteHosts
    var close: () -> Void

    @State private var busy: Set<String> = []
    /// Per-row result or error from the last action.
    @State private var messages: [String: String] = [:]
    @State private var notificationsAllowed: Bool?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var confirmRemoveAll = false
    @State private var tab = Tab.agents
    @AppStorage(Notifier.soundKey) private var sound = "Default"
    @AppStorage(Notifier.quietKey) private var quietHours = false
    @AppStorage(Notifier.quietStartKey) private var quietStart = Notifier.defaultQuietStart
    @AppStorage(Notifier.quietEndKey) private var quietEnd = Notifier.defaultQuietEnd
    @AppStorage(Presenting.key) private var silenceWhilePresenting = true
    @AppStorage(KeepAwake.key) private var keepAwake = false
    @AppStorage(GlobalShortcut.key) private var globalShortcut = true
    /// Bumped after file changes so installed states are re-read.
    @State private var revision = 0

    private let editors = VSCodeExtension.editors
    private var installer: HookInstaller { model.installer }

    private func present(_ source: AgentSource) -> Bool {
        FileManager.default.fileExists(atPath: LookoutPaths.home.appendingPathComponent(source == .claude ? ".claude" : ".codex").path)
    }

    private var firstRun: Bool { _ = revision; return model.needsSetup }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                header
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .frame(maxWidth: .infinity)
            }
            .padding([.horizontal, .top], 20).padding(.bottom, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case .agents: card { agentRows }
                    case .hosts: RemoteHostsSection(model: model, remotes: remotes)
                    case .notifications: card { notificationRows }
                    case .general: card { generalRows }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .task { notificationsAllowed = await Notifier.shared.isAuthorized() }
        .confirmationDialog("Remove Lookout's hooks from this Mac?", isPresented: $confirmRemoveAll) {
            Button("Remove Hooks", role: .destructive) { removeAll() }
        } message: {
            Text("Takes Lookout's entries out of ~/.claude/settings.json and ~/.codex/hooks.json and uninstalls the editor extensions. Remote hosts keep theirs; use Remove on each host.")
        }
    }

    // MARK: Header & footer

    private var header: some View {
        let active = model.sessions.values.filter { $0.status != .ended }
        let machines = Set(active.map { $0.host ?? "" }).count
        return HStack(spacing: 14) {
            Image(systemName: firstRun ? "binoculars.fill" : "checkmark")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(firstRun ? Color.accentColor : .green)
                .frame(width: 44, height: 44)
                .background((firstRun ? Color.accentColor : .green).opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(firstRun ? "Set up Lookout"
                     : "Lookout is watching \(active.count) agent\(active.count == 1 ? "" : "s") on \(max(machines, 1)) machine\(machines > 1 ? "s" : "")")
                    .font(.title3.weight(.semibold))
                Text("Keep launching agents however you like. Nothing is wrapped or relaunched.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Text("Backups of every edited file sit next to the original ·")
                Button("Show in Finder") { showBackups() }
                    .buttonStyle(.link)
            }
            .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if firstRun {
                Button("Later") { close() }.keyboardShortcut(.cancelAction)
                Button("Install") { Task { await installAll() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!busy.isEmpty)
            } else {
                Button("Remove all hooks…") { confirmRemoveAll = true }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                Button("Done") { close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: Tabs

    @ViewBuilder
    private var agentRows: some View {
        let _ = revision
        hookRow(.claude)
        Divider()
        hookRow(.codex)
        ForEach(editors, id: \.bundleID) { editor in
            Divider()
            editorRow(editor)
        }
    }

    @ViewBuilder
    private var notificationRows: some View {
        SetupRow(state: notificationsAllowed == true ? .ok : notificationsAllowed == false ? .warning : .unknown,
                 title: "Notifications",
                 subtitle: notificationsAllowed == false
                    ? "Not allowed · turn them on in System Settings › Notifications › Lookout"
                    : "Allowed · approvals, questions and finished turns",
                 message: messages["notifications"]) {
            if notificationsAllowed == false {
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
            } else {
                Button("Send a test") { Notifier.shared.postTest() }
            }
        }
        Divider()
        SetupRow(state: nil, title: "Notification sound", subtitle: "Plays with every notification, unless it has its own sound below.") {
            SoundPicker(selection: $sound)
        }
        Divider()
        eventSounds
        Divider()
        SetupRow(state: nil, title: "Quiet hours",
                 subtitle: "No notifications in these hours; the menu bar still shows who needs you. Mute a single project from its right-click menu.") {
            HStack(spacing: 6) {
                Toggle("", isOn: $quietHours).toggleStyle(.switch).controlSize(.small).labelsHidden()
                Group {
                    DatePicker("From", selection: time($quietStart), displayedComponents: .hourAndMinute)
                    Text("to")
                    DatePicker("To", selection: time($quietEnd), displayedComponents: .hourAndMinute)
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!quietHours)
            }
        }
        Divider()
        SetupRow(state: nil, title: "Silence while presenting",
                 subtitle: "No notifications while you share or record the screen, mirror a display, or play a Keynote or PowerPoint slideshow.") {
            Toggle("", isOn: $silenceWhilePresenting).toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
    }

    /// A sound for each agent and kind of notification, so you can tell them apart without looking.
    private var eventSounds: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Sounds by agent").fontWeight(.semibold)
                Text("Tell Claude Code from Codex, and a question from a finished turn, by ear.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("")
                    ForEach(AgentSource.allCases, id: \.self) { Text($0.displayName).font(.callout).foregroundStyle(.secondary) }
                }
                ForEach(Notifier.SoundEvent.allCases, id: \.self) { event in
                    GridRow {
                        Text(event.label).font(.callout)
                        ForEach(AgentSource.allCases, id: \.self) { source in
                            EventSoundPicker(key: Notifier.soundKey(source, event))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    @ViewBuilder
    private var generalRows: some View {
        SetupRow(state: nil, title: "Keep awake while agents work",
                 subtitle: "The Mac doesn't idle-sleep during a turn. The display still sleeps.") {
            Toggle("", isOn: $keepAwake).toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
        Divider()
        SetupRow(state: nil, title: "Open Lookout with \(GlobalShortcut.display)",
                 subtitle: "From any app. In the panel, ⌘Y and ⌘N answer the first request, ⌘1–⌘9 pick an option.") {
            Toggle("", isOn: $globalShortcut).toggleStyle(.switch).controlSize(.small).labelsHidden()
                .onChange(of: globalShortcut) { GlobalShortcut.shared.update() }
        }
        Divider()
        SetupRow(state: nil, title: "Launch at login",
                 subtitle: "Agents started before Lookout are still found, so this is just convenience.",
                 message: messages["login"]) {
            Toggle("", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                .toggleStyle(.switch).controlSize(.small)
                .labelsHidden()
        }
    }

    /// Minutes after midnight as a time of day, for a time picker.
    private func time(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: .now) ?? .now
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
    }

    private func hookRow(_ source: AgentSource) -> some View {
        let installed = installer.isInstalled(source)
        let found = model.sessions.values.filter { $0.host == nil && $0.source == source && $0.status != .ended }.count
        let file = source == .claude ? "~/.claude/settings.json" : "~/.codex/hooks.json"
        let subtitle: String
        if !present(source) {
            subtitle = "\(source.displayName) isn't set up on this Mac (no ~/.\(source.rawValue) folder)"
        } else if installed {
            let entries = installer.entryCount(source)
            subtitle = (source == .claude ? "Installed · \(entries) entries in \(file)" : "Installed · \(file)")
                + " · \(found) agent\(found == 1 ? "" : "s") found"
        } else {
            subtitle = "Not installed · adds hook entries to \(file)"
                + (source == .codex ? " and trusts them through Codex" : "")
        }
        let id = source.rawValue
        return SetupRow(state: installed ? .ok : present(source) ? .missing : .unknown,
                        title: "\(source.displayName) hooks", subtitle: subtitle, message: messages[id]) {
            if busy.contains(id) {
                ProgressView().controlSize(.small)
            } else if present(source) {
                installButton(installed: installed) { Task { await install(source) } }
            }
        }
    }

    private func editorRow(_ editor: (name: String, bundleID: String)) -> some View {
        let version = VSCodeExtension.installedVersion(bundleID: editor.bundleID)
        let id = editor.bundleID
        return SetupRow(state: version != nil ? .ok : .missing, title: "\(editor.name) extension",
                        subtitle: version.map { "Installed \($0) · lets Lookout jump to the exact window and terminal tab" }
                            ?? "\(editor.name) is installed but has no Lookout extension yet. Jumping will focus the window only.",
                        message: messages[id]) {
            if busy.contains(id) {
                ProgressView().controlSize(.small)
            } else {
                installButton(installed: version != nil) { Task { await installExtension(editor) } }
            }
        }
    }

    @ViewBuilder
    private func installButton(installed: Bool, action: @escaping () -> Void) -> some View {
        if installed {
            Button("Reinstall", action: action)
        } else {
            Button("Install", action: action).buttonStyle(.borderedProminent)
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.08)))
    }

    // MARK: Actions

    private func installAll() async {
        model.installHookBinary()
        for source in AgentSource.allCases where present(source) { await install(source) }
        for editor in editors { await installExtension(editor) }
        notificationsAllowed = await Notifier.shared.requestAuthorization()
        revision += 1
    }

    private func install(_ source: AgentSource) async {
        let id = source.rawValue
        busy.insert(id)
        defer { busy.remove(id); revision += 1 }
        model.installHookBinary()
        do {
            try installer.install(source)
            messages[id] = nil
        } catch {
            messages[id] = "❌ \(error.localizedDescription)"
            return
        }
        guard source == .codex else { return }
        let hooksPath = installer.codexHooksURL.path
        do {
            _ = try await Task.detached {
                let path = CodexTrust.shellPath()
                guard let codex = CodexTrust.findCodex(path: path) else { throw CodexTrustError.codexNotFound }
                return try CodexTrust.trustLookoutHooks(hooksFile: hooksPath, codexPath: codex, path: path)
            }.value
        } catch {
            messages[id] = "⚠️ Couldn't trust the hooks (\(error.localizedDescription)). Codex will ask you to review them on its next launch."
        }
    }

    private func installExtension(_ editor: (name: String, bundleID: String)) async {
        let id = editor.bundleID
        busy.insert(id)
        defer { busy.remove(id); revision += 1 }
        do {
            try await Task.detached { try VSCodeExtension.install(bundleID: editor.bundleID) }.value
            messages[id] = "Reload open \(editor.name) windows once to activate it."
        } catch {
            messages[id] = "❌ \(error.localizedDescription)"
        }
    }

    private func removeAll() {
        for source in AgentSource.allCases where installer.isInstalled(source) {
            do {
                try installer.uninstall(source)
                messages[source.rawValue] = "Removed"
            } catch {
                messages[source.rawValue] = "❌ \(error.localizedDescription)"
            }
        }
        for editor in editors where VSCodeExtension.isInstalled(bundleID: editor.bundleID) {
            do {
                try VSCodeExtension.uninstall(bundleID: editor.bundleID)
                messages[editor.bundleID] = "Removed"
            } catch {
                messages[editor.bundleID] = "❌ \(error.localizedDescription)"
            }
        }
        revision += 1
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            messages["login"] = nil
        } catch {
            messages["login"] = "❌ \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func showBackups() {
        let files = [installer.claudeSettingsURL, installer.codexHooksURL]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if files.isEmpty {
            NSWorkspace.shared.open(LookoutPaths.home)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(files)
        }
    }
}

/// One line in a Setup card: status icon, title and subtitle, actions on the right.
/// "Default", "None" or a macOS sound; plays the sound when picked.
struct SoundPicker: View {
    @Binding var selection: String
    /// The first choice's label and tag; per-event pickers use it for "the main sound".
    var inherit: (label: String, tag: String) = ("Default", "Default")

    var body: some View {
        Picker("", selection: $selection) {
            Text(inherit.label).tag(inherit.tag)
            if inherit.tag != "Default" { Text("Default").tag("Default") }
            Text("None").tag("None")
            Divider()
            ForEach(Notifier.systemSounds, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .onChange(of: selection) { _, name in NSSound(named: name)?.play() } // preview
    }
}

private struct EventSoundPicker: View {
    @AppStorage private var selection: String

    init(key: String) { _selection = AppStorage(wrappedValue: "", key) }

    var body: some View { SoundPicker(selection: $selection, inherit: ("Same as above", "")) }
}

struct SetupRow<Actions: View>: View {
    enum State { case ok, missing, warning, failed, unknown }

    let state: State?
    let title: String
    var titleDetail: Text?
    let subtitle: String
    var message: String?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let state {
                icon(state).frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.semibold)
                    if let titleDetail { titleDetail }
                }
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message {
                    Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) { actions() }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    @ViewBuilder
    private func icon(_ state: State) -> some View {
        switch state {
        case .ok: Image(systemName: "checkmark.circle").foregroundStyle(.green)
        case .missing: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        case .warning: Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
        case .failed: Circle().fill(.red).frame(width: 8, height: 8)
        case .unknown: Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }
}

import AppKit
import LookoutCore
import SwiftUI

/// Main window: filters on the left, agents in the middle, details of the selected agent on the right.
struct DashboardView: View {
    @ObservedObject var model: AppModel
    var openSetup: () -> Void

    @State private var filter: Filter? = .all
    @State private var selectedID: AgentSession.ID?

    enum Filter: Hashable {
        case all, attention, working, done, ended
        case project(String) // cwd

        var title: String {
            switch self {
            case .all: "All Agents"
            case .attention: "Needs You"
            case .working: "Working"
            case .done: "Finished"
            case .ended: "Ended"
            case .project(let cwd): URL(fileURLWithPath: cwd).lastPathComponent
            }
        }

        var icon: String {
            switch self {
            case .all: "binoculars"
            case .attention: "exclamationmark.bubble"
            case .working: "gearshape.2"
            case .done: "checkmark.circle"
            case .ended: "moon.zzz"
            case .project: "folder"
            }
        }

        func matches(_ s: AgentSession) -> Bool {
            switch self {
            case .all: true
            case .attention: s.status.needsAttention
            case .working: s.status == .working
            case .done: s.status == .finished || s.status == .idle
            case .ended: s.status == .ended
            case .project(let cwd): s.cwd == cwd
            }
        }
    }

    private var visibleSessions: [AgentSession] {
        model.sortedSessions.filter { (filter ?? .all).matches($0) }
    }

    private var selected: AgentSession? {
        selectedID.flatMap { model.sessions[$0] }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            agentList
        } detail: {
            if let session = selected {
                AgentDetailView(session: session) { model.focus(session) }
            } else {
                ContentUnavailableView("No Agent Selected", systemImage: "binoculars",
                                       description: Text("Select an agent to see its details. Double-click to jump to its terminal."))
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if model.sessions.values.contains(where: { $0.status == .ended }) {
                    Button("Clear Ended", systemImage: "trash") { model.clearEnded() }
                }
                Button("Setup", systemImage: "wrench.and.screwdriver") { openSetup() }
            }
        }
    }

    // MARK: Columns

    private var sidebar: some View {
        let sessions = Array(model.sessions.values)
        let projects = Dictionary(grouping: sessions, by: \.cwd)
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        return List(selection: $filter) {
            Section("Status") {
                ForEach([Filter.all, .attention, .working, .done, .ended], id: \.self) { f in
                    sidebarRow(f, count: sessions.filter(f.matches).count)
                }
            }
            if !projects.isEmpty {
                Section("Projects") {
                    ForEach(projects, id: \.key) { cwd, group in
                        sidebarRow(.project(cwd), count: group.count).help(cwd)
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 170, ideal: 190)
    }

    private func sidebarRow(_ f: Filter, count: Int) -> some View {
        Label(f.title, systemImage: f.icon)
            .badge(count)
            .tag(f)
    }

    private var agentList: some View {
        List(visibleSessions, selection: $selectedID) { session in
            SessionSummary(session: session)
                .padding(.vertical, 4)
                .tag(session.id)
        }
        .contextMenu(forSelectionType: AgentSession.ID.self) { ids in
            if let id = ids.first, let session = model.sessions[id] {
                Button("Focus Terminal") { model.focus(session) }
                Button("Copy Directory") { copy(session.cwd) }
                Button("Copy Session ID") { copy(session.sessionID) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let session = model.sessions[id] { model.focus(session) }
        }
        .overlay {
            if visibleSessions.isEmpty {
                ContentUnavailableView(model.sessions.isEmpty ? "No Agents Yet" : "Nothing Here",
                                       systemImage: "binoculars",
                                       description: Text(model.sessions.isEmpty
                                           ? "Start Claude Code or Codex in any terminal."
                                           : "No agents match this filter."))
            }
        }
        .navigationTitle((filter ?? .all).title)
        .navigationSplitViewColumnWidth(min: 320, ideal: 400)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct AgentDetailView: View {
    let session: AgentSession
    let focus: () -> Void

    private var hostName: String? {
        guard let id = session.hostBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if session.status != .ended {
                    Button(action: focus) {
                        Label(hostName.map { "Open in \($0)" } ?? "Focus Terminal", systemImage: "arrow.up.forward.app")
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                }
                if let detail = session.detail {
                    textBlock(title: session.status.needsAttention ? "Waiting On" : "Latest", text: detail)
                }
                if let prompt = session.lastPrompt {
                    textBlock(title: "Last Prompt", text: prompt)
                }
                info
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            HostIcon(bundleID: session.hostBundleID, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(session.projectName).font(.title2.weight(.semibold))
                    SourceBadge(source: session.source)
                }
                HStack(spacing: 6) {
                    StatusDot(status: session.status)
                    Text(session.status.label).foregroundStyle(session.status.color)
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text("· for \(SessionSummary.relative(session.statusSince))").foregroundStyle(.secondary)
                    }
                }
                .font(.callout.weight(.medium))
            }
        }
    }

    private func textBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Text(text)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Details").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                row("Directory", session.cwd)
                row("App", hostName ?? session.hostBundleID)
                row("Terminal", [session.termProgram, session.tty].compactMap { $0 }.joined(separator: " · "))
                row("Process", session.agentPID.map { "PID \($0)" })
                row("Session", session.sessionID)
                row("Last event", session.lastEventAt.formatted(date: .omitted, time: .standard))
            }
            .font(.callout)
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label).foregroundStyle(.secondary)
                Text(value).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            }
        }
    }
}

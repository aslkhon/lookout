import AppKit
import LookoutCore
import SwiftUI

/// Main window: filters on the left, agents by status or by project in the middle, details of the
/// selected agent on the right.
struct DashboardView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var remotes: RemoteHosts
    var openSetup: () -> Void

    enum Layout: String, CaseIterable { case byStatus = "By status", byProject = "By project" }
    enum HostFilter: Hashable { case all, local, remote(String) }

    @AppStorage("dashboardLayout") private var layout: Layout = .byStatus
    @AppStorage("dashboardShowsSidebar") private var showsSidebar = true
    @AppStorage("dashboardShowsDetail") private var showsDetail = true
    @State private var status: AgentStatus.Group?
    @State private var hostFilter: HostFilter = .all
    @State private var source: AgentSource?
    @State private var query = ""
    @State private var selectedID: AgentSession.ID?
    @State private var collapsed: Set<String> = []

    private var all: [AgentSession] { model.sortedSessions }

    /// Sessions passing the host and agent filters (the status filter and ended agents aside).
    private func scoped(_ sessions: [AgentSession]) -> [AgentSession] {
        sessions.filter { s in
            let hostOK: Bool = switch hostFilter {
            case .all: true
            case .local: s.host == nil
            case .remote(let host): s.host == host
            }
            return hostOK && (source == nil || s.source == source) && s.matches(query)
        }
    }

    private var visible: [AgentSession] {
        scoped(all).filter { s in
            if let status { return s.status.group == status }
            return s.status != .ended // ended agents only show under their own filter
        }
    }

    private var hiddenEnded: Int {
        status == nil ? scoped(all).filter { $0.status == .ended }.count : 0
    }

    private var selected: AgentSession? { selectedID.flatMap { model.sessions[$0] } }

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { showsSidebar ? .all : .detailOnly },
            set: { showsSidebar = $0 != .detailOnly })) {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            agentList
                .navigationSplitViewColumnWidth(min: 460, ideal: 640)
                .toolbar { toolbar }
        }
        .navigationTitle("Lookout")
        .navigationSubtitle(countLabel)
        .searchable(text: $query, placement: .toolbar, prompt: "Project, prompt or command")
        .inspector(isPresented: $showsDetail) {
            Group {
                if let session = selected {
                    AgentDetailView(session: session) { model.focus(session) }
                } else {
                    ContentUnavailableView("No Agent Selected", systemImage: "binoculars",
                                           description: Text("Select an agent to see its details. Double-click to jump to its terminal."))
                }
            }
            .inspectorColumnWidth(min: 280, ideal: 330, max: 440)
        }
    }

    // MARK: Sidebar

    /// One filter in the sidebar. Each section keeps its own choice, so the List selection holds one item per section.
    private enum Filter: Hashable {
        case status(AgentStatus.Group?)
        case host(HostFilter)
        case source(AgentSource?)
    }

    private var filterSelection: Binding<Set<Filter>> {
        Binding {
            [.status(status), .host(hostFilter), .source(source)]
        } set: { new in
            // A click selects just that row; apply it and keep the other sections' choices.
            for filter in new.subtracting([.status(status), .host(hostFilter), .source(source)]) {
                switch filter {
                case .status(let value): status = value
                case .host(let value): hostFilter = value
                case .source(let value): source = value
                }
            }
        }
    }

    private var sidebar: some View {
        List(selection: filterSelection) {
            Section("Status") {
                Label("All Agents", systemImage: "square.stack")
                    .badge(all.count)
                    .tag(Filter.status(nil))
                ForEach(AgentStatus.Group.allCases, id: \.self) { group in
                    let count = all.filter { $0.status.group == group }.count
                    Label { Text(group.title) } icon: { StatusDot(status: group.dotStatus, size: 8) }
                        .badge(group == .needsYou && count > 0 ? Text("\(count)").foregroundColor(.orange) : Text("\(count)"))
                        .tag(Filter.status(group))
                }
            }
            Section("Hosts") {
                Label("All Hosts", systemImage: "network")
                    .badge(all.count)
                    .tag(Filter.host(.all))
                Label("This Mac", systemImage: "desktopcomputer")
                    .badge(all.filter { $0.host == nil }.count)
                    .tag(Filter.host(.local))
                ForEach(remotes.hosts, id: \.self) { host in
                    Label { Text(host) } icon: {
                        Image(systemName: "globe").foregroundStyle(remotes.states[host].color)
                    }
                    .badge(all.filter { $0.host == host }.count)
                    .help(remotes.states[host].label)
                    .tag(Filter.host(.remote(host)))
                }
            }
            Section("Agent") {
                Label("Any Agent", systemImage: "circle.grid.2x1")
                    .badge(all.count)
                    .tag(Filter.source(nil))
                ForEach(AgentSource.allCases, id: \.self) { s in
                    Label(s.displayName, systemImage: s == .claude ? "asterisk" : "chevron.left.forwardslash.chevron.right")
                        .badge(all.filter { $0.source == s }.count)
                        .tag(Filter.source(s))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(action: openSetup) {
                Label("Setup", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Picker("Layout", selection: $layout) {
                ForEach(Layout.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Group agents by status or by project")
        }
        ToolbarItem {
            if layout == .byStatus {
                Button("Clear Ended", systemImage: "clear") { model.clearEnded() }
                    .disabled(!all.contains { $0.status == .ended })
                    .help("Remove ended agents from the list")
            } else {
                Button(collapsed.isEmpty ? "Collapse All" : "Expand All",
                       systemImage: collapsed.isEmpty ? "rectangle.compress.vertical" : "rectangle.expand.vertical") {
                    collapsed = collapsed.isEmpty ? Set(projects.map(\.name)) : []
                }
                .help(collapsed.isEmpty ? "Collapse all projects" : "Expand all projects")
            }
        }
        ToolbarItem {
            Button(showsDetail ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right") {
                withAnimation { showsDetail.toggle() }
            }
            .keyboardShortcut("0", modifiers: [.option, .command])
            .help(showsDetail ? "Hide Inspector" : "Show Inspector")
        }
    }

    private var countLabel: String {
        let hidden = hiddenEnded > 0 ? " · \(hiddenEnded) ended hidden" : ""
        if layout == .byProject {
            return "\(projects.count) project\(projects.count == 1 ? "" : "s") · \(visible.count) of \(all.count) agents"
        }
        return "\(visible.count) shown\(hidden)"
    }

    // MARK: Content

    // Rows have one fixed height: macOS List caches row heights and clipped rows whose height changed.
    private var agentList: some View {
        List(selection: $selectedID) {
            switch layout {
            case .byStatus: statusSections
            case .byProject: projectSections
            }
        }
        .listStyle(.inset)
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
            if visible.isEmpty {
                ContentUnavailableView(all.isEmpty ? "No Agents Yet" : "Nothing Here",
                                       systemImage: "binoculars",
                                       description: Text(all.isEmpty
                                           ? "Start Claude Code or Codex in any terminal."
                                           : "No agents match these filters."))
            }
        }
    }

    @ViewBuilder
    private var statusSections: some View {
        let groups = Dictionary(grouping: visible, by: \.status.group)
        ForEach(AgentStatus.Group.allCases, id: \.self) { group in
            if let members = groups[group] {
                Section {
                    ForEach(members) { session in
                        StatusRow(session: session)
                    }
                } header: {
                    Text("\(group.title)  \(members.count)").foregroundStyle(group.color)
                }
            }
        }
    }

    private var projects: [(name: String, sessions: [AgentSession])] {
        Dictionary(grouping: visible, by: \.projectName)
            .map { ($0.key, $0.value) }
            .sorted { a, b in
                let ra = a.sessions.map(\.status.rank).min() ?? 0, rb = b.sessions.map(\.status.rank).min() ?? 0
                return (ra, a.name.lowercased()) < (rb, b.name.lowercased())
            }
    }

    @ViewBuilder
    private var projectSections: some View {
        let endedByProject = Dictionary(grouping: scoped(all).filter { $0.status == .ended }, by: \.projectName)
        ForEach(projects, id: \.name) { project in
            let expanded = !collapsed.contains(project.name)
            Section {
                if expanded {
                    ForEach(project.sessions) { session in
                        ProjectRow(session: session)
                    }
                }
            } header: {
                Button {
                    withAnimation { if expanded { collapsed.insert(project.name) } else { collapsed.remove(project.name) } }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(.secondary)
                            .frame(width: 10)
                        ProjectHeader(name: project.name, sessions: project.sessions,
                                      endedHidden: status == nil ? endedByProject[project.name]?.count ?? 0 : 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension RemoteHosts.State? {
    var color: Color {
        switch self {
        case .connected: .green
        case .connecting, nil: .yellow
        case .failed: .red
        }
    }

    var label: String {
        switch self {
        case .connected: "Connected"
        case .connecting, nil: "Connecting…"
        case .failed(let error): "Not connected: \(error)"
        }
    }
}

extension RemoteHosts.State {
    var color: Color { Optional(self).color }
}

// MARK: Rows

/// "Needs approval · Bash: npm test" plus the prompt (and turn time) underneath.
private struct StatusText: View {
    let session: AgentSession
    /// The row's title, not repeated here.
    var title: String?
    @Environment(\.backgroundProminence) private var prominence
    private var selected: Bool { prominence == .increased }

    var body: some View {
        let secondary = [session.name, session.lastPrompt].compactMap { $0 }.first { $0 != title }
        let detail = session.detail ?? secondary
        let below = [session.detail != nil ? secondary : nil,
                     session.status == .finished ? session.lastTurnDuration.map { "took \(Format.duration($0))" } : nil]
            .compactMap { $0 }.joined(separator: " · ")
        VStack(alignment: .leading, spacing: 2) {
            (Text(session.status.label)
                .foregroundColor(selected ? .primary : session.status.color)
                .fontWeight(.medium)
             + Text(detail.map { " · \($0)" } ?? "")
                .foregroundColor(session.status.group == .idle ? .secondary : .primary))
                .lineLimit(1)
            if !below.isEmpty {
                Text(below).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .font(.callout)
    }
}

private struct TimeLabel: View {
    let session: AgentSession
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Ticking { now in
            Text(Format.ago(session.statusSince, now: now))
                .font(.callout.weight(session.needsYou ? .semibold : .regular))
                .foregroundStyle(session.needsYou && prominence != .increased ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .monospacedDigit()
        }
        .frame(width: 36, alignment: .trailing)
    }
}

/// Rows keep one height (see `agentList`).
private let rowHeight: CGFloat = 36

private struct StatusRow: View {
    let session: AgentSession
    @Environment(\.backgroundProminence) private var prominence
    private var selected: Bool { prominence == .increased }

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(status: session.status)
            HStack(spacing: 5) {
                Text(session.projectName).fontWeight(.semibold).lineLimit(1)
                if let branch = session.branch {
                    Text("/ \(branch)").foregroundStyle(.secondary).lineLimit(1)
                }
                SourceChip(source: session.source, onAccent: selected)
            }
            .frame(width: 220, alignment: .leading)
            StatusText(session: session)
            Spacer(minLength: 8)
            HostChip(host: session.host, onAccent: selected)
            TimeLabel(session: session)
        }
        .frame(height: rowHeight)
        .opacity(session.status == .ended ? 0.6 : 1)
        .help(session.cwd)
    }
}

private struct ProjectRow: View {
    let session: AgentSession
    @Environment(\.backgroundProminence) private var prominence
    private var selected: Bool { prominence == .increased }

    private var title: String { session.name ?? session.branch ?? session.source.displayName }

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(status: session.status)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .fontWeight(.semibold).lineLimit(1)
                HStack(spacing: 4) {
                    SourceChip(source: session.source, onAccent: selected)
                    if let host = session.host {
                        Chip(text: host, style: selected ? .onAccent : .remote)
                    } else if let app = session.appName {
                        Chip(text: app, style: selected ? .onAccent : .neutral)
                    }
                }
            }
            .frame(width: 220, alignment: .leading)
            StatusText(session: session, title: title)
            Spacer(minLength: 8)
            TimeLabel(session: session)
        }
        .frame(height: rowHeight)
        .opacity(session.status == .ended ? 0.6 : 1)
        .help(session.cwd)
    }
}

private struct ProjectHeader: View {
    let name: String
    let sessions: [AgentSession]
    let endedHidden: Int

    var body: some View {
        let hosts = Array(Set(sessions.map { $0.host ?? "" })).sorted()
        let cwds = Set(sessions.map(\.cwd))
        let counts = Dictionary(grouping: sessions, by: \.status.group).mapValues(\.count)
        HStack(spacing: 8) {
            Text(name).font(.body.weight(.semibold)).foregroundStyle(.primary)
            ForEach(hosts, id: \.self) { HostChip(host: $0.isEmpty ? nil : $0) }
            if cwds.count == 1, let cwd = cwds.first {
                Text((cwd as NSString).abbreviatingWithTildeInPath)
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            ForEach(AgentStatus.Group.allCases, id: \.self) { group in
                if let count = counts[group] {
                    HStack(spacing: 4) {
                        StatusDot(status: group.dotStatus, size: 6)
                        Text("\(count)")
                    }
                    .foregroundStyle(group == .needsYou ? .orange : .secondary)
                }
            }
            if endedHidden > 0 {
                Text("· \(endedHidden) ended hidden").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .textCase(nil)
        .padding(.vertical, 4)
    }
}

// MARK: Detail

struct AgentDetailView: View {
    let session: AgentSession
    let focus: () -> Void

    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if session.status != .ended {
                    Button(action: focus) {
                        Label(openTitle, systemImage: "arrow.up.forward")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                }
                if session.needsYou { waitingBox }
                if let prompt = session.lastPrompt {
                    block("Last prompt") {
                        Text(prompt)
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                block("Details") { details }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var openTitle: String {
        if let app = session.appName { return "Open in \(app)" }
        return "Focus Terminal"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(session.projectName).font(.title2.weight(.semibold))
                if let branch = session.branch {
                    Text("/ \(branch)").font(.title3).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            HStack(spacing: 5) {
                SourceChip(source: session.source)
                if let app = session.appName {
                    Chip(text: [app, session.tty.map { $0.hasPrefix("/dev/") ? String($0.dropFirst(5)) : $0 }].compactMap { $0 }.joined(separator: " · "))
                }
                HostChip(host: session.host)
            }
            if let name = session.name {
                Text(name).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var waitingBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(.orange).frame(width: 7, height: 7)
                Text(session.status.label).fontWeight(.semibold).foregroundStyle(.orange)
                Ticking(interval: 1) { now in
                    Text("· \(Format.duration(now.timeIntervalSince(session.statusSince)))").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            if let command = session.tool?.argument {
                CodeBlock(text: command, lineLimit: 8)
            } else if let detail = session.detail {
                Text(detail).textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.orange.opacity(0.4)))
    }

    private func block<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: title)
            content()
        }
    }

    private var details: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
            row("Directory", session.host == nil ? (session.cwd as NSString).abbreviatingWithTildeInPath : session.cwd, mono: true)
            row("Branch", session.branch, mono: true)
            row("PID", session.agentPID.map(String.init), mono: true)
            GridRow {
                Text("Session").foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(shortID).font(.system(.callout, design: .monospaced)).help(session.sessionID)
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(session.sessionID, forType: .string)
                        copied = true
                    }
                    .controlSize(.small)
                }
            }
            if let started = session.startedAt {
                GridRow {
                    Text("Started").foregroundStyle(.secondary)
                    Ticking { now in
                        Text("\(started.formatted(date: .omitted, time: .shortened)) · \(Format.ago(started, now: now)) ago")
                    }
                }
            }
            row("Last event", session.lastEventAt.formatted(date: .omitted, time: .shortened))
        }
        .font(.callout)
        .onChange(of: session.id) { copied = false }
    }

    private var shortID: String {
        let id = session.sessionID
        return id.count > 12 ? "\(id.prefix(4))…\(id.suffix(4))" : id
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?, mono: Bool = false) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label).foregroundStyle(.secondary)
                Text(value)
                    .font(mono ? .system(.callout, design: .monospaced) : .callout)
                    .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            }
        }
    }
}

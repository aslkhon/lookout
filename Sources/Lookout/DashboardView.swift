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
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
        } content: {
            VStack(spacing: 0) {
                contentHeader
                agentList
            }
            .navigationSplitViewColumnWidth(min: 480, ideal: 620)
        } detail: {
            if let session = selected {
                AgentDetailView(session: session) { model.focus(session) }
            } else {
                ContentUnavailableView("No Agent Selected", systemImage: "binoculars",
                                       description: Text("Select an agent to see its details. Double-click to jump to its terminal."))
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    sidebarSection("Status")
                    filterRow("All agents", count: all.count, selected: status == nil) { status = nil }
                    ForEach(AgentStatus.Group.allCases, id: \.self) { group in
                        filterRow(group.title, count: all.filter { $0.status.group == group }.count,
                                  selected: status == group, highlightCount: group == .needsYou) {
                            status = group
                        } icon: {
                            StatusDot(status: group.dotStatus, size: 7)
                        }
                    }

                    sidebarSection("Hosts")
                    filterRow("All hosts", count: all.count, selected: hostFilter == .all) { hostFilter = .all }
                    filterRow("This Mac", count: all.filter { $0.host == nil }.count, selected: hostFilter == .local) {
                        hostFilter = .local
                    } icon: {
                        Image(systemName: "desktopcomputer").imageScale(.small).foregroundStyle(.secondary)
                    }
                    ForEach(remotes.hosts, id: \.self) { host in
                        filterRow(host, count: all.filter { $0.host == host }.count,
                                  selected: hostFilter == .remote(host), connection: remotes.states[host]) {
                            hostFilter = .remote(host)
                        } icon: {
                            Image(systemName: "globe").imageScale(.small).foregroundStyle(.teal)
                        }
                    }

                    sidebarSection("Agent")
                    filterRow("Both", count: all.count, selected: source == nil) { source = nil }
                    ForEach(AgentSource.allCases, id: \.self) { s in
                        filterRow(s.displayName, count: all.filter { $0.source == s }.count, selected: source == s) {
                            source = s
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 8)
            }
            Button(action: openSetup) {
                Label("Setup", systemImage: "gearshape")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .padding(14)
        }
    }

    private func sidebarSection(_ title: String) -> some View {
        SectionTitle(title: title)
            .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 4)
    }

    private func filterRow(_ title: String, count: Int, selected: Bool, highlightCount: Bool = false,
                           connection: RemoteHosts.State? = nil,
                           action: @escaping () -> Void) -> some View {
        filterRow(title, count: count, selected: selected, highlightCount: highlightCount,
                  connection: connection, action: action) { EmptyView() }
    }

    private func filterRow<Icon: View>(_ title: String, count: Int, selected: Bool, highlightCount: Bool = false,
                                       connection: RemoteHosts.State? = nil,
                                       action: @escaping () -> Void, @ViewBuilder icon: () -> Icon) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                icon()
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                if let connection {
                    Circle().fill(connection.color).frame(width: 6, height: 6)
                }
                Text("\(count)")
                    .foregroundStyle(highlightCount && count > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .monospacedDigit()
            }
            .font(.callout.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(selected ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Content

    private var contentHeader: some View {
        HStack(spacing: 10) {
            Picker("Layout", selection: $layout) {
                ForEach(Layout.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            TextField("Project, prompt or command", text: $query)
                .textFieldStyle(.roundedBorder)
            Text(countLabel)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize()
            if layout == .byStatus {
                Button("Clear ended") { model.clearEnded() }
                    .disabled(!all.contains { $0.status == .ended })
            } else {
                Button(collapsed.isEmpty ? "Collapse all" : "Expand all") {
                    collapsed = collapsed.isEmpty ? Set(projects.map(\.name)) : []
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var countLabel: String {
        let hidden = hiddenEnded > 0 ? " · \(hiddenEnded) ended hidden" : ""
        if layout == .byProject {
            return "\(projects.count) project\(projects.count == 1 ? "" : "s") · \(visible.count) of \(all.count) agents"
        }
        return "\(visible.count) shown\(hidden)"
    }

    // A ScrollView rather than List: macOS List caches row heights and clips rows after filtering.
    private var agentList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    switch layout {
                    case .byStatus: statusSections
                    case .byProject: projectSections
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { moveSelection(-1, proxy); return .handled }
            .onKeyPress(.downArrow) { moveSelection(1, proxy); return .handled }
            .onKeyPress(.return) {
                if let session = selected { model.focus(session) }
                return .handled
            }
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

    /// Visible rows in display order, for arrow-key navigation.
    private var orderedIDs: [AgentSession.ID] {
        switch layout {
        case .byStatus:
            let groups = Dictionary(grouping: visible, by: \.status.group)
            return AgentStatus.Group.allCases.flatMap { groups[$0] ?? [] }.map(\.id)
        case .byProject:
            return projects.filter { !collapsed.contains($0.name) }.flatMap(\.sessions).map(\.id)
        }
    }

    private func moveSelection(_ delta: Int, _ proxy: ScrollViewProxy) {
        let ids = orderedIDs
        guard !ids.isEmpty else { return }
        let index = selectedID.flatMap { ids.firstIndex(of: $0) }.map { $0 + delta } ?? (delta > 0 ? 0 : ids.count - 1)
        selectedID = ids[min(max(index, 0), ids.count - 1)]
        proxy.scrollTo(selectedID)
    }

    @ViewBuilder
    private var statusSections: some View {
        let groups = Dictionary(grouping: visible, by: \.status.group)
        ForEach(AgentStatus.Group.allCases, id: \.self) { group in
            if let members = groups[group] {
                SectionTitle(title: group.title, count: members.count, color: group.color)
                    .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 4)
                ForEach(members) { session in
                    row(session) { StatusRow(session: session, selected: selectedID == session.id) }
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
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    if expanded { collapsed.insert(project.name) } else { collapsed.remove(project.name) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                        ProjectHeader(name: project.name, sessions: project.sessions,
                                      endedHidden: status == nil ? endedByProject[project.name]?.count ?? 0 : 0)
                    }
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded {
                    ForEach(project.sessions) { session in
                        row(session) { ProjectRow(session: session, selected: selectedID == session.id) }
                    }
                }
            }
            .padding(6)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .padding(.top, 8)
        }
    }

    /// A selectable row: click selects, double-click (or Return) jumps to the terminal.
    private func row<Content: View>(_ session: AgentSession, @ViewBuilder content: () -> Content) -> some View {
        let isSelected = selectedID == session.id
        return content()
            .padding(.horizontal, 10)
            .background {
                RoundedRectangle(cornerRadius: 7).fill(
                    isSelected ? Color.accentColor : session.needsYou ? Color.orange.opacity(0.12) : .clear)
            }
            .foregroundStyle(isSelected ? .white : .primary)
            .contentShape(Rectangle())
            .id(session.id)
            .onTapGesture(count: 2) { model.focus(session) }
            .simultaneousGesture(TapGesture().onEnded { selectedID = session.id })
            .contextMenu {
                Button("Focus Terminal") { model.focus(session) }
                Button("Copy Directory") { copy(session.cwd) }
                Button("Copy Session ID") { copy(session.sessionID) }
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
}

extension RemoteHosts.State {
    var color: Color { Optional(self).color }
}

// MARK: Rows

/// "Needs approval · Bash: npm test" plus the prompt (and turn time) underneath.
private struct StatusText: View {
    let session: AgentSession
    let selected: Bool
    /// The row's title, not repeated here.
    var title: String?

    var body: some View {
        let secondary = [session.name, session.lastPrompt].compactMap { $0 }.first { $0 != title }
        let detail = session.detail ?? secondary
        let below = [session.detail != nil ? secondary : nil,
                     session.status == .finished ? session.lastTurnDuration.map { "took \(Format.duration($0))" } : nil]
            .compactMap { $0 }.joined(separator: " · ")
        VStack(alignment: .leading, spacing: 2) {
            (Text(session.status.label)
                .foregroundColor(selected ? .white : session.status.color)
                .fontWeight(.medium)
             + Text(detail.map { " · \($0)" } ?? "")
                .foregroundColor(selected ? .white : .primary.opacity(session.status.group == .idle ? 0.6 : 0.9)))
                .lineLimit(1)
            if !below.isEmpty {
                Text(below).foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary)).lineLimit(1)
            }
        }
        .font(.callout)
    }
}

private struct TimeLabel: View {
    let session: AgentSession
    let selected: Bool

    var body: some View {
        Ticking { now in
            Text(Format.ago(session.statusSince, now: now))
                .font(.callout.weight(session.needsYou ? .semibold : .regular))
                .foregroundStyle(selected ? AnyShapeStyle(.white)
                                 : session.needsYou ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .monospacedDigit()
        }
        .frame(width: 36, alignment: .trailing)
    }
}

private struct StatusRow: View {
    let session: AgentSession
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(status: session.status)
            HStack(spacing: 5) {
                Text(session.projectName).fontWeight(.semibold).lineLimit(1)
                if let branch = session.branch {
                    Text("/ \(branch)").foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                SourceChip(source: session.source, onAccent: selected)
            }
            .frame(width: 220, alignment: .leading)
            StatusText(session: session, selected: selected)
            Spacer(minLength: 8)
            HostChip(host: session.host, onAccent: selected)
            TimeLabel(session: session, selected: selected)
        }
        .padding(.vertical, 6)
        .opacity(session.status == .ended ? 0.6 : 1)
        .help(session.cwd)
    }
}

private struct ProjectRow: View {
    let session: AgentSession
    let selected: Bool

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
            StatusText(session: session, selected: selected, title: title)
            Spacer(minLength: 8)
            TimeLabel(session: session, selected: selected)
        }
        .padding(.vertical, 4)
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
                    Chip(text: [app, session.tty.map { ($0 as NSString).lastPathComponent }].compactMap { $0 }.joined(separator: " · "))
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

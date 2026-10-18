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
    /// Drives the split view; a binding computed from @AppStorage loses the toggle's animation.
    @State private var columns: NavigationSplitViewVisibility =
        UserDefaults.standard.object(forKey: "dashboardShowsSidebar") as? Bool == false ? .detailOnly : .all
    @AppStorage("dashboardShowsDetail") private var showsDetail = true
    @AppStorage("dashboardOnTop") private var onTop = false
    @State private var status: AgentStatus.Group?
    @State private var hostFilter: HostFilter = .all
    @State private var source: AgentSource?
    @State private var query = ""
    @State private var selectedID: AgentSession.ID?
    @State private var collapsed: Set<String> = []
    /// The project whose icon picker is open. Kept here: list rows are rebuilt as agents update.
    @State private var editingIcon: String?
    @State private var listWidth: CGFloat = 0

    /// Wide enough for project cards side by side; narrow enough for compact rows.
    private static let gridWidth: CGFloat = 940
    private static let compactWidth: CGFloat = 560
    private static let toolbarSearchWidth: CGFloat = 600
    private var showsGrid: Bool { layout == .byProject && listWidth >= Self.gridWidth }

    private var all: [AgentSession] { model.sortedSessions }

    /// Sessions passing the host and agent filters (the status filter and ended agents aside).
    private func scoped(_ sessions: [AgentSession]) -> [AgentSession] {
        sessions.filter { inScope($0, host: hostFilter, source: source) }
    }

    private func inScope(_ s: AgentSession, host: HostFilter, source: AgentSource?) -> Bool {
        let hostOK: Bool = switch host {
        case .all: true
        case .local: s.host == nil
        case .remote(let name): s.host == name
        }
        return hostOK && (source == nil || s.source == source) && s.matches(query)
    }

    /// Ended agents only show under their own filter.
    private func hasStatus(_ s: AgentSession, _ status: AgentStatus.Group?) -> Bool {
        status.map { s.status.group == $0 } ?? (s.status != .ended)
    }

    private var visible: [AgentSession] {
        all.filter { hasStatus($0, status) && inScope($0, host: hostFilter, source: source) }
    }

    // Sidebar counts: what the list would show for that row, with the other sections' current choices.
    private func count(status: AgentStatus.Group?) -> Int {
        all.filter { hasStatus($0, status) && inScope($0, host: hostFilter, source: source) }.count
    }

    private func count(host: HostFilter) -> Int {
        all.filter { hasStatus($0, status) && inScope($0, host: host, source: source) }.count
    }

    private func count(source: AgentSource?) -> Int {
        all.filter { hasStatus($0, status) && inScope($0, host: hostFilter, source: source) }.count
    }

    private var hiddenEnded: Int {
        status == nil ? scoped(all).filter { $0.status == .ended }.count : 0
    }

    private var selected: AgentSession? { selectedID.flatMap { model.sessions[$0] } }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
                .frame(minWidth: 200) // the custom toolbar toggle otherwise lets the column shrink to the toolbar's width
                .navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 280)
                .toolbar(removing: .sidebarToggle)
                .toolbar {
                    // Next to the traffic lights, as in Notes and Mail.
                    ToolbarItem { sidebarToggle }
                    if #available(macOS 26, *) {
                        ToolbarSpacer(.flexible) // keeps the toggle by the traffic lights without shrinking the sidebar
                    }
                }
        } detail: {
            agentList
                .toolbar { toolbar }
        }
        .sheet(isPresented: Binding(get: { editingIcon != nil }, set: { if !$0 { editingIcon = nil } })) {
            if let project = editingIcon {
                ProjectStylePicker(project: project) { editingIcon = nil }
            }
        }
        .navigationTitle("Lookout")
        .onChange(of: columns) { showsSidebar = columns != .detailOnly }
        .navigationSubtitle(countLabel)
        .background(FloatingWindow(floating: onTop))
        .onChange(of: model.attentionCount, initial: true) { _, count in
            NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        }
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
            .toolbar {
                ToolbarItem { inspectorToggle }
            }
        }
    }

    // MARK: Sidebar

    /// One filter in the sidebar. Each section keeps its own choice.
    private enum Filter: Hashable {
        case status(AgentStatus.Group?)
        case host(HostFilter)
        case source(AgentSource?)
    }

    private func isSelected(_ filter: Filter) -> Bool {
        switch filter {
        case .status(let value): status == value
        case .host(let value): hostFilter == value
        case .source(let value): source == value
        }
    }

    private func select(_ filter: Filter) {
        switch filter {
        case .status(let value): status = value
        case .host(let value): hostFilter = value
        case .source(let value): source = value
        }
    }

    /// A sidebar row that draws its own highlight. List selection can't hold one choice per section:
    /// a click deselects the other sections' rows and putting them back makes them blink.
    private func filterRow<Icon: View>(_ filter: Filter, _ title: String, count: Int, countColor: Color = .secondary,
                                       @ViewBuilder icon: () -> Icon) -> some View {
        Button { select(filter) } label: {
            HStack {
                Label { Text(title) } icon: { icon() }
                Spacer()
                Text("\(count)").monospacedDigit().foregroundStyle(countColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected(filter) ? Color.primary.opacity(0.1) : .clear)
                .padding(.horizontal, 10)
        )
    }

    private var sidebar: some View {
        List {
            Section("Status") {
                filterRow(.status(nil), "All Agents", count: count(status: nil)) { Image(systemName: "square.stack") }
                ForEach(AgentStatus.Group.allCases, id: \.self) { group in
                    let count = count(status: group)
                    filterRow(.status(group), group.title, count: count,
                              countColor: group == .needsYou && count > 0 ? .orange : .secondary) {
                        StatusDot(status: group.dotStatus, size: 8)
                    }
                }
            }
            Section("Hosts") {
                filterRow(.host(.all), "All Hosts", count: count(host: .all)) { Image(systemName: "network") }
                filterRow(.host(.local), "This Mac", count: count(host: .local)) {
                    Image(systemName: "desktopcomputer")
                }
                ForEach(remotes.hosts, id: \.self) { host in
                    filterRow(.host(.remote(host)), host, count: count(host: .remote(host))) {
                        Image(systemName: "globe").foregroundStyle(remotes.states[host].color)
                    }
                    .help(remotes.states[host].label)
                }
            }
            Section("Agent") {
                filterRow(.source(nil), "Any Agent", count: count(source: nil)) { Image(systemName: "circle.grid.2x1") }
                ForEach(AgentSource.allCases, id: \.self) { s in
                    filterRow(.source(s), s.displayName, count: count(source: s)) {
                        AgentLogo(source: s)
                    }
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

    private var sidebarToggle: some View {
        Button(showsSidebar ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left") {
            withAnimation { columns = columns == .detailOnly ? .all : .detailOnly }
        }
        .keyboardShortcut("s", modifiers: [.control, .command])
        .help(showsSidebar ? "Hide Sidebar" : "Show Sidebar")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            let picker = Picker("Layout", selection: $layout) {
                ForEach(Layout.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            // Narrow windows: an icon menu, since a segmented control in the toolbar's overflow menu loses its labels.
            Group {
                if searchInToolbar {
                    picker.pickerStyle(.segmented).labelsHidden()
                } else {
                    Menu {
                        picker.pickerStyle(.inline)
                    } label: {
                        Label(layout.rawValue, systemImage: layout == .byStatus ? "list.bullet" : "folder")
                    }
                }
            }
            .help("Group agents by status or by project")
        }
        ToolbarItem { pinToggle }
        ToolbarItem { miniToggle }
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
        if searchInToolbar {
            ToolbarItem {
                // An AppKit search field: .searchable always lands at the window's trailing edge, over the inspector.
                SearchField(text: $query, prompt: "Search")
                    .frame(width: listWidth < 760 ? 120 : 180)
            }
        }
    }

    /// Too narrow and the toolbar would hide the search field: it moves above the list instead.
    private var searchInToolbar: Bool { listWidth >= Self.toolbarSearchWidth }

    private var pinToggle: some View {
        Button(onTop ? "Don't Keep on Top" : "Keep on Top", systemImage: onTop ? "pin.fill" : "pin") { onTop.toggle() }
            .keyboardShortcut("t", modifiers: [.option, .command])
            .help(onTop ? "Stop keeping this window above other apps" : "Keep this window above other apps")
    }

    private var miniToggle: some View {
        Button("Compact Mode", systemImage: "pip") { AppDelegate.shared?.showMini() }
            .keyboardShortcut("m", modifiers: [.shift, .command]) // ⌥⌘M is Minimize All
            .help("Switch to a small window of your projects that floats above other apps")
    }

    private var inspectorToggle: some View {
        Button(showsDetail ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right") {
            withAnimation { showsDetail.toggle() }
        }
        .keyboardShortcut("0", modifiers: [.option, .command])
        .help(showsDetail ? "Hide Inspector" : "Show Inspector")
    }

    private var countLabel: String {
        let hidden = hiddenEnded > 0 ? " · \(hiddenEnded) ended hidden" : ""
        if layout == .byProject {
            return "\(projects.count) project\(projects.count == 1 ? "" : "s") · \(visible.count) of \(all.count) agents"
        }
        return "\(visible.count) shown\(hidden)"
    }

    // MARK: Content

    private var agentList: some View {
        Group {
            if showsGrid { projectGrid } else { list }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !searchInToolbar {
                SearchField(text: $query, prompt: "Search")
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
        .environment(\.compactRows, listWidth < Self.compactWidth)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { listWidth = $0 }
        .background { shortcuts }
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

    // Rows have one fixed height: macOS List caches row heights and clipped rows whose height changed.
    private var list: some View {
        List(selection: $selectedID) {
            switch layout {
            case .byStatus: statusSections
            case .byProject: projectSections
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: AgentSession.ID.self) { ids in
            if let id = ids.first, let session = model.sessions[id] { menu(for: session) }
        } primaryAction: { ids in
            if let id = ids.first, let session = model.sessions[id] { model.focus(session) }
        }
    }

    @ViewBuilder
    private func menu(for session: AgentSession) -> some View {
        Button("Focus Terminal") { model.focus(session) }
        Button("Copy Directory") { copy(session.cwd) }
        Button("Copy Session ID") { copy(session.sessionID) }
    }

    /// ⌘1–⌘6 pick a status filter; Return focuses the selected agent (the list handles Return itself).
    private var shortcuts: some View {
        Group {
            Button("All Agents") { status = nil }.keyboardShortcut("1")
            ForEach(Array(AgentStatus.Group.allCases.enumerated()), id: \.offset) { index, group in
                Button(group.title) { status = group }.keyboardShortcut(KeyEquivalent(Character("\(index + 2)")))
            }
            if showsGrid {
                Button("Focus Terminal") {
                    // Not while typing in the search field: Return there just ends editing.
                    if !(NSApp.keyWindow?.firstResponder is NSText) { selected.map(model.focus) }
                }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(selected == nil)
            }
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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

    private typealias Project = (name: String, sessions: [AgentSession])

    private var projects: [Project] {
        // Alphabetical so projects stay put; agents inside still sort by status.
        Dictionary(grouping: visible, by: \.projectName)
            .map { ($0.key, $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var endedByProject: [String: Int] {
        guard status == nil else { return [:] }
        return Dictionary(grouping: scoped(all).filter { $0.status == .ended }, by: \.projectName).mapValues(\.count)
    }

    /// The project's header row: collapse chevron, icon, name, hosts and status counts.
    private func projectHeader(_ project: Project, endedHidden: Int) -> some View {
        let expanded = !collapsed.contains(project.name)
        return Button {
            withAnimation(.snappy(duration: 0.2)) { if expanded { collapsed.insert(project.name) } else { collapsed.remove(project.name) } }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                ProjectHeader(name: project.name, sessions: project.sessions, endedHidden: endedHidden) {
                    editingIcon = project.name
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false) // its focus ring drew over the card's edge
    }

    /// Each project is one card: its header and agents share a rounded background.
    @ViewBuilder
    private var projectSections: some View {
        let ended = endedByProject
        ForEach(projects, id: \.name) { project in
            let rows = collapsed.contains(project.name) ? [] : project.sessions
            let alert = project.sessions.contains(where: \.needsYou)
            Section {
                projectHeader(project, endedHidden: ended[project.name] ?? 0)
                    .selectionDisabled()
                    .listRowSeparator(.hidden)
                    .listRowBackground(CardPiece(project: project.name, top: true, bottom: rows.isEmpty, alert: alert))
                ForEach(rows) { session in
                    let last = session.id == rows.last?.id
                    ProjectRow(session: session)
                        .listRowSeparator(last ? .hidden : .visible)
                        .listRowBackground(CardPiece(project: project.name, top: false, bottom: last, alert: alert))
                }
            }
        }
    }

    /// Wide windows: project cards two to a row, like a control panel. Cards in a row share its height.
    private var projectGrid: some View {
        let ended = endedByProject
        let projects = projects
        return ScrollView {
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                ForEach(Array(stride(from: 0, to: projects.count, by: 2)), id: \.self) { i in
                    GridRow(alignment: .top) {
                        ForEach(projects[i..<min(i + 2, projects.count)], id: \.name) { project in
                            projectTile(project, endedHidden: ended[project.name] ?? 0)
                        }
                        if i + 1 == projects.count {
                            Color.clear.frame(maxWidth: .infinity).gridCellUnsizedAxes(.vertical)
                        }
                    }
                }
            }
            .padding(16)
        }
        .environment(\.compactRows, true)
    }

    private func projectTile(_ project: Project, endedHidden: Int) -> some View {
        let alert = project.sessions.contains(where: \.needsYou)
        let rows = collapsed.contains(project.name) ? [] : project.sessions
        return VStack(spacing: 0) {
            projectHeader(project, endedHidden: endedHidden)
                .padding(.vertical, 2)
            ForEach(rows) { session in
                Divider().padding(.leading, 12)
                tileRow(session)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top) // as tall as its row
        .background { CardPiece(project: project.name, top: true, bottom: true, alert: alert, inList: false) }
    }

    /// A grid row: click selects, double-click focuses the terminal, right-click for the menu.
    private func tileRow(_ session: AgentSession) -> some View {
        let isSelected = session.id == selectedID
        return ProjectRow(session: session)
            .environment(\.backgroundProminence, isSelected ? .increased : .standard)
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(isSelected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.focus(session) }
            .simultaneousGesture(TapGesture().onEnded { selectedID = session.id })
            .contextMenu { menu(for: session) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Puts the hosting window above other apps' windows while `floating` is on.
private struct FloatingWindow: NSViewRepresentable {
    let floating: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { view.window?.level = floating ? .floating : .normal } // the window isn't attached yet on first update
    }
}

private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.delegate = context.coordinator
        field.target = context.coordinator // the clear button sends its action, not a text change
        field.action = #selector(Coordinator.changed(_:))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ note: Notification) {
            text.wrappedValue = (note.object as? NSSearchField)?.stringValue ?? ""
        }
        @objc func changed(_ field: NSSearchField) { text.wrappedValue = field.stringValue }
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
    /// Just the status line, for compact rows.
    var oneLine = false
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
            if !below.isEmpty && !oneLine {
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
private let rowHeight: CGFloat = 40

private struct StatusRow: View {
    let session: AgentSession
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.compactRows) private var compact
    private var selected: Bool { prominence == .increased }

    var body: some View {
        HStack(spacing: 12) {
            StatusIcon(session: session)
            AgentLogo(source: session.source, size: 16)
                .help(session.source.displayName)
            let title = HStack(spacing: 5) {
                Text(session.projectName).fontWeight(.semibold).lineLimit(1)
                if let branch = session.branch {
                    Text("/ \(branch)").foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if compact {
                VStack(alignment: .leading, spacing: 2) {
                    title
                    StatusText(session: session, oneLine: true)
                }
            } else {
                title.frame(width: 220, alignment: .leading)
                StatusText(session: session)
            }
            Spacer(minLength: 8)
            if !compact || session.host != nil {
                HostChip(host: session.host, onAccent: selected)
            }
            TimeLabel(session: session)
        }
        .frame(height: rowHeight)
        .padding(.vertical, 6).padding(.horizontal, 4)
        .opacity(session.status == .ended ? 0.6 : 1)
        .help(session.cwd)
    }
}

private struct ProjectRow: View {
    let session: AgentSession
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.compactRows) private var compact
    private var selected: Bool { prominence == .increased }

    private var title: String { session.name ?? session.branch ?? session.source.displayName }

    var body: some View {
        HStack(spacing: 12) {
            StatusIcon(session: session)
            AgentLogo(source: session.source, size: 16)
                .help(session.source.displayName)
            if compact {
                VStack(alignment: .leading, spacing: 2) {
                    ViewThatFits(in: .horizontal) { // the chip goes first when space runs out
                        HStack(spacing: 6) {
                            Text(title).fontWeight(.semibold).lineLimit(1).fixedSize()
                            chip.fixedSize()
                        }
                        Text(title).fontWeight(.semibold).lineLimit(1)
                    }
                    StatusText(session: session, title: title, oneLine: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .fontWeight(.semibold).lineLimit(1)
                    HStack(spacing: 4) { chip }
                }
                .frame(width: 220, alignment: .leading)
                StatusText(session: session, title: title)
            }
            Spacer(minLength: 8)
            TimeLabel(session: session)
        }
        .frame(height: rowHeight)
        .padding(.vertical, 6).padding(.horizontal, 12) // inside the project card
        .opacity(session.status == .ended ? 0.6 : 1)
        .help(session.cwd)
    }

    @ViewBuilder
    private var chip: some View {
        if let host = session.host {
            Chip(text: host, style: selected ? .onAccent : .remote)
        } else if let app = session.appName {
            Chip(text: app, style: selected ? .onAccent : .neutral)
        }
    }
}

extension EnvironmentValues {
    /// Narrow window or grid tile: rows stack their title over a one-line status.
    @Entry var compactRows = false
}

private struct ProjectHeader: View {
    let name: String
    let sessions: [AgentSession]
    let endedHidden: Int
    let pickIcon: () -> Void

    var body: some View {
        let hosts = Array(Set(sessions.map { $0.host ?? "" })).sorted()
        let cwds = Set(sessions.map(\.cwd))
        let counts = Dictionary(grouping: sessions, by: \.status.group).mapValues(\.count)
        HStack(spacing: 8) {
            Button(action: pickIcon) {
                ProjectIcon(project: name)
                    .font(.body)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .help("Set Icon and Color")
            Text(name).font(.body.weight(.semibold)).foregroundStyle(.primary).fixedSize()
            if counts[.needsYou] != nil {
                Text("Needs you")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.orange, in: Capsule())
                    .fixedSize()
            }
            ForEach(hosts, id: \.self) { HostChip(host: $0.isEmpty ? nil : $0).fixedSize() }
            if cwds.count == 1, let cwd = cwds.first {
                Text((cwd as NSString).abbreviatingWithTildeInPath)
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            ForEach(AgentStatus.Group.allCases, id: \.self) { group in
                if let count = counts[group] {
                    HStack(spacing: 4) {
                        StatusDot(status: group.dotStatus, size: 6)
                            .padding(.horizontal, group.dotStatus == .working ? 3.5 : 0) // room for its halo
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

/// A project card's background, or a slice of it in the list: rounded at the top for the header and at the
/// bottom for the last row. Middle slices draw only the sides of the border, so the card reads as one piece.
private struct CardPiece: View {
    let top: Bool
    let bottom: Bool
    /// An agent in the project needs you: the card glows orange.
    let alert: Bool
    /// A list row background, inset from the row's edges; otherwise a whole grid tile.
    let inList: Bool
    @AppStorage private var color: String

    init(project: String, top: Bool, bottom: Bool, alert: Bool, inList: Bool = true) {
        self.top = top; self.bottom = bottom; self.alert = alert; self.inList = inList
        _color = ProjectStyle.color(for: project)
    }

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: top ? 10 : 0, bottomLeadingRadius: bottom ? 10 : 0,
                                           bottomTrailingRadius: bottom ? 10 : 0, topTrailingRadius: top ? 10 : 0)
        ZStack {
            shape.fill(ProjectStyle.cardFill(named: color))
            // Open ends run past the row and are clipped off.
            CardOutline(shape: shape, alert: alert)
                .padding(.top, top ? 0 : -20).padding(.bottom, bottom ? 0 : -20)
        }
        .padding(.top, inList && top ? 4 : 0).padding(.bottom, inList && bottom ? 4 : 0)
        .padding(.horizontal, inList ? 8 : 0)
        .mask { Rectangle().padding(inList ? 0 : -12) } // tiles keep their glow
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
                block("Details") { details }
                block("Conversation") { ConversationView(session: session) }
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

/// The latest prompts, replies and tool calls, read from the agent's transcript file on this Mac.
private struct ConversationView: View {
    let session: AgentSession

    /// nil until loaded; empty when there's no transcript to read.
    @State private var entries: [TranscriptEntry]?
    @State private var located: (id: String, url: URL?)?
    /// Why an ssh host's history couldn't be read.
    @State private var remoteError: String?
    @State private var showsAll = false
    @State private var expanded: Set<Int> = []

    private static let recent = 12

    var body: some View {
        Group {
            if let entries, !entries.isEmpty {
                // At least the last few entries, and always back to the latest prompt.
                let lastPrompt = entries.lastIndex { $0.kind == .user } ?? entries.count
                let shown = showsAll ? entries : Array(entries[min(max(entries.count - Self.recent, 0), lastPrompt)...])
                VStack(alignment: .leading, spacing: 10) {
                    if shown.count < entries.count {
                        Button("Show \(entries.count - shown.count) earlier") { showsAll = true }
                            .buttonStyle(.link).font(.callout)
                    }
                    ForEach(Self.runs(shown), id: \.first!.id) { run in
                        if run.count > 1 { toolRun(run) } else { entry(run[0]) }
                    }
                }
            } else if entries != nil {
                fallback
            } else {
                ProgressView().controlSize(.small)
            }
        }
        // Replies can quote web pages or files: only open web links, never file: or app schemes.
        .environment(\.openURL, OpenURLAction { url in
            ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
        // Reload whenever the agent reports something; look for the file again until it's found.
        .task(id: "\(session.id) \(session.lastEventAt.timeIntervalSince1970)") { await reload() }
    }

    private func reload() async {
        let session = session
        if located?.id != session.id {
            entries = nil; showsAll = false; expanded = []
            located = nil; remoteError = nil
        }
        if let host = session.host { return await reloadRemote(session, host: host) }
        if located?.url == nil { // a new Claude session has no file until its first prompt
            let url = await Task.detached { Transcript.url(for: session) }.value
            located = (session.id, url)
        }
        guard let url = located?.url else { entries = []; return }
        entries = await Task.detached { Transcript.load(url, source: session.source, limit: 150) }.value
    }

    /// Over ssh, through the helper Lookout installed on the host.
    private func reloadRemote(_ session: AgentSession, host: String) async {
        if entries != nil { // a working agent reports often: one ssh per burst of events
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
        }
        located = (session.id, nil)
        let quote = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = ["~/.lookout/bin/lookout-hook", "--transcript", quote(session.source.rawValue), quote(session.sessionID),
                       String(session.agentPID ?? 0), quote(session.cwd),
                       String(Int(session.startedAt?.timeIntervalSince1970 ?? 0))].joined(separator: " ")
        do {
            let output = try await RemoteHosts.run(host, command)
            guard !Task.isCancelled else { return }
            entries = Transcript.parseRemote(Data(output.utf8), source: session.source, limit: 150)
            remoteError = nil
        } catch {
            guard !Task.isCancelled else { return }
            if entries == nil { entries = [] }
            remoteError = error.localizedDescription
        }
    }

    /// No transcript: a Codex agent that hasn't sent a hook yet, or an ssh host that couldn't be read.
    @ViewBuilder
    private var fallback: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let prompt = session.lastPrompt {
                Text(prompt)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            Text(remoteError.map { "Couldn't read the history on \(session.host ?? "the host"): \($0)" }
                 ?? "No history found yet. It appears after the agent's next turn.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func entry(_ entry: TranscriptEntry) -> some View {
        switch entry.kind {
        case .user:
            Text(entry.text)
                .lineLimit(expanded.contains(entry.id) ? nil : 6)
                .textSelection(.enabled)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) { moreButton(entry) }
        case .assistant:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                AgentLogo(source: session.source, size: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.markdown(entry.text))
                        .lineLimit(expanded.contains(entry.id) ? nil : 6)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    moreButton(entry)
                }
            }
        case .tool:
            HStack(spacing: 8) {
                Image(systemName: entry.text.hasPrefix("Bash:") ? "terminal" : "wrench.and.screwdriver")
                    .frame(width: 12)
                Text(entry.text.prefix { $0 != "\n" })
                    .lineLimit(1).truncationMode(.middle)
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .help(entry.text)
        }
    }

    /// Entries split so consecutive tool calls share one run; everything else stands alone.
    private static func runs(_ entries: [TranscriptEntry]) -> [[TranscriptEntry]] {
        entries.reduce(into: []) { runs, entry in
            if entry.kind == .tool, runs.last?.last?.kind == .tool { runs[runs.count - 1].append(entry) }
            else { runs.append([entry]) }
        }
    }

    /// Several tool calls in a row, folded to a count and the latest call.
    @ViewBuilder
    private func toolRun(_ run: [TranscriptEntry]) -> some View {
        let open = expanded.contains(run[0].id)
        Button {
            if open { expanded.remove(run[0].id) } else { expanded.insert(run[0].id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 12)
                Text("\(run.count) tool calls").fontWeight(.medium)
                if !open, let last = run.last {
                    Text("· " + last.text.prefix { $0 != "\n" })
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if open {
            ForEach(run) { entry($0).padding(.leading, 20) }
        }
    }

    /// "More"/"Less" for long messages.
    @ViewBuilder
    private func moreButton(_ entry: TranscriptEntry) -> some View {
        let lines = entry.text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        if entry.text.count > 320 || lines > 5 {
            let open = expanded.contains(entry.id)
            Button(open ? "Less" : "More") {
                if open { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
            }
            .buttonStyle(.link).font(.caption)
            .padding(entry.kind == .user ? 4 : 0)
        }
    }

    /// Inline Markdown (bold, code, links) as the agents write it; plain text if it doesn't parse.
    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

import AppKit
import LookoutCore
import SwiftUI

/// The menu bar panel: agents that need you, are working or just finished, with idle and ended
/// agents folded into one summary row each.
struct MenuContentView: View {
    @ObservedObject var model: AppModel
    var openSetup: () -> Void
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppDelegate.miniKey) private var miniShown = false

    @State private var listHeight: CGFloat = 0
    @State private var searching = false
    @State private var query = ""
    @State private var expanded: Set<AgentStatus.Group> = []
    @FocusState private var searchFocused: Bool

    private var sessions: [AgentSession] {
        model.sortedSessions.filter { $0.matches(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if searching {
                TextField("Project, prompt or command", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .padding(.horizontal, 12).padding(.bottom, 8)
                    .onExitCommand { closeSearch() }
            }
            Divider()
            if let error = model.serverError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(12)
                Divider()
            }
            if model.needsSetup {
                setupBanner
                Divider()
            }
            if model.sessions.isEmpty {
                emptyState
            } else {
                // A ScrollView has no ideal height in the menu window, so size it to its content (capped).
                ScrollView {
                    list
                        .padding(.horizontal, 8).padding(.vertical, 10)
                        .background(GeometryReader { Color.clear.preference(key: HeightKey.self, value: $0.size.height) })
                }
                .frame(height: min(listHeight, 520))
                .onPreferenceChange(HeightKey.self) { listHeight = $0 }
            }
            Divider()
            footer
        }
        .frame(width: 400)
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 8) {
            Text("Lookout").font(.headline)
            if model.attentionCount > 0 {
                HStack(spacing: 4) {
                    Circle().fill(.orange).frame(width: 6, height: 6)
                    Text("\(model.attentionCount) need\(model.attentionCount == 1 ? "s" : "") you")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(.orange.opacity(0.15), in: Capsule())
            }
            Spacer()
            Button {
                searching ? closeSearch() : openSearch()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("f")
            .help("Search")
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    @ViewBuilder
    private var list: some View {
        let groups = Dictionary(grouping: sessions, by: \.status.group)
        VStack(alignment: .leading, spacing: 4) {
            ForEach([AgentStatus.Group.needsYou, .working, .finished], id: \.self) { group in
                if let members = groups[group], !members.isEmpty {
                    SectionTitle(title: group.title, count: members.count, color: group.color)
                        .padding(.horizontal, 8).padding(.top, group == .needsYou ? 0 : 8)
                    ForEach(members) { session in
                        MenuAgentRow(session: session) { focus(session) }
                    }
                }
            }
            ForEach([AgentStatus.Group.idle, .ended], id: \.self) { group in
                if let members = groups[group], !members.isEmpty {
                    foldedRow(group, members)
                    if expanded.contains(group) || !query.isEmpty {
                        ForEach(members) { session in
                            MenuAgentRow(session: session) { focus(session) }
                        }
                    }
                }
            }
            if sessions.isEmpty {
                Text("No agents match “\(query)”")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
            }
        }
    }

    /// "5 idle · project ×3 on unicon, analytics ×2", expanding in place.
    private func foldedRow(_ group: AgentStatus.Group, _ members: [AgentSession]) -> some View {
        Button {
            if expanded.contains(group) { expanded.remove(group) } else { expanded.insert(group) }
        } label: {
            HStack(spacing: 10) {
                StatusDot(status: group.dotStatus)
                Text("\(members.count) \(group.title.lowercased())").fontWeight(.medium)
                    + Text(" · \(Self.summary(members))").foregroundColor(.secondary)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(expanded.contains(group) ? 90 : 0))
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    /// Project names with counts and hosts, most common first.
    static func summary(_ sessions: [AgentSession]) -> String {
        let groups = Dictionary(grouping: sessions) { "\($0.projectName)\u{1F}\($0.host ?? "")" }
        return groups.sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }.map { key, members in
            let parts = key.split(separator: "\u{1F}", omittingEmptySubsequences: false)
            var text = String(parts[0])
            if members.count > 1 { text += " ×\(members.count)" }
            if parts.count > 1, !parts[1].isEmpty { text += " on \(parts[1])" }
            return text
        }.joined(separator: ", ")
    }

    private var setupBanner: some View {
        HStack {
            Image(systemName: "wrench.and.screwdriver")
            Text("Hooks aren't installed yet.").font(.callout)
            Spacer()
            Button("Set Up…") { closeMenu(); openSetup() }
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "binoculars").font(.title2).foregroundStyle(.secondary)
            Text("No agents yet").font(.callout.weight(.medium))
            Text("Start Claude Code or Codex in any terminal.\nAgents already running appear after their next action.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            footerButton("Open Window", shortcut: "⌘O") { closeMenu(); NSApp.activate(); openWindow(id: "dashboard") }
                .keyboardShortcut("o")
            footerButton("Setup…", shortcut: "⌘,") { closeMenu(); openSetup() }
                .keyboardShortcut(",")
            Button(miniShown ? "Hide Mini" : "Mini") { closeMenu(); AppDelegate.shared?.toggleMini() }
                .help("A small window with your projects that floats above other apps")
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func footerButton(_ title: String, shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                Text(shortcut).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Actions

    private func focus(_ session: AgentSession) {
        closeMenu()
        model.focus(session)
    }

    private func openSearch() {
        searching = true
        searchFocused = true
    }

    private func closeSearch() {
        searching = false
        query = ""
    }

    private func closeMenu() {
        NSApp.keyWindow?.orderOut(nil)
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// One agent in the menu panel. Agents that need you get a tinted card and their pending command.
struct MenuAgentRow: View {
    let session: AgentSession
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                StatusDot(status: session.status, size: session.needsYou ? 10 : 8)
                    .frame(width: 12, height: 12)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 4) {
                    titleLine
                    statusLine
                    if session.needsYou, let command = session.tool?.argument {
                        CodeBlock(text: command)
                    }
                    if session.status == .finished, let took = session.lastTurnDuration {
                        Text("took \(Format.duration(took))").font(.caption).foregroundStyle(.secondary)
                    }
                    if let secondary = session.name ?? session.lastPrompt {
                        Text(secondary).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(background, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(session.cwd)
        .opacity(session.status == .ended ? 0.6 : 1)
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            Text(session.projectName).fontWeight(.semibold).lineLimit(1)
            if let branch = session.branch {
                Text("/ \(branch)").foregroundStyle(.secondary).lineLimit(1)
            }
            SourceChip(source: session.source)
            if let host = session.host {
                Chip(text: host, style: .remote, systemImage: "globe")
            } else if let app = session.appName {
                Chip(text: app)
            }
            Spacer(minLength: 4)
            Ticking { now in
                Text(Format.ago(session.statusSince, now: now))
                    .font(.caption.weight(session.needsYou ? .semibold : .regular))
                    .foregroundStyle(session.needsYou ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
        }
    }

    private var statusLine: some View {
        let label = Text(session.statusLabel).foregroundColor(session.statusColor).fontWeight(.medium)
        return Group {
            if session.status == .working, let tool = session.tool, let argument = tool.argument {
                label + Text(" · \(tool.name) ").foregroundColor(.primary.opacity(0.85))
                    + Text(argument).font(.system(.callout, design: .monospaced)).foregroundColor(.primary.opacity(0.85))
            } else if let detail = session.statusDetail {
                label + Text(" · \(detail)").foregroundColor(.primary.opacity(0.85))
            } else {
                label
            }
        }
        .font(.callout)
        .lineLimit(1)
    }

    private var background: Color {
        if session.needsYou { return .orange.opacity(hovering ? 0.2 : 0.12) }
        return hovering ? .primary.opacity(0.08) : .clear
    }
}

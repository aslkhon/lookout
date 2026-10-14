import AppKit
import LookoutCore
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var model: AppModel
    var openSetup: () -> Void
    var openDashboard: () -> Void
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
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
                    VStack(spacing: 2) {
                        ForEach(model.sortedSessions) { session in
                            SessionRow(session: session) {
                                closeMenu()
                                model.focus(session)
                            }
                        }
                    }
                    .padding(6)
                    .background(GeometryReader { Color.clear.preference(key: HeightKey.self, value: $0.size.height) })
                }
                .frame(height: min(listHeight, 460))
                .onPreferenceChange(HeightKey.self) { listHeight = $0 }
            }
            Divider()
            footer
        }
        .frame(width: 380)
    }

    private var header: some View {
        HStack {
            Text("Lookout").font(.headline)
            Spacer()
            let counts = Dictionary(grouping: model.sessions.values, by: \.status).mapValues(\.count)
            ForEach([AgentStatus.needsApproval, .needsInput, .working], id: \.self) { status in
                if let n = counts[status], n > 0 {
                    HStack(spacing: 4) {
                        StatusDot(status: status)
                        Text("\(n)").monospacedDigit()
                    }
                    .font(.caption)
                    .help(status.label)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
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
        HStack(spacing: 12) {
            Button("Open Window") { closeMenu(); openDashboard() }
            Button("Setup…") { closeMenu(); openSetup() }
            if model.sessions.values.contains(where: { $0.status == .ended }) {
                Button("Clear Ended") { model.clearEnded() }
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func closeMenu() {
        NSApp.keyWindow?.orderOut(nil)
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct SessionRow: View {
    let session: AgentSession
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            SessionSummary(session: session)
                .padding(.horizontal, 8).padding(.vertical, 7)
                .contentShape(Rectangle())
                .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(session.cwd)
    }
}

/// Visual summary of an agent, shared by the menu and the dashboard list.
struct SessionSummary: View {
    let session: AgentSession

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(status: session.status).padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.projectName).font(.system(.body, weight: .semibold)).lineLimit(1)
                    SourceBadge(source: session.source)
                    Spacer(minLength: 4)
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(Self.relative(session.statusSince)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                let label = Text(session.status.label).foregroundStyle(session.status.color)
                Group {
                    if let detail = session.detail {
                        Text("\(label) · \(detail)")
                    } else {
                        label
                    }
                }
                .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                if let prompt = session.lastPrompt {
                    Text(prompt).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            HostIcon(bundleID: session.hostBundleID).padding(.top, 2)
        }
        .opacity(session.status == .ended ? 0.55 : 1)
    }

    static func relative(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}

struct SourceBadge: View {
    let source: AgentSource

    var body: some View {
        Text(source.displayName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }
}

struct StatusDot: View {
    let status: AgentStatus

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: 8, height: 8)
            .overlay {
                if status == .working {
                    Circle().stroke(status.color.opacity(0.4), lineWidth: 3).frame(width: 12, height: 12)
                }
            }
    }
}

struct HostIcon: View {
    let bundleID: String?
    var size: CGFloat = 18

    var body: some View {
        if let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: size, height: size)
                .help(FileManager.default.displayName(atPath: url.path))
        }
    }
}

extension AgentStatus {
    var color: Color {
        switch self {
        case .needsApproval: .orange
        case .needsInput: .blue
        case .working: .green
        case .finished: .purple
        case .idle: .gray
        case .ended: .secondary
        }
    }
}

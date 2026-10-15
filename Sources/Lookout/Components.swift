import AppKit
import LookoutCore
import SwiftUI

// Building blocks shared by the menu panel, the dashboard and Setup.

/// Small rounded label: agent kind, app, host.
struct Chip: View {
    enum Style { case neutral, remote, success, onAccent }

    let text: String
    var style: Style = .neutral
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 5).padding(.vertical, 2)
        .foregroundStyle(foreground)
        .background(background, in: RoundedRectangle(cornerRadius: 4))
    }

    private var foreground: Color {
        switch style {
        case .neutral: .secondary
        case .remote: .teal
        case .success: .green
        case .onAccent: .white
        }
    }

    private var background: Color {
        switch style {
        case .neutral: .primary.opacity(0.08)
        case .remote: .teal.opacity(0.15)
        case .success: .green.opacity(0.15)
        case .onAccent: .white.opacity(0.2)
        }
    }
}

struct SourceChip: View {
    let source: AgentSource
    var onAccent = false
    var body: some View { Chip(text: source.displayName, style: onAccent ? .onAccent : .neutral) }
}

/// The agent's logo (Claude and OpenAI marks from Simple Icons, CC0), tinted like a symbol.
struct AgentLogo: View {
    let source: AgentSource
    var size: CGFloat = 14

    private static let images: [AgentSource: NSImage] = AgentSource.allCases.reduce(into: [:]) { images, source in
        let name = source == .claude ? "ClaudeLogo" : "CodexLogo"
        guard let url = Bundle.main.url(forResource: name, withExtension: "pdf"),
              let image = NSImage(contentsOf: url) else { return }
        image.isTemplate = true
        images[source] = image
    }

    var body: some View {
        if let image = Self.images[source] {
            Image(nsImage: image)
                .resizable()
                .frame(width: size, height: size)
                .foregroundStyle(source == .claude ? Color(red: 0.85, green: 0.47, blue: 0.34) : .primary)
        } else {
            Image(systemName: "terminal") // not bundled, e.g. under `swift run`
        }
    }
}

/// "This Mac", or the ssh host an agent runs on.
struct HostChip: View {
    let host: String?
    var onAccent = false
    var body: some View {
        Chip(text: host ?? "This Mac", style: onAccent ? .onAccent : (host == nil ? .neutral : .remote))
    }
}

struct StatusDot: View {
    let status: AgentStatus
    var size: CGFloat = 8

    var body: some View {
        Group {
            if status == .ended {
                Circle().strokeBorder(status.color, lineWidth: 1.2)
            } else {
                Circle().fill(status.color)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            if status == .working {
                Circle().stroke(status.color.opacity(0.35), lineWidth: 3).frame(width: size + 4, height: size + 4)
            }
        }
    }
}

/// A command the agent is running or waiting on.
struct CodeBlock: View {
    let text: String
    var lineLimit: Int? = 1

    var body: some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .lineLimit(lineLimit)
            .truncationMode(.tail)
            .textSelection(.enabled)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Uppercase section title, e.g. "NEEDS YOU 2".
struct SectionTitle: View {
    let title: String
    var count: Int?
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
            if let count { Text("\(count)") }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
    }
}

extension AgentStatus {
    var color: Color {
        switch self {
        case .needsApproval, .needsInput: .orange
        case .working: .green
        case .finished: .purple
        case .idle: .gray
        case .ended: .secondary
        }
    }

    /// The status groups the menu and dashboard show, in order.
    enum Group: CaseIterable {
        case needsYou, working, finished, idle, ended

        var title: String {
            switch self {
            case .needsYou: "Needs you"
            case .working: "Working"
            case .finished: "Finished"
            case .idle: "Idle"
            case .ended: "Ended"
            }
        }

        var color: Color {
            switch self {
            case .needsYou: .orange
            default: .secondary
            }
        }

        var dotStatus: AgentStatus {
            switch self {
            case .needsYou: .needsApproval
            case .working: .working
            case .finished: .finished
            case .idle: .idle
            case .ended: .ended
            }
        }
    }

    var group: Group {
        switch self {
        case .needsApproval, .needsInput: .needsYou
        case .working: .working
        case .finished: .finished
        case .idle: .idle
        case .ended: .ended
        }
    }
}

extension AgentSession {
    /// Short name of the app running the agent, e.g. "VS Code" or "Ghostty".
    var appName: String? {
        switch hostBundleID {
        case "com.microsoft.VSCode": return "VS Code"
        case "com.microsoft.VSCodeInsiders": return "VS Code Insiders"
        case "com.todesktop.230313mzl4w4u92": return "Cursor"
        case "com.mitchellh.ghostty": return "Ghostty"
        case "com.apple.Terminal": return "Terminal"
        case "com.googlecode.iterm2": return "iTerm"
        case let id?:
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        case nil:
            return termProgram == "vscode" ? "VS Code" : nil
        }
    }

    /// "Needs approval · Bash: npm test"-style text after the status label.
    var statusDetail: String? {
        if status.needsAttention, let tool { return tool.name }
        return detail
    }

    var needsYou: Bool { status.needsAttention }

    /// Whether `query` matches this agent's project, prompt, name or command.
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return [projectName, cwd, name, lastPrompt, detail, tool?.argument, branch, host]
            .compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(q) }
    }
}

enum Format {
    /// "now", "4m", "2h", "12d".
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }

    /// "45s", "2m 14s", "38m", "1h 5m".
    static func duration(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        if s < 60 { return "\(s)s" }
        if s < 600 { return s % 60 == 0 ? "\(s / 60)m" : "\(s / 60)m \(s % 60)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }
}

/// Re-renders its content every `interval` seconds, for relative times.
struct Ticking<Content: View>: View {
    var interval: TimeInterval = 30
    @ViewBuilder let content: (Date) -> Content

    var body: some View {
        TimelineView(.periodic(from: .now, by: interval)) { context in content(context.date) }
    }
}

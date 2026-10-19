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
/// Gemini CLI and OpenCode get a symbol.
struct AgentLogo: View {
    let source: AgentSource
    var size: CGFloat = 14

    private static let images: [AgentSource: NSImage] = AgentSource.allCases.reduce(into: [:]) { images, source in
        let name: String? = switch source {
        case .claude: "ClaudeLogo"
        case .codex: "CodexLogo"
        case .gemini, .opencode: nil
        }
        guard let name, let url = Bundle.main.url(forResource: name, withExtension: "pdf"),
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
        } else if source == .gemini {
            Image(systemName: "sparkle")
                .font(.system(size: size * 0.9, weight: .semibold))
                .frame(width: size, height: size)
                .foregroundStyle(Color(red: 0.31, green: 0.52, blue: 0.96))
        } else if source == .opencode {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: size * 0.7, weight: .bold))
                .frame(width: size, height: size)
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

/// The agent's mascot acting out its status: one icon for which agent and what it's doing.
struct StatusIcon: View {
    let session: AgentSession
    var size: CGFloat = 15
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        MascotIcon(kind: MascotKind(session.source), scene: MascotScene(session),
                   phase: Double(abs(session.id.hashValue) % 1000) / 100, animated: !reduceMotion)
            .frame(width: size, height: size)
            .help("\(session.source.displayName): \(session.statusLabel)")
            .accessibilityElement()
            .accessibilityLabel("\(session.source.displayName), \(session.statusLabel)")
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

    /// The status, or "No activity" for a working agent that has gone quiet.
    var statusLabel: String { stalled ? "No activity" : status.label }
    var statusColor: Color { stalled ? .yellow : status.color }

    /// "Needs approval · Bash: npm test"-style text after the status label.
    var statusDetail: String? {
        // A question or a plan shows itself instead.
        if status == .needsApproval, let tool, tool.name != PlanReview.tool { return tool.name }
        return detail
    }

    var needsYou: Bool { status.needsAttention }

    /// " · 2 subagents", or nothing.
    var subagentSuffix: String {
        switch subagents.count {
        case 0: ""
        case 1: " · 1 subagent"
        case let n: " · \(n) subagents"
        }
    }

    /// Whether `query` matches this agent's project, prompt, name or command.
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return [projectName, cwd, name, lastPrompt, detail, tool?.argument, branch, host]
            .compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(q) }
    }
}

/// Answers an agent's permission request from Lookout; its terminal dialog closes too.
struct ApprovalButtons: View {
    let decide: (PermissionDecision) -> Void
    /// ⌘Y and ⌘N answer it: for one agent at a time, the first in the panel or the selected one.
    var shortcuts = false

    var body: some View {
        HStack(spacing: 8) {
            Button("Deny") { decide(.deny) }
                .keyboardShortcut("n", enabled: shortcuts)
            Button("Allow") { decide(.allow) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("y", enabled: shortcuts)
            if shortcuts { ShortcutHint(text: "⌘Y · ⌘N") }
        }
        .controlSize(.small)
    }
}

struct ShortcutHint: View {
    let text: String

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.tertiary)
    }
}

extension View {
    @ViewBuilder
    func keyboardShortcut(_ key: KeyEquivalent, enabled: Bool) -> some View {
        if enabled { keyboardShortcut(key) } else { self }
    }
}

/// Claude's plan, with feedback to send from here. Approving happens in the terminal: Claude ignores a
/// hook's allow for a plan.
struct PlanReviewBox: View {
    let plan: String
    let decide: (PermissionDecision) -> Void
    let approveInTerminal: () -> Void
    /// Scrolls past this; nil shows the whole plan.
    var maxHeight: CGFloat?

    @State private var feedback = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                // A nested ScrollView sized to fit would take the plan's unwrapped width.
                if let maxHeight {
                    ScrollView { planText }.frame(maxHeight: maxHeight)
                } else {
                    planText
                }
            }
            .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            TextField("Tell Claude what to change", text: $feedback, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .onSubmit(send)
            HStack(spacing: 8) {
                Button("Send Feedback", action: send)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty)
                Button("Approve in Terminal", action: approveInTerminal)
                    .buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
    }

    private var planText: some View {
        MarkdownText(markdown: plan)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trimmed: String { feedback.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func send() {
        guard !trimmed.isEmpty else { return }
        decide(.feedback(trimmed))
    }
}

/// A plan's Markdown: headings, lists, code blocks and inline styling.
struct MarkdownText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    inline(text).font(level == 1 ? .headline : .subheadline.weight(.semibold))
                        .padding(.top, level == 1 ? 0 : 4)
                case .item(let marker, let indent, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(marker).foregroundStyle(.secondary).monospacedDigit()
                        inline(text)
                    }
                    .padding(.leading, CGFloat(indent) * 14)
                case .code(let code):
                    Text(code).font(.system(.caption, design: .monospaced))
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                case .paragraph(let text):
                    inline(text)
                case .table(let rows):
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            GridRow {
                                ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                    inline(cell).fontWeight(index == 0 ? .semibold : nil)
                                }
                            }
                            if index == 0 && rows.count > 1 { Divider() }
                        }
                    }
                    .padding(.vertical, 2)
                case .rule:
                    Divider()
                }
            }
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var styled = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        styled.link = nil // agent-written text; a link could open any URL scheme
        return Text(styled)
    }
}

/// Answers Claude's questions: click an option, or type your own answer. A single question with
/// a single choice is sent on the click; otherwise with Send once every question has an answer.
struct QuestionForm: View {
    let questions: [AgentQuestion]
    let decide: (PermissionDecision) -> Void
    /// ⌘1–⌘9 pick the options of a single question (the menu panel's first agent).
    var shortcuts = false

    @State private var picked: [Int: Set<String>] = [:]
    @State private var typed: [Int: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(questions.enumerated()), id: \.offset) { i, question in
                VStack(alignment: .leading, spacing: 6) {
                    if questions.count > 1 || question.multiSelect {
                        Text(question.text).font(.callout.weight(.medium))
                    }
                    ForEach(Array(question.options.enumerated()), id: \.element.label) { n, option in
                        let key = shortcuts && questions.count == 1 && n < 9 ? n + 1 : nil
                        optionButton(i, question, option, key: key)
                    }
                    TextField(question.options.isEmpty ? "Answer" : "Or type your own", text: typedBinding(i))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if complete { send() } }
                }
            }
            if !sendsOnClick {
                Button("Send", action: send)
                    .buttonStyle(.borderedProminent)
                    .disabled(!complete)
            }
        }
        .controlSize(.small)
    }

    private var sendsOnClick: Bool {
        questions.count == 1 && !questions[0].multiSelect && !questions[0].options.isEmpty
    }

    private func optionButton(_ i: Int, _ question: AgentQuestion, _ option: AgentQuestion.Option, key: Int?) -> some View {
        let on = picked[i, default: []].contains(option.label)
        return Button {
            if sendsOnClick {
                decide(.answer([question.text: option.label]))
                return
            }
            if question.multiSelect {
                picked[i, default: []].formSymmetricDifference([option.label])
            } else {
                picked[i] = on ? [] : [option.label]
            }
            typed[i] = nil
        } label: {
            HStack(spacing: 6) {
                if !sendsOnClick {
                    Image(systemName: on ? (question.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle")
                                         : (question.multiSelect ? "square" : "circle"))
                        .foregroundStyle(on ? .orange : .secondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                    if let description = option.description {
                        Text(description).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if let key { ShortcutHint(text: "⌘\(key)") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .keyboardShortcut(KeyEquivalent(Character(String(key ?? 0))), enabled: key != nil)
        .help(option.description ?? option.label)
        .accessibilityLabel(option.label)
    }

    private func typedBinding(_ i: Int) -> Binding<String> {
        Binding(get: { typed[i] ?? "" }, set: {
            typed[i] = $0
            if !$0.isEmpty { picked[i] = nil }
        })
    }

    /// Typed words win over picked options.
    private func answer(_ i: Int) -> String? {
        let text = (typed[i] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        let labels = questions[i].options.map(\.label).filter { picked[i, default: []].contains($0) }
        return labels.isEmpty ? nil : labels.joined(separator: ", ")
    }

    private var complete: Bool { questions.indices.allSatisfy { answer($0) != nil } }

    private func send() {
        var answers: [String: String] = [:]
        for i in questions.indices {
            guard let a = answer(i) else { return }
            answers[questions[i].text] = a
        }
        decide(.answer(answers))
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

    /// Time left until `date`: "12m", "2h 10m", "3d".
    static func until(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(date.timeIntervalSince(now)))
        if s < 3600 { return "\(max(1, s / 60))m" }
        if s < 86400 { return s % 3600 / 60 == 0 ? "\(s / 3600)h" : "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86400)d"
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

/// Plan limits per agent: "5h ▰▰▱ 46% · 2h 10m   Week ▰▰▱ 55% · 3d".
struct LimitsStrip: View {
    let limits: [(source: AgentSource, limits: [UsageLimit])]

    var body: some View {
        Ticking(interval: 60) { now in
            VStack(alignment: .leading, spacing: 6) {
                ForEach(limits, id: \.source) { entry in
                    HStack(spacing: 10) {
                        AgentLogo(source: entry.source, size: 12)
                            .help(entry.source.displayName)
                        ForEach(entry.limits.map { $0.current(now: now) }, id: \.windowMinutes) { limit in
                            gauge(limit, now: now)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .font(.caption)
    }

    private func gauge(_ limit: UsageLimit, now: Date) -> some View {
        let used = min(max(limit.usedPercent, 0), 100)
        let color: Color = used >= 90 ? .red : used >= 70 ? .orange : .green
        return HStack(spacing: 5) {
            Text(limit.name).foregroundStyle(.secondary)
            Capsule().fill(.quaternary)
                .frame(width: 40, height: 5)
                .overlay(alignment: .leading) {
                    Capsule().fill(color).frame(width: 40 * used / 100, height: 5)
                }
            Text("\(Int(used.rounded()))%").monospacedDigit()
            Text("· \(Format.until(limit.resetsAt, now: now))").foregroundStyle(.secondary).monospacedDigit()
        }
        .help("\(limit.name) limit: \(Int(used.rounded()))% used, resets \(limit.resetsAt.formatted(date: .abbreviated, time: .shortened))")
    }
}

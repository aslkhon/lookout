import AppKit
import SwiftUI

/// What the user picked for a project, saved per project name: an emoji and a card color.
enum ProjectStyle {
    static func icon(for project: String) -> AppStorage<String> {
        AppStorage(wrappedValue: "", "projectIcon.\(project)")
    }

    static func color(for project: String) -> AppStorage<String> {
        AppStorage(wrappedValue: "", "projectColor.\(project)")
    }

    static let colors: [(name: String, color: Color)] = [
        ("red", .red), ("orange", .orange), ("yellow", .yellow), ("green", .green), ("mint", .mint), ("teal", .teal),
        ("blue", .blue), ("indigo", .indigo), ("purple", .purple), ("pink", .pink), ("brown", .brown), ("gray", .gray),
    ]

    static func color(named name: String) -> Color? {
        colors.first { $0.name == name }?.color
    }
}

/// The project's emoji, or a folder in its color.
struct ProjectIcon: View {
    @AppStorage private var icon: String
    @AppStorage private var color: String

    init(project: String) {
        _icon = ProjectStyle.icon(for: project)
        _color = ProjectStyle.color(for: project)
    }

    var body: some View {
        if icon.isEmpty {
            Image(systemName: "folder").foregroundStyle(ProjectStyle.color(named: color) ?? .secondary)
        } else {
            Text(icon)
        }
    }
}

/// A project card's border: its color, plus an orange glow that pulses while an agent needs you.
/// The pulse follows the clock, so every piece of a card (and every card) glows in step.
struct CardOutline<S: InsettableShape>: View {
    let shape: S
    let color: Color?
    let alert: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let color { shape.strokeBorder(color.opacity(0.85), lineWidth: 1.5) }
            if alert {
                TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let pulse = reduceMotion ? 0.8 : 0.3 + 0.6 * (0.5 + 0.5 * sin(t * 2 * .pi / 1.8))
                    // Just outside the card's own border, so its color still shows.
                    shape.strokeBorder(Color.orange.opacity(pulse), lineWidth: 2)
                        .padding(color == nil ? 0 : -2.5)
                        .shadow(color: .orange.opacity(pulse), radius: 6)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Emoji and color for a project.
struct ProjectStylePicker: View {
    let project: String
    let done: () -> Void
    @AppStorage private var icon: String
    @AppStorage private var color: String
    @FocusState private var fieldFocused: Bool

    init(project: String, done: @escaping () -> Void) {
        self.project = project; self.done = done
        _icon = ProjectStyle.icon(for: project)
        _color = ProjectStyle.color(for: project)
    }

    private static let suggestions = ["🚀", "🧠", "📞", "💬", "🛒", "💳", "📊", "📈", "🔭", "🛠️", "🧪", "🤖",
                                      "🌐", "📱", "🖥️", "🗄️", "🔒", "📦", "🎨", "📝", "🎧", "🎬", "🏦", "⚡️"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Icon and color for \(project)").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 4), count: 8), spacing: 4) {
                ForEach(Self.suggestions, id: \.self) { emoji in
                    Button { icon = emoji } label: {
                        Text(emoji).font(.title3).frame(width: 28, height: 28)
                            .background(icon == emoji ? Color.accentColor.opacity(0.25) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 6) {
                swatch(name: "", fill: Color.clear).overlay(Image(systemName: "slash.circle").foregroundStyle(.secondary))
                    .help("No color")
                ForEach(ProjectStyle.colors, id: \.name) { swatch(name: $0.name, fill: $0.color).help($0.name.capitalized) }
            }
            HStack {
                TextField("Any emoji", text: Binding(get: { icon }, set: { icon = $0.last.map(String.init) ?? "" }))
                    .focused($fieldFocused)
                    .frame(width: 90)
                    .onSubmit(done)
                Button("Emoji…") { fieldFocused = true; NSApp.orderFrontCharacterPalette(nil) }
                Spacer()
                Button("Reset") { icon = ""; color = "" }.disabled(icon.isEmpty && color.isEmpty)
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 330)
    }

    private func swatch(name: String, fill: Color) -> some View {
        Button { color = name } label: {
            Circle().fill(fill).frame(width: 18, height: 18)
                .padding(2)
                .overlay(Circle().strokeBorder(color == name ? Color.primary : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}

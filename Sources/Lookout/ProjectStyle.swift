import AppKit
import SwiftUI

/// What the user picked for a project, saved per project name: an emoji, a card color and whether it notifies.
enum ProjectStyle {
    static func icon(for project: String) -> AppStorage<String> {
        AppStorage(wrappedValue: "", "projectIcon.\(project)")
    }

    static func color(for project: String) -> AppStorage<String> {
        AppStorage(wrappedValue: "", "projectColor.\(project)")
    }

    static func mutedKey(_ project: String) -> String { "projectMuted.\(project)" }

    static func muted(for project: String) -> AppStorage<Bool> {
        AppStorage(wrappedValue: false, mutedKey(project))
    }

    static let colors: [(name: String, color: Color)] = [
        ("red", .red), ("orange", .orange), ("yellow", .yellow), ("green", .green), ("mint", .mint), ("teal", .teal),
        ("blue", .blue), ("indigo", .indigo), ("purple", .purple), ("pink", .pink), ("brown", .brown), ("gray", .gray),
    ]

    static func color(named name: String) -> Color? {
        colors.first { $0.name == name }?.color
    }

    /// A card's background: a pale wash of the project's color, or the plain card gray.
    static func cardFill(named name: String) -> Color {
        color(named: name)?.opacity(0.08) ?? .primary.opacity(0.05)
    }
}

/// "Mute Notifications", for a project's context menu.
struct MuteToggle: View {
    @AppStorage private var muted: Bool

    init(project: String) { _muted = ProjectStyle.muted(for: project) }

    var body: some View { Toggle("Mute Notifications", isOn: $muted) }
}

/// A slashed bell after a muted project's name.
struct MutedBell: View {
    @AppStorage private var muted: Bool

    init(project: String) { _muted = ProjectStyle.muted(for: project) }

    var body: some View {
        if muted {
            Image(systemName: "bell.slash").foregroundStyle(.secondary).help("Notifications muted")
        }
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

/// A project card's outline while an agent needs you: an orange glow that pulses
/// in step on every piece of a card (and every card).
struct CardOutline<S: InsettableShape>: View {
    let shape: S
    let alert: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if alert {
            Pulsing(pulsing: !reduceMotion, margin: 12) {
                shape.strokeBorder(Color.orange, lineWidth: 2)
                    .shadow(color: .orange, radius: 6)
            }
            .padding(-12)
            .allowsHitTesting(false)
        }
    }
}

/// Fades its content in and out with Core Animation, in step with every other `Pulsing`
/// (redrawing from SwiftUI every frame relaid out the whole window each time).
/// The content is hosted separately, so it doesn't inherit the environment (font, colors).
struct Pulsing<Content: View>: NSViewRepresentable {
    let pulsing: Bool
    /// Opacity at the dim and bright ends; it rests at the bright one when not pulsing.
    var range: ClosedRange<Float> = 0.3...0.9
    /// Room for drawing past the frame, like a glow; the caller pads by minus this.
    var margin: CGFloat = 0
    @ViewBuilder let content: Content

    func makeNSView(context: Context) -> PulsingView<AnyView> {
        let view = PulsingView(rootView: AnyView(content.padding(margin)))
        view.range = range
        return view
    }

    func updateNSView(_ view: PulsingView<AnyView>, context: Context) {
        view.rootView = AnyView(content.padding(margin))
        view.pulsing = pulsing
    }
}

final class PulsingView<Content: View>: NSHostingView<Content> {
    private static var period: CFTimeInterval { 1.8 }
    var range: ClosedRange<Float> = 0.3...0.9
    var pulsing = true { didSet { if pulsing != oldValue { updateAnimation() } } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimation()
    }

    private func updateAnimation() {
        guard let layer else { return }
        layer.removeAnimation(forKey: "pulse")
        layer.opacity = pulsing ? range.lowerBound : range.upperBound
        guard pulsing, window != nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = range.lowerBound
        pulse.toValue = range.upperBound
        pulse.duration = Self.period / 2
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.timeOffset = CACurrentMediaTime().truncatingRemainder(dividingBy: Self.period) // same phase everywhere
        pulse.isRemovedOnCompletion = false
        layer.add(pulse, forKey: "pulse")
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
    private static let columns = Array(repeating: GridItem(.fixed(28), spacing: 4), count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Icon and color for \(project)").font(.headline)
            LazyVGrid(columns: Self.columns, spacing: 4) {
                ForEach(Self.suggestions, id: \.self) { emoji in
                    Button { icon = emoji } label: {
                        Text(emoji).font(.title3).frame(width: 28, height: 28)
                            .background(icon == emoji ? Color.accentColor.opacity(0.25) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            LazyVGrid(columns: Self.columns, spacing: 4) { // a single row is wider than the picker
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

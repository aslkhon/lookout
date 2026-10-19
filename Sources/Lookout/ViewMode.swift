import AppKit
import SwiftUI

/// Where Lookout shows your agents. Only one at a time: the menu bar icon, the notch, the mini
/// window or the full window.
enum ViewMode: String, CaseIterable {
    case menuBar, notch, mini, window

    var title: String {
        switch self {
        case .menuBar: "Menu Bar"
        case .notch: "Notch"
        case .mini: "Mini Window"
        case .window: "Full Window"
        }
    }

    var icon: String {
        switch self {
        case .menuBar: "menubar.rectangle"
        case .notch: "rectangle.topthird.inset.filled"
        case .mini: "pip"
        case .window: "macwindow"
        }
    }
}

@MainActor
final class ViewModes: ObservableObject {
    static let shared = ViewModes()
    private static let key = "viewMode"

    @Published fileprivate(set) var mode: ViewMode
    /// The full window closes back to this.
    fileprivate var beforeWindow: ViewMode = .menuBar
    /// The menu bar label has appeared, so the dashboard can be opened: until then the icon stays,
    /// since the dashboard's openWindow is captured from it.
    @Published var ready = false

    private init() {
        let defaults = UserDefaults.standard
        mode = defaults.string(forKey: Self.key).flatMap(ViewMode.init)
            ?? (defaults.bool(forKey: "miniWindowShown") ? .mini : .menuBar) // before view modes
    }

    fileprivate func save() { UserDefaults.standard.set(mode.rawValue, forKey: Self.key) }
}

extension AppDelegate {
    /// Shows `new` and closes the others.
    func switchView(to new: ViewMode) {
        let views = ViewModes.shared
        if new == .window, views.mode != .window { views.beforeWindow = views.mode }
        views.mode = new // before closing the dashboard, so its closing doesn't switch back
        views.save()
        if new != .notch { notchPanel?.orderOut(nil) }
        if new != .mini { miniPanel?.orderOut(nil) }
        if new != .window, Self.dashboardOpen { Self.closeDashboard?() }
        switch new {
        case .menuBar: break
        case .notch: showNotch()
        case .mini: showMini()
        case .window: NSApp.activate(); Self.openDashboard?()
        }
    }

    /// The full window was closed: back to the view it was opened from.
    func dashboardClosed() {
        let views = ViewModes.shared
        if views.mode == .window { switchView(to: views.beforeWindow) }
    }
}

/// A button per view, the current one highlighted. In each view, so you can always switch.
struct ViewSwitcher: View {
    @ObservedObject private var views = ViewModes.shared
    var size: CGFloat = 12
    /// Runs before switching, e.g. to close the menu panel.
    var willSwitch: () -> Void = {}

    var body: some View {
        // Neutral, like the rest of the chrome: the current view is a slightly lighter tile, no accent.
        HStack(spacing: 2) {
            ForEach(ViewMode.allCases, id: \.self) { mode in
                let current = mode == views.mode
                Button {
                    willSwitch()
                    AppDelegate.shared?.switchView(to: mode)
                } label: {
                    Image(systemName: mode.icon)
                        .font(.system(size: size))
                        .frame(width: size * 2, height: size * 1.7)
                        .foregroundStyle(current ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                        .background(current ? Color.primary.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(current ? "Showing in the \(mode.title)" : "Show in the \(mode.title)")
                .modifier(MiniShortcut(enabled: mode == .mini))
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
    }
}

/// ⇧⌘M switches to the mini window (⌥⌘M is Minimize All).
private struct MiniShortcut: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.keyboardShortcut("m", modifiers: [.shift, .command]) } else { content }
    }
}

extension View {
    /// For panels sized by hand. Letting the hosting controller size the window, then moving the
    /// window from its resize, looped AppKit and SwiftUI layout until the stack ran out. Here the
    /// window is resized after the layout pass, and the content's size doesn't depend on it.
    func reportingSize(_ fit: @escaping @MainActor (CGSize) -> Void) -> some View {
        fixedSize().onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            DispatchQueue.main.async { fit(size) }
        }
    }
}

/// Setup and Quit, for the views without the menu bar's menu.
struct AppCommands: View {
    var body: some View {
        Button("Setup…") { AppDelegate.shared?.showSetup() }
        Button("Quit Lookout") { NSApp.terminate(nil) }
    }
}

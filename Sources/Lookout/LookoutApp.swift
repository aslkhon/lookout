import AppKit
import LookoutCore
import SwiftUI

@main
struct LookoutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared
    @ObservedObject private var views = ViewModes.shared

    var body: some Scene {
        // Only in the menu bar view.
        MenuBarExtra(isInserted: Binding(get: { views.mode == .menuBar || !views.ready }, set: { _ in })) {
            MenuContentView(model: model, openSetup: { delegate.showSetup() })
        } label: {
            MenuBarLabel(count: model.attentionCount)
        }
        .menuBarExtraStyle(.window)

        // A SwiftUI window (not a hand-made NSWindow) so the sidebar runs full height behind the toolbar.
        Window("Lookout", id: "dashboard") {
            DashboardView(model: model, remotes: model.remotes, openSetup: { delegate.showSetup() })
                .frame(minWidth: 380, minHeight: 300) // narrow enough to pin in a corner
                .onAppear {
                    AppDelegate.dashboardOpen = true
                    NSApp.setActivationPolicy(.regular) // in the Dock and ⌘-Tab while open
                    // Opened some other way (a notification, the Dock): it's the view now.
                    if ViewModes.shared.mode != .window { AppDelegate.shared?.switchView(to: .window) }
                }
                .onDisappear {
                    AppDelegate.dashboardOpen = false
                    NSApp.setActivationPolicy(.accessory)
                    AppDelegate.shared?.dashboardClosed()
                }
        }
        .defaultSize(width: 980, height: 600)
    }
}

private struct MenuBarLabel: View {
    let count: Int
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Image(systemName: count > 0 ? "binoculars.fill" : "binoculars")
            .onAppear {
                AppDelegate.openDashboard = { openWindow(id: "dashboard") }
                AppDelegate.closeDashboard = { dismissWindow(id: "dashboard") }
                // First appearance: the dashboard can open now, so show the saved view. (If this
                // comes before applicationDidFinishLaunching, that shows it instead.)
                if !ViewModes.shared.ready {
                    ViewModes.shared.ready = true
                    AppDelegate.shared?.showSavedView()
                }
            }
        if count > 0 { Text("\(count)") }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var setupWindow: NSWindow?
    var miniPanel: NSPanel?
    var notchPanel: NotchPanel?
    /// For views outside the App struct (the dashboard's toolbar, the menu).
    private(set) static weak var shared: AppDelegate?
    /// SwiftUI's openWindow for the dashboard, captured from the menu bar label.
    static var openDashboard: (() -> Void)?
    static var closeDashboard: (() -> Void)?
    /// Dismissing the dashboard when it isn't open made SwiftUI create it at 0×0, off screen,
    /// where its layout looped forever.
    static var dashboardOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        _ = Notifier.shared // become the notification delegate before any click arrives
        AwayWatcher.shared.start()
        GlobalShortcut.shared.update()
        AppModel.shared.start()
        _ = Updater.shared
        if ViewModes.shared.ready { showSavedView() }
        if AppModel.shared.needsSetup {
            showSetup()
        } else {
            // Hooks already present (reinstall, new bundle id): make sure notifications are authorized.
            Task { await Notifier.shared.requestAuthorization() }
        }
    }

    func showSavedView() {
        DispatchQueue.main.async { self.switchView(to: ViewModes.shared.mode) }
    }

    func showSetup() {
        if setupWindow == nil {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: SetupView.size),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Lookout Setup"
            window.isReleasedWhenClosed = false
            let hosting = NSHostingController(
                rootView: SetupView(model: AppModel.shared, remotes: AppModel.shared.remotes, close: { [weak window] in window?.close() }))
            hosting.sizingOptions = [] // fixed-size window; avoids a constraint-update loop
            window.contentViewController = hosting
            window.setContentSize(SetupView.size)
            window.center()
            setupWindow = window
        }
        NSApp.activate()
        setupWindow?.makeKeyAndOrderFront(nil)
    }

    /// The menu bar icon is hidden in the other views: that's not a reason to quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon reopens the dashboard.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Self.openDashboard?() }
        return true
    }
}

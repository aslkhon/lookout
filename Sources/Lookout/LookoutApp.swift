import AppKit
import LookoutCore
import SwiftUI

@main
struct LookoutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model, openSetup: { delegate.showSetup() }, openDashboard: { delegate.showDashboard() })
        } label: {
            let count = model.attentionCount
            Image(systemName: count > 0 ? "binoculars.fill" : "binoculars")
            if count > 0 { Text("\(count)") }
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var setupWindow: NSWindow?
    private var dashboardWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = Notifier.shared // become the notification delegate before any click arrives
        AppModel.shared.start()
        if AppModel.shared.needsSetup {
            showSetup()
        } else {
            // Hooks already present (reinstall, new bundle id): make sure notifications are authorized.
            Task { await Notifier.shared.requestAuthorization() }
        }
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

    func showDashboard() {
        if dashboardWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 600),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Lookout"
            window.isReleasedWhenClosed = false
            window.toolbarStyle = .unified
            let hosting = NSHostingController(
                rootView: DashboardView(model: AppModel.shared, remotes: AppModel.shared.remotes, openSetup: { [weak self] in self?.showSetup() }))
            hosting.sizingOptions = [] // window size is user-controlled
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: 980, height: 600))
            window.contentMinSize = NSSize(width: 760, height: 420)
            window.setFrameAutosaveName("LookoutDashboard")
            window.delegate = self
            if window.frame.origin == .zero { window.center() }
            dashboardWindow = window
        }
        // Show in the Dock and ⌘-Tab while the window is open.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        dashboardWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === dashboardWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Clicking the Dock icon reopens the dashboard.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showDashboard() }
        return true
    }
}

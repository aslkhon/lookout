import AppKit
import Carbon.HIToolbox

/// ⌥⇧L from any app opens Lookout's menu panel (or the dashboard, if the panel can't be found).
@MainActor
final class GlobalShortcut {
    static let shared = GlobalShortcut()
    static let key = "globalShortcut"
    static let display = "⌥⇧L"

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    func update() {
        if Self.enabled { register() } else { unregister() }
    }

    private func register() {
        guard hotKey == nil else { return }
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { GlobalShortcut.openPanel() } }
                return noErr
            }, 1, &type, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x4C4B_4F54), id: 1) // "LKOT"
        RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(optionKey | shiftKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    /// Clicks Lookout's own menu bar item, which opens (or closes) its panel.
    static func openPanel() {
        let button = NSApp.windows.lazy
            .filter { $0.className == "NSStatusBarWindow" }
            .compactMap { $0.contentView.flatMap(statusButton) }
            .first
        if let button {
            button.performClick(nil)
        } else {
            NSApp.activate()
            AppDelegate.openDashboard?()
        }
    }

    private static func statusButton(in view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews { if let found = statusButton(in: sub) { return found } }
        return nil
    }
}

import AppKit
import Carbon.HIToolbox
import LookoutCore

/// ⌥⇧L from any app brings up the current view: opens the menu panel, unfolds the notch, or
/// brings the mini or full window to the front. While the notch shows an approval, ⌘Y and ⌘N
/// answer it from any app.
@MainActor
final class GlobalShortcut {
    static let shared = GlobalShortcut()
    static let key = "globalShortcut"
    static let display = "⌥⇧L"

    private var hotKey: EventHotKeyRef?
    private var answerKeys: [EventHotKeyRef] = []
    /// When `answer` last changed: presses in the next half second are ignored, so a key already on
    /// its way when an approval appears can't answer it.
    private var armedAt = Date.distantPast
    private var handler: EventHandlerRef?

    private static let openID: UInt32 = 1, allowID: UInt32 = 2, denyID: UInt32 = 3

    /// Answers the approval the notch shows; ⌘Y and ⌘N are taken from other apps only while it's set.
    var answer: ((PermissionDecision) -> Void)? {
        didSet {
            if answer != nil { armedAt = .now }
            guard (answer == nil) != (oldValue == nil) else { return }
            if answer != nil {
                installHandler()
                for (key, id) in [(kVK_ANSI_Y, Self.allowID), (kVK_ANSI_N, Self.denyID)] {
                    var ref: EventHotKeyRef?
                    RegisterEventHotKey(UInt32(key), UInt32(cmdKey), EventHotKeyID(signature: Self.signature, id: id),
                                        GetApplicationEventTarget(), 0, &ref)
                    if let ref { answerKeys.append(ref) }
                }
            } else {
                answerKeys.forEach { UnregisterEventHotKey($0) }
                answerKeys = []
            }
        }
    }

    private static let signature = OSType(0x4C4B_4F54) // "LKOT"

    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    func update() {
        if Self.enabled { register() } else { unregister() }
    }

    private func register() {
        guard hotKey == nil else { return }
        installHandler()
        let id = EventHotKeyID(signature: Self.signature, id: Self.openID)
        RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(optionKey | shiftKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }

    private func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch id.id {
                    case GlobalShortcut.allowID: GlobalShortcut.shared.answerIfSettled(.allow)
                    case GlobalShortcut.denyID: GlobalShortcut.shared.answerIfSettled(.deny)
                    default: GlobalShortcut.openPanel()
                    }
                }
            }
            return noErr
        }, 1, &type, nil, &handler)
    }

    private func answerIfSettled(_ decision: PermissionDecision) {
        guard Date.now.timeIntervalSince(armedAt) >= 0.5 else { return }
        answer?(decision)
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    static func openPanel() {
        switch ViewModes.shared.mode {
        case .menuBar: clickMenuBarItem()
        case .notch: AppDelegate.shared?.notchPanel?.peek(byYou: true)
        case .mini: AppDelegate.shared?.miniPanel?.orderFrontRegardless()
        case .window: AppDelegate.shared?.switchView(to: .window)
        }
    }

    /// Clicks Lookout's own menu bar item, which opens (or closes) its panel.
    private static func clickMenuBarItem() {
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

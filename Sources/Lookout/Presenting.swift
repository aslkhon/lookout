import AppKit
import CoreGraphics

/// Whether the screen is being shown to others: shared or recorded, mirrored, or playing a slideshow.
/// Notifications stay silent then; the menu bar still shows who needs you.
enum Presenting {
    /// UserDefaults key for the Setup switch; on by default.
    static let key = "silenceWhilePresenting"

    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    static let slideshowApps: Set<String> = ["com.apple.iWork.Keynote", "com.microsoft.Powerpoint"]

    static var now: Bool { sharingScreen || mirroring || slideshow }

    /// macOS puts an on-screen "StatusIndicator" window of its own on each display while
    /// anything captures the screen: screen sharing in a call, a recording, a screenshot tool.
    static var sharingScreen: Bool {
        windows([.optionOnScreenOnly]).contains { w in
            w[kCGWindowOwnerName as String] as? String == "Window Server"
                && w[kCGWindowName as String] as? String == "StatusIndicator"
        }
    }

    static var mirroring: Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains { CGDisplayIsInMirrorSet($0) != 0 }
    }

    /// Keynote or PowerPoint in front with a window covering a whole display.
    static var slideshow: Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              slideshowApps.contains(app.bundleIdentifier ?? "") else { return false }
        let screens = NSScreen.screens.map { $0.frame.size }
        return windows([.optionOnScreenOnly, .excludeDesktopElements]).contains { w in
            guard w[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier,
                  let bounds = w[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            return screens.contains { $0.width == bounds["Width"] && $0.height == bounds["Height"] }
        }
    }

    private static func windows(_ options: CGWindowListOption) -> [[String: Any]] {
        CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    }
}

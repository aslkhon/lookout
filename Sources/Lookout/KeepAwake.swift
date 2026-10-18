import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac from idle-sleeping while agents work, so a long turn isn't cut off. The display
/// still sleeps (and the screen still locks) as usual.
@MainActor
final class KeepAwake {
    static let shared = KeepAwake()
    static let key = "keepAwake"

    private var assertion: IOPMAssertionID = 0
    private var held = false

    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }

    func update(working: Bool) {
        let want = working && Self.enabled
        guard want != held else { return }
        if want {
            held = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                               IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                               "Lookout: agents are working" as CFString, &assertion) == kIOReturnSuccess
        } else {
            IOPMAssertionRelease(assertion)
            held = false
        }
    }
}

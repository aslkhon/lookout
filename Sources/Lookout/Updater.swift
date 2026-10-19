import AppKit
import Sparkle

/// Updates through Sparkle. The feed is appcast.xml on the latest GitHub release, and each
/// update is checked against the EdDSA key in Info.plist, so ad-hoc signing is enough.
@MainActor
final class Updater: NSObject, ObservableObject {
    static let shared = Updater()

    private var controller: SPUStandardUpdaterController!
    @Published private(set) var canCheck = false

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    }

    var checksAutomatically: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }

    func check() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}

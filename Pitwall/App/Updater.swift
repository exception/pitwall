import AppKit
import Sparkle

/// Self-updates via Sparkle. The feed (SUFeedURL) is the appcast.xml attached
/// to the latest GitHub release; updates are verified against SUPublicEDKey.
/// Both live in Info.plist; scripts/release.sh writes and signs the appcast.
final class Updater {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController

    private init() {
        // Debug builds run out of DerivedData: never check on their own (an
        // update would replace the dev build), but the menu item still works.
        #if DEBUG
        let start = false
        #else
        let start = true
        #endif
        controller = SPUStandardUpdaterController(startingUpdater: start, updaterDelegate: nil, userDriverDelegate: nil)
        started = start
    }

    private var started: Bool

    func checkForUpdates() {
        if !started { controller.startUpdater(); started = true }
        controller.checkForUpdates(nil)
    }
}

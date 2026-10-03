import Sparkle

/// Keeps the app up to date from GitHub Releases. Checks on launch, downloads
/// in the background, and relaunches on the new version as soon as it's ready.
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()

    private var controller: SPUStandardUpdaterController?

    /// Start the updater and check for a new build right away.
    func start() {
        #if !DEBUG // Development builds shouldn't replace themselves with published ones.
        guard controller == nil else { return }
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        controller = c
        c.updater.checkForUpdatesInBackground()
        #endif
    }

    var canCheck: Bool { controller != nil }

    /// "Check for Updates…" in the app menu.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    // Install as soon as the update is downloaded instead of waiting for the app to quit.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        immediateInstallHandler()
        return true
    }
}

import AppKit
import Sparkle

/// In-place updates through Sparkle, fitted to an app that lives in the menu bar.
///
/// A menu bar app has no window for Sparkle's alert to appear in front of, so a scheduled
/// check that finds an update only raises a card in the popover (Sparkle's "gentle
/// reminder"); pressing it brings Sparkle's own dialog forward to download and install.
@MainActor
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    /// The version a background check found, until the person has looked at it.
    @Published private(set) var availableVersion: String?
    private var controller: SPUStandardUpdaterController?

    /// Only a release build can update itself: it carries the feed's address and the public
    /// half of the key the feed is signed with. A local build has neither and stays as it is.
    static var isConfigured: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        return info["SUFeedURL"] is String && info["SUPublicEDKey"] is String
    }

    override init() {
        super.init()
        guard Updater.isConfigured else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        // 1.0.0 kept its own switch for this; a person who turned it off stays opted out.
        let legacyKey = "checksForUpdates"
        if UserDefaults.standard.object(forKey: legacyKey) as? Bool == false {
            controller?.updater.automaticallyChecksForUpdates = false
        }
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }

    var canCheck: Bool { controller != nil }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// Brings Sparkle's dialog forward: the update that was found, or a fresh check.
    func showUpdate() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    // MARK: Gentle reminders

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Right after launch the app has the person's attention and Sparkle may show its
    /// alert; any other time the popover's card stands in for it.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        let version = update.displayVersionString
        Task { @MainActor in self.availableVersion = version }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in self.availableVersion = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in self.availableVersion = nil }
    }
}

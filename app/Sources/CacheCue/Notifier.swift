import AppKit
import UserNotifications
import CacheCueCore

/// System notifications, for what the menu bar cannot say to someone who is not looking at
/// it: a cache about to go cold, a limit filling up. Off until the person turns an alert on,
/// which is also the first time macOS is asked for permission.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private nonisolated static let sessionKey = "session"

    /// Brings a session into view when its notification is pressed.
    var showSession: ((String) -> Void)?

    /// Notifications belong to an app bundle; the bare executable (a test, `--render`) has none.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil
    }

    func start() {
        center?.delegate = self
    }

    /// Asks macOS for permission, the first time; answers false when it is refused, now or before.
    func authorize(_ done: @escaping (Bool) -> Void) {
        guard let center else { return done(false) }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in done(granted) }
        }
    }

    func post(_ alert: Alert, strings: Strings) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title(strings)
        content.body = alert.body(strings)
        content.sound = .default
        if let sessionID = alert.sessionID {
            content.userInfo = [Notifier.sessionKey: sessionID]
        }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // The app has no window to be in front, so a notification shows whenever it arrives.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let sessionID = response.notification.request.content.userInfo[Notifier.sessionKey] as? String
        Task { @MainActor in
            if let sessionID { self.showSession?(sessionID) }
            completionHandler()
        }
    }
}

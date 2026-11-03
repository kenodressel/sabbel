import Foundation
import SabbelCore
@preconcurrency import UserNotifications

/// User notifications through `UNUserNotificationCenter`: banner only, no sound.
///
/// Delivery is best effort: a failure is logged, never thrown. A notification
/// that cannot be shown must not cost the user their dictation.
public final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let log: @Sendable (String) -> Void
    /// Nil when the process has no bundle identifier (the unbundled dev binary),
    /// where `UNUserNotificationCenter.current()` raises. Notices are only logged then.
    private let center: UNUserNotificationCenter?

    public init(log: @escaping @Sendable (String) -> Void) {
        self.log = log
        center = Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
        super.init()
        center?.delegate = self
    }

    /// Asks once for permission to show alerts (no sound, no badge).
    public func requestAuthorization() {
        guard let center else {
            log("Notifications unavailable: not running from an app bundle")
            return
        }
        let log = self.log
        center.requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                log("Notification authorization failed: \(error.localizedDescription)")
            } else if !granted {
                log("Notifications not allowed by the user")
            }
        }
    }

    /// Title "Sabbel", the notice's subtitle and message, word for word.
    static func content(for notice: Notice) -> (title: String, subtitle: String, body: String) {
        ("Sabbel", notice.subtitle, notice.message)
    }

    public func post(_ notice: Notice) {
        let c = Self.content(for: notice)
        guard let center else {
            log("Notification (not shown, no app bundle): \(c.subtitle)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = c.title
        content.subtitle = c.subtitle
        content.body = c.body
        content.sound = nil
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        let log = self.log
        center.add(request) { error in
            if let error { log("Failed to deliver notification '\(c.subtitle)': \(error.localizedDescription)") }
        }
    }

    /// Show banners even while Sabbel counts as the active app (menu open,
    /// live panel clicked); by default macOS hides them then.
    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

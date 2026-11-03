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
    /// where `UNUserNotificationCenter.current()` raises, or when the caller
    /// asked for a record-only notifier. Notices are only logged then.
    private let center: UNUserNotificationCenter?
    /// Why `center` is nil, for the log.
    private let unavailable: String

    /// - Parameter notificationCenter: false never touches
    ///   `UNUserNotificationCenter`, so the process never registers with
    ///   Notification Center (the `--e2e` run shares the app's bundle id).
    public init(log: @escaping @Sendable (String) -> Void, notificationCenter: Bool = true) {
        self.log = log
        if !notificationCenter {
            center = nil
            unavailable = "record-only notifier"
        } else if Bundle.main.bundleIdentifier == nil {
            center = nil
            unavailable = "not running from an app bundle"
        } else {
            center = UNUserNotificationCenter.current()
            unavailable = ""
        }
        super.init()
        center?.delegate = self
    }

    public var usesNotificationCenter: Bool { center != nil }

    /// Asks once for permission to show alerts (no sound, no badge).
    public func requestAuthorization() {
        guard let center else {
            log("Notifications unavailable: \(unavailable)")
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
            log("Notification (not shown, \(unavailable)): \(c.subtitle)")
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

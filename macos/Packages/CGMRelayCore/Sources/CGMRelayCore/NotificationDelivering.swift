import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// NotificationDelivering is CGM Relay's own seam onto the system
/// notification center: requesting permission and delivering one alert.
/// AlertEngine's own tests never touch this at all -- they only compute
/// which alerts fired -- so this protocol exists purely so AppModel can
/// wire that decision to an actual notification in production while a
/// test fakes the wiring with no UNUserNotificationCenter involved.
public protocol NotificationDelivering: Sendable {
    /// requestAuthorization asks the person for permission, returning
    /// whether it was granted. Called only when a person turns an alert
    /// on, never proactively at launch.
    func requestAuthorization() async -> Bool
    /// deliver shows one notification. A caller checks requestAuthorization's
    /// own result (or an earlier grant) before ever calling this; it is
    /// not itself responsible for asking again.
    func deliver(title: String, body: String) async
}

#if canImport(UserNotifications)
/// UserNotificationCenterDelivering is the production NotificationDelivering,
/// backed by UNUserNotificationCenter.
public struct UserNotificationCenterDelivering: NotificationDelivering {
    public init() {}

    public func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    public func deliver(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
#endif

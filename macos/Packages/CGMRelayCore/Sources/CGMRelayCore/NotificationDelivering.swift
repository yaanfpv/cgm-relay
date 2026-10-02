import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// NotificationAuthorization is the system's answer about notification
/// permission, reduced to the three cases the app acts on.
public enum NotificationAuthorization: Sendable, Equatable {
    /// notDetermined means nobody has been asked yet; asking shows the
    /// system's own prompt.
    case notDetermined
    /// denied means the person refused, or turned notifications off in
    /// System Settings; only System Settings can change it now.
    case denied
    /// allowed means notifications can be delivered.
    case allowed
}

/// NotificationDelivering is CGM Relay's own seam onto the system
/// notification center: requesting permission and delivering one alert.
/// AlertEngine's own tests never touch this at all -- they only compute
/// which alerts fired -- so this protocol exists purely so AppModel can
/// wire that decision to an actual notification in production while a
/// test fakes the wiring with no UNUserNotificationCenter involved.
public protocol NotificationDelivering: Sendable {
    /// authorization is what the system says right now about this app's
    /// permission to show notifications, read fresh each time.
    func authorization() async -> NotificationAuthorization
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

    public func authorization() async -> NotificationAuthorization {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral: return .allowed
        @unknown default: return .denied
        }
    }

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

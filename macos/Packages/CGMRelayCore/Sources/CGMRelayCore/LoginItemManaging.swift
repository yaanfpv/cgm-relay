#if canImport(ServiceManagement)
import ServiceManagement
#endif

/// LoginItemStatus mirrors SMAppService.Status in this app's own terms.
public enum LoginItemStatus: Sendable, Equatable {
    /// enabled means the app opens at login already.
    case enabled
    /// disabled means it does not, whether because nobody has asked yet
    /// or because a person turned it off.
    case disabled
    /// requiresApproval means register() already succeeded, but the
    /// person still has to approve it in System Settings' own Login
    /// Items list before it actually opens at login.
    case requiresApproval
    /// notFound means this build has no login item helper for the system
    /// to register at all -- unexpected outside development, but never a
    /// reason to crash the General pane over.
    case notFound
}

/// LoginItemManaging wraps SMAppService so the General pane's Open at
/// Login toggle is testable with no real login item ever registered:
/// production code uses SMAppServiceLoginItemManager; tests use a fake
/// that just remembers what was called.
public protocol LoginItemManaging: Sendable {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

#if canImport(ServiceManagement)
/// SMAppServiceLoginItemManager is the production LoginItemManaging,
/// backed by SMAppService.mainApp. Reading status never has a side
/// effect; only an explicit register()/unregister() call, driven by the
/// person's own toggle, changes anything.
public struct SMAppServiceLoginItemManager: LoginItemManaging {
    public init() {}

    public var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .disabled
        case .notFound: return .notFound
        @unknown default: return .disabled
        }
    }

    public func register() throws {
        try SMAppService.mainApp.register()
    }

    public func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}
#endif

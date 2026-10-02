import Foundation
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
    /// notFound means Open at Login is not available: a development build
    /// with no fake, or a registration the system refused.
    case notFound
}

/// LoginItemManaging wraps SMAppService so the Open at Login controls are
/// testable with no real login item ever registered: production code uses
/// SystemLoginItemManager; tests and development walks use
/// FileBackedLoginItemManager.
public protocol LoginItemManaging: Sendable {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

/// SystemLoginItemStatus is the system's own answer about this app's login
/// item, before it is put in this app's terms.
public enum SystemLoginItemStatus: Sendable, Equatable {
    case enabled, requiresApproval, notRegistered, notFound
}

/// SystemLoginItem is the system's login item service seen through the one
/// value and two calls the app uses, so the mapping below is testable with
/// no real registration.
public protocol SystemLoginItem: Sendable {
    var status: SystemLoginItemStatus { get }
    func register() throws
    func unregister() throws
}

/// SystemLoginItemManager is the production LoginItemManaging over the
/// system's login item service. Reading status never has a side effect;
/// only an explicit register()/unregister() call, driven by the person's
/// own toggle, changes anything.
public struct SystemLoginItemManager: LoginItemManaging {
    private let item: any SystemLoginItem

    public init(item: any SystemLoginItem = MainAppLoginItem()) {
        self.item = item
    }

    /// The system reports notFound for a main app it has never been asked to
    /// register, which is every fresh install, so it reads as off with Turn
    /// On available. Unavailable is only ever what a failed register() says.
    public var status: LoginItemStatus {
        switch item.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .disabled
        }
    }

    public func register() throws {
        try item.register()
    }

    public func unregister() throws {
        try item.unregister()
    }
}

#if canImport(ServiceManagement)
/// MainAppLoginItem is SMAppService.mainApp.
public struct MainAppLoginItem: SystemLoginItem {
    public init() {}

    public var status: SystemLoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .notRegistered
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

/// LoginItemFailure turns the error a failed registration threw into the
/// system's own reason, one plain sentence.
public enum LoginItemFailure {
    public static func reason(for error: Error) -> String {
        if error is LoginItemUnavailableError {
            return "This build can't open at login."
        }
        let nsError = error as NSError
        let text = nsError.localizedFailureReason ?? nsError.localizedDescription
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "The system refused to add CGM Relay to Login Items." }
        return trimmed.hasSuffix(".") ? trimmed : trimmed + "."
    }
}

/// FileBackedLoginItemManager keeps a login item's state in one small file
/// instead of the system's Login Items list, so a development run can turn
/// Open at Login on and off, and reach every state, without registering
/// anything for real. The file holds one word: enabled, disabled,
/// requiresApproval or notFound; a missing or unreadable file reads as
/// disabled.
public struct FileBackedLoginItemManager: LoginItemManaging {
    public let stateFile: URL

    public init(stateFile: URL) {
        self.stateFile = stateFile
    }

    public var status: LoginItemStatus {
        let word = (try? String(contentsOf: stateFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch word {
        case "enabled": return .enabled
        case "requiresApproval": return .requiresApproval
        case "notFound": return .notFound
        default: return .disabled
        }
    }

    /// register turns a disabled item on, leaves one that is waiting for
    /// approval waiting, and fails where the system would: with no login
    /// item helper in this build.
    public func register() throws {
        switch status {
        case .notFound: throw LoginItemUnavailableError.notFound
        case .disabled: try write("enabled")
        case .enabled, .requiresApproval: break
        }
    }

    public func unregister() throws {
        if status == .notFound { throw LoginItemUnavailableError.notFound }
        try write("disabled")
    }

    private func write(_ word: String) throws {
        try word.write(to: stateFile, atomically: true, encoding: .utf8)
    }
}

public enum LoginItemUnavailableError: Error, Equatable {
    case notFound
}

/// UnavailableLoginItemManager is what a debug build uses when no login
/// item fake was asked for: it reads as not available and refuses to
/// register, so a debug build can never put a real login item on the
/// developer's Mac.
public struct UnavailableLoginItemManager: LoginItemManaging {
    public init() {}
    public var status: LoginItemStatus { .notFound }
    public func register() throws { throw LoginItemUnavailableError.notFound }
    public func unregister() throws { throw LoginItemUnavailableError.notFound }
}

/// LoginItemFakeLocator decides whether a launch uses a file-backed login
/// item. Only a debug build does, and only when the launch also names a
/// throwaway Keychain service, exactly as the synthetic account seed and
/// the Tailscale fake do: a debug build shares the real bundle identifier,
/// so registering for real from one would put a login item on the
/// developer's own Mac.
public enum LoginItemFakeLocator {
    /// resolve returns the state file to use, or nil when the launch uses
    /// the system's login items.
    public static func resolve(
        isDebugBuild: Bool,
        fakePath: String?,
        explicitKeychainServiceOverride: String?
    ) -> URL? {
        guard
            isDebugBuild,
            let fakePath, !fakePath.isEmpty,
            SyntheticAccountSeeder.isThrowawayService(explicitKeychainServiceOverride)
        else {
            return nil
        }
        return URL(fileURLWithPath: fakePath)
    }
}

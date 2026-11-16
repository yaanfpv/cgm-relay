import Foundation
import ServiceManagement

/// SleepHelperStatus is where the sleep reset helper stands with the system.
public enum SleepHelperStatus: Equatable, Sendable {
    case notRegistered
    /// The system cannot find the helper in this app, as in a bundle that
    /// was built without it.
    case notFound
    /// Registered, waiting for the person to approve it in System Settings.
    case requiresApproval
    case enabled
}

/// SleepHelperRegistering registers the sleep reset helper with the system.
/// There is deliberately no way to unregister it: once the person has
/// approved it, it stays.
public protocol SleepHelperRegistering: Sendable {
    var status: SleepHelperStatus { get }
    func register() throws
}

/// SMAppServiceSleepHelper registers the helper daemon that ships inside
/// the app bundle. The system asks the person to approve it once, in
/// System Settings under Login Items.
public struct SMAppServiceSleepHelper: SleepHelperRegistering {
    public init() {}

    private var service: SMAppService { SMAppService.daemon(plistName: SleepResetHelper.daemonPlistName) }

    public var status: SleepHelperStatus {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    public func register() throws {
        try service.register()
    }
}

/// SleepHelperSettings opens the place where the person approves the helper.
public enum SleepHelperSettings {
    public static func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// InertSleepHelper is the helper in a run on throwaway data: nothing is
/// registered, and asking to register reaches nothing.
public struct InertSleepHelper: SleepHelperRegistering {
    public init() {}
    public var status: SleepHelperStatus { .notRegistered }
    public func register() throws {}
}

/// SleepResetDecision is what the helper does on one look at the Mac.
public enum SleepResetDecision: Equatable, Sendable {
    case writeOff
    case leaveAlone
}

/// SleepResetPolicy is the helper's whole decision: with CGM Relay not
/// running, a sleep setting that is on or cannot be read is written off,
/// on power or on battery. While CGM Relay runs the helper never writes,
/// since the app owns the setting then.
public enum SleepResetPolicy {
    public static func decide(appRunning: Bool, onBattery: Bool, sleepDisabled: Bool?) -> SleepResetDecision {
        if appRunning { return .leaveAlone }
        return sleepDisabled == false ? .leaveAlone : .writeOff
    }
}

/// SleepResetHelper names what the helper daemon is and the little it may
/// do: one fixed command, and two things it reads to decide on it.
public enum SleepResetHelper {
    /// Input is something the helper reads.
    public enum Input: Equatable, Sendable {
        case processList
        case powerSource
    }

    /// command is the only command the helper ever runs.
    public static let command = ["/usr/bin/pmset", "-a", "disablesleep", "0"]
    public static let inputs: [Input] = [.processList, .powerSource]

    /// daemonPlistName is the launchd plist inside the app bundle, in
    /// Contents/Library/LaunchDaemons.
    public static let daemonPlistName = "com.yaanfpv.cgmrelay.sleep-helper.plist"
    public static let daemonLabel = "com.yaanfpv.cgmrelay.sleep-helper"
    public static let daemonExecutableName = "cgm-relay-sleep-helper"

    /// appBundleIdentifier is the app whose process the helper looks for.
    public static let appBundleIdentifier = "com.yaanfpv.cgmrelay"
    /// appExecutableName narrows the process list to look at; it decides
    /// nothing, the code signature requirement does.
    public static let appExecutableName = "CGM Relay"
    /// appRequirement is the code signing requirement a running process has
    /// to meet to count as this app: its signing identifier is the bundle
    /// identifier, and an Apple-issued certificate signed it.
    public static let appRequirement = "identifier \"\(appBundleIdentifier)\" and anchor apple generic"
}

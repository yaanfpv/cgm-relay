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

    /// ProcessListing is the process list as the helper reads it, in the four
    /// reads appIsRunning needs, so the system calls stay in the helper's
    /// main.swift.
    public struct ProcessListing {
        /// countHint is the number of processes the system reports before the
        /// list is copied.
        public var countHint: () -> Int32
        /// fill copies pids into the buffer and returns how many it copied.
        public var fill: (inout [pid_t]) -> Int32
        public var executableName: (pid_t) -> String?
        /// isGenuineApp is whether the process meets appRequirement.
        public var isGenuineApp: (pid_t) -> Bool

        public init(
            countHint: @escaping () -> Int32,
            fill: @escaping (inout [pid_t]) -> Int32,
            executableName: @escaping (pid_t) -> String?,
            isGenuineApp: @escaping (pid_t) -> Bool
        ) {
            self.countHint = countHint
            self.fill = fill
            self.executableName = executableName
            self.isGenuineApp = isGenuineApp
        }
    }

    /// listSlack is how many slots the buffer holds beyond countHint.
    static let listSlack = 64

    /// appIsRunning is whether CGM Relay counts as running. It reads the list
    /// once into a buffer of countHint plus listSlack slots. A list that is
    /// not proven whole (nothing copied, or the copy filled the buffer, so
    /// more may exist) counts as running; only a whole list with no genuine
    /// process of the app says it is not. A process whose name or signature
    /// cannot be read is skipped.
    public static func appIsRunning(using listing: ProcessListing) -> Bool {
        let hint = listing.countHint()
        guard hint > 0 else { return true }
        var pids = [pid_t](repeating: 0, count: Int(hint) + listSlack)
        let filled = listing.fill(&pids)
        guard filled > 0, Int(filled) < pids.count else { return true }
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            guard listing.executableName(pid) == appExecutableName else { continue }
            if listing.isGenuineApp(pid) { return true }
        }
        return false
    }

    /// Look is the helper's state across looks: whether a write was made while
    /// the setting could not be read, so an unreadable setting does not run
    /// the command at every look.
    public struct Look {
        private var wroteWithoutReading = false

        public init() {}

        /// powerSourceChanged clears what a power source change could have
        /// changed the answer to.
        public mutating func powerSourceChanged() {
            wroteWithoutReading = false
        }

        /// run is one look: it decides with SleepResetPolicy and calls
        /// runCommand, which returns whether the command succeeded, only for
        /// a write.
        public mutating func run(
            appRunning: Bool, onBattery: Bool, sleepDisabled: Bool?, runCommand: () -> Bool
        ) {
            if appRunning || sleepDisabled != nil { wroteWithoutReading = false }
            guard SleepResetPolicy.decide(
                appRunning: appRunning, onBattery: onBattery, sleepDisabled: sleepDisabled
            ) == .writeOff else { return }
            if sleepDisabled == nil && wroteWithoutReading { return }
            if runCommand() && sleepDisabled == nil { wroteWithoutReading = true }
        }
    }
}

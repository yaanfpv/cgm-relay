import AppKit
import CGMRelayCore
import Combine
import Sparkle

/// UpdatesModel owns the app's one Sparkle updater and is both its
/// delegates, so the app menu, the right-click menu, the panel, About and
/// Settings all drive the same session and read the same state.
///
/// A scheduled check never takes focus: the update is shown as a quiet
/// indicator (`pending`) and Sparkle's own window opens only when the
/// person asks. A build with no public key starts no updater at all.
@MainActor
final class UpdatesModel: NSObject, ObservableObject {
    enum Availability: Equatable {
        case running
        /// noPublicKey is a build no release has signed for, which has nothing
        /// to verify an update against and so never starts the updater.
        case noPublicKey
        case failedToStart(String)
    }

    static let noPublicKeyNote = "Updates start with the first public release."

    private(set) var availability = Availability.noPublicKey
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var lastCheckDate: Date?
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var automaticallyDownloads = false
    @Published private(set) var pending: PendingUpdate = .none
    private var controller: SPUStandardUpdaterController?
    private var restartNow: (() -> Void)?
    private let feedURLOverride: String?

    /// feedURLOverride is honoured only in a DEBUG build, and only where the
    /// caller has already checked that the launch named a throwaway service.
    init(feedURLOverride: String? = nil) {
        self.feedURLOverride = feedURLOverride
        super.init()
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard Self.isUsableKey(key) else { return }
        // The controller keeps only a weak reference to its delegates, so
        // this object outlives it, and the updater starts only once both
        // delegates are in place.
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        do {
            try controller.updater.start()
        } catch {
            availability = .failedToStart(error.localizedDescription)
            return
        }
        self.controller = controller
        availability = .running
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).receive(on: DispatchQueue.main).assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.lastUpdateCheckDate).receive(on: DispatchQueue.main).assign(to: &$lastCheckDate)
        updater.publisher(for: \.automaticallyChecksForUpdates).receive(on: DispatchQueue.main).assign(to: &$automaticallyChecks)
        updater.publisher(for: \.automaticallyDownloadsUpdates).receive(on: DispatchQueue.main).assign(to: &$automaticallyDownloads)
    }

    /// isUsableKey is false for the empty value a build without a release key
    /// carries, and for a build setting left unexpanded.
    static func isUsableKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.contains("$(")
    }

    /// unavailableNote says why the update controls do nothing, or is nil
    /// when they work.
    var unavailableNote: String? {
        switch availability {
        case .running: return nil
        case .noPublicKey: return Self.noPublicKeyNote
        case .failedToStart(let reason): return "Updates could not start: \(reason)"
        }
    }

    var isRunning: Bool { controller != nil }

    /// menuTitle is the title of the one entry that checks for, shows or
    /// installs an update.
    var menuTitle: String { pending.menuTitle }

    /// canPerformAction is whether that entry can be used right now: never
    /// while a check is already open, but always to restart into an update
    /// that is ready.
    var canPerformAction: Bool {
        guard isRunning else { return false }
        if case .readyToRestart = pending { return true }
        return canCheckForUpdates
    }

    /// perform is the one action behind every entry: install a ready update,
    /// bring an available one into view, or check.
    func perform() {
        guard canPerformAction else { return }
        if case .readyToRestart = pending {
            restartNow?()
        } else {
            controller?.checkForUpdates(nil)
        }
    }

    func setAutomaticallyChecks(_ on: Bool) {
        controller?.updater.automaticallyChecksForUpdates = on
    }

    func setAutomaticallyDownloads(_ on: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = on
    }
}

extension UpdatesModel: SPUUpdaterDelegate {
    #if DEBUG
    func feedURLString(for updater: SPUUpdater) -> String? {
        feedURLOverride
    }
    #endif

    /// A downloaded update installs when the app quits. The relay is never
    /// restarted on its own, so this keeps the moment in the person's hands
    /// and offers it as Restart to Update.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        restartNow = immediateInstallHandler
        pending = .readyToRestart(version: item.displayVersionString)
        return true
    }
}

/// Sparkle's user driver delegate is not annotated for the main actor, but
/// Sparkle only ever calls it there.
extension UpdatesModel: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A scheduled update never opens Sparkle's window on its own, however
    /// soon after launch it is found.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if state.userInitiated {
            NSApp.setActivationPolicy(.regular)
        } else {
            pending = .available(version: update.displayVersionString)
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        clearAvailable()
    }

    func standardUserDriverWillFinishUpdateSession() {
        clearAvailable()
    }

    private func clearAvailable() {
        if case .available = pending {
            pending = .none
        }
    }
}

/// AppVersion is the running app's own version and build number.
enum AppVersion {
    static var short: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    }
}

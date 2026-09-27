import AppKit
import CGMRelayCore
import Foundation
import os

/// AppModel is CGM Relay's own coordinator: it bootstraps the app's
/// generated credentials, supervises the engine process, polls its
/// status, and exposes exactly what the menu needs to render as
/// @Published state. Everything it depends on is a CGMRelayCore
/// protocol; the mapping, supervision, and polling logic it wires
/// together are each tested directly in CGMRelayCoreTests, so this type
/// carries no logic of its own worth testing beyond that wiring.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var menuState: MenuDisplayState
    @Published private(set) var credentialsConfigured = false
    @Published private(set) var engineState: EngineSupervisor.RunState = .stopped

    private let credentialStore: any CredentialStore
    private let supervisor: EngineSupervisor
    private let statusPoller: StatusPoller
    private let listenAddr: String
    private let statusAddr: String
    private let databasePath: String
    private let retentionDays: Int
    private let librelinkupBaseURL: String?

    private var latestStatus: EngineStatus?

    /// recoveryLogger carries this file's own recovery diagnostics -- only
    /// ever a failure to move the old database aside, which is rare (a
    /// permissions problem) and never carries a secret. Not DEBUG-only:
    /// "Start Fresh…" is a real recovery path for every person running
    /// this app, not a development tool.
    private let recoveryLogger = Logger(subsystem: "com.yaanfpv.cgmrelay", category: "recovery")

    var canStart: Bool { credentialsConfigured && engineState == .stopped }

    /// canStop is true only while stopping would actually change
    /// something: a running engine, one still starting, or one waiting on
    /// a pending restart. A permanently failed engine offers its own
    /// recovery instead ("Try Again" or "Start Fresh…"), never "Stop",
    /// since nothing is running or scheduled to.
    var canStop: Bool {
        switch engineState {
        case .starting, .running, .waitingToRestart:
            return true
        case .stopped, .failed:
            return false
        }
    }

    /// canStartFresh is true only for the permanent failures a moved-
    /// aside database can actually fix: a database sealed with a key this
    /// Mac no longer has, a database SQLite cannot read at all, and a
    /// database Start Fresh already tried and failed to move. It excludes
    /// configurationUnreadable, whose database may open perfectly well --
    /// moving it aside there would cost the person their history for
    /// nothing -- and storeInUse, whose database is perfectly readable by
    /// whichever copy currently holds it: moving it aside there would
    /// rename a file the other copy is actively using out from under it.
    var canStartFresh: Bool {
        switch engineState {
        case .failed(.storeKeyMismatch), .failed(.recoveryMoveFailed), .failed(.storeDamaged):
            return true
        case .failed(.configurationUnreadable), .failed(.storeInUse), .stopped, .starting, .running, .waitingToRestart:
            return false
        }
    }

    /// canTryAgain is true for the permanent failures a plain re-run can
    /// actually fix, since nothing was ever written to disk that a
    /// move-aside would need to recover first: configurationUnreadable,
    /// and storeInUse, since the other copy holding the lock may quit at
    /// any time, and this is what makes that quit take effect the moment
    /// the menu is next opened rather than needing a manual click.
    var canTryAgain: Bool {
        switch engineState {
        case .failed(.configurationUnreadable), .failed(.storeInUse):
            return true
        case .failed(.storeKeyMismatch), .failed(.storeDamaged), .failed(.recoveryMoveFailed), .stopped, .starting, .running, .waitingToRestart:
            return false
        }
    }

    init(
        engineURL: URL,
        credentialStore: any CredentialStore = KeychainCredentialStore(),
        listenAddr: String = "127.0.0.1:1337",
        statusAddr: String = "127.0.0.1:1338",
        databasePath: String,
        retentionDays: Int = 15,
        librelinkupBaseURL: String? = nil
    ) {
        self.credentialStore = credentialStore
        self.listenAddr = listenAddr
        self.statusAddr = statusAddr
        self.databasePath = databasePath
        self.retentionDays = retentionDays
        self.librelinkupBaseURL = librelinkupBaseURL
        menuState = .make(credentialsConfigured: false, engineState: .stopped, status: nil, now: Date())

        // A weak box, rather than capturing self, because Swift forbids
        // referring to self in a class's own init before every stored
        // property has a value -- and the closures below are themselves
        // stored properties (via supervisor/statusPoller) that must be
        // built before that point.
        let ref = AppModelRef()
        supervisor = EngineSupervisor(engineURL: engineURL, launcher: RealProcessLauncher()) { state in
            Task { @MainActor in ref.value?.handleEngineStateChange(state) }
        }
        statusPoller = StatusPoller(
            fetcher: URLSessionStatusFetcher(statusURL: AppModel.statusURL(for: statusAddr))
        ) { status in
            Task { @MainActor in ref.value?.handleStatusUpdate(status) }
        }
        ref.value = self

        // Scene has no equivalent of a view's own .task, so the app's
        // one-time launch sequence starts here instead, the moment the
        // model itself is fully constructed.
        Task { [weak self] in await self?.onLaunch() }
    }

    /// onLaunch runs the app's ordinary startup: generate a token and
    /// store key on a first launch, start the engine if a LibreLinkUp
    /// account is already on file, and begin polling its status. Starting
    /// the engine and starting the status poller run concurrently rather
    /// than one after the other, so a slow first Keychain read never
    /// delays the status display coming up.
    func onLaunch() async {
        try? CredentialsBootstrapper(store: credentialStore).ensureBootstrapped()
        refreshCredentialsConfigured()
        async let engineStarted: Void = canStart ? startEngine() : ()
        async let pollerStarted: Void = statusPoller.start()
        _ = await (engineStarted, pollerStarted)
    }

    /// onMenuOpened refreshes the status immediately, so opening the menu
    /// never shows a reading that is stale only because the slow timer
    /// has not fired since it changed. It also retries a
    /// configurationUnreadable or storeInUse failure on its own, so a
    /// Keychain that was only briefly unavailable, or another copy that
    /// has since quit, recovers the moment the menu is opened, with no
    /// click needed.
    func onMenuOpened() {
        refreshCredentialsConfigured()
        if canTryAgain {
            tryAgain()
        }
        Task { await statusPoller.pollNow() }
    }

    func start() {
        guard canStart else { return }
        Task { await startEngine() }
    }

    func stop() {
        Task { await supervisor.stop() }
    }

    /// startFresh recovers from a permanently failed engine: it moves the
    /// database that failed aside (never deleting it), then starts the
    /// engine again against a fresh one at the same path. A no-op unless
    /// canStartFresh is currently true, checked again the moment the
    /// scheduled Task actually runs -- not just when the button was
    /// pressed -- since nothing here moves anything until then. If the
    /// move itself fails, the engine is never started against whatever
    /// is left at the original path -- the menu shows the move failure
    /// instead, rather than silently retrying into the same state. A
    /// locked database is not a move failure at all: it means another
    /// copy of the app currently holds it open, which is exactly what
    /// storeInUse already describes, so that case is reported there
    /// instead of blaming the folder's permissions.
    func startFresh() {
        guard canStartFresh else { return }
        Task {
            guard canStartFresh else { return }
            await supervisor.clearFailure()
            do {
                try DatabaseRecovery.moveAside(databasePath: databasePath)
            } catch DatabaseRecoveryError.locked {
                await supervisor.fail(.storeInUse)
                return
            } catch {
                recoveryLogger.error("could not move the unreadable database aside: \(error, privacy: .public)")
                await supervisor.fail(.recoveryMoveFailed)
                return
            }
            await startEngine()
        }
    }

    /// tryAgain re-runs the ordinary launch sequence for a
    /// configurationUnreadable or storeInUse failure: clear the failure,
    /// run CredentialsBootstrapper again, then start the engine. A no-op
    /// unless canTryAgain is currently true.
    func tryAgain() {
        guard canTryAgain else { return }
        Task {
            await supervisor.clearFailure()
            try? CredentialsBootstrapper(store: credentialStore).ensureBootstrapped()
            await startEngine()
        }
    }

    func quit() {
        Task {
            await supervisor.stop()
            await statusPoller.stop()
            NSApplication.shared.terminate(nil)
        }
    }

    /// startEngine assembles the engine's configuration and starts it. A
    /// nil or throwing build (a Keychain read failed, or the token or
    /// store key CredentialsBootstrapper should already have generated is
    /// missing) is a permanent failure, not a silent no-op: canStart
    /// requires engineState == .stopped, and leaving it .stopped here
    /// would leave the menu showing "Stopped" beside a Start button that
    /// fails the exact same way every time it is pressed again.
    ///
    /// Before any of that, it checks whether this database is genuinely
    /// split by an earlier move aside that never finished or rolled back:
    /// starting the engine there would let it create a fresh main file at
    /// the original path and replay only the sidecar left behind, which
    /// later reads as a whole set and buries the rest of the old data
    /// under a second, unrelated dated base. Reporting the same failure
    /// Start Fresh itself reports keeps that recovery path the only way
    /// forward, exactly as if the move had just failed.
    private func startEngine() async {
        if DatabaseRecovery.hasSplitMove(databasePath: databasePath) {
            await supervisor.fail(.recoveryMoveFailed)
            return
        }
        guard
            let config = try? EngineConfigurationBuilder.build(
                from: credentialStore,
                listenAddr: listenAddr,
                statusAddr: statusAddr,
                databasePath: databasePath,
                retentionDays: retentionDays,
                librelinkupBaseURL: librelinkupBaseURL
            )
        else {
            await supervisor.fail(.configurationUnreadable)
            return
        }
        await supervisor.start(configuration: config)
    }

    private func refreshCredentialsConfigured() {
        let email = try? credentialStore.string(for: .librelinkupEmail)
        let password = try? credentialStore.string(for: .librelinkupPassword)
        credentialsConfigured = !(email ?? "").isEmpty && !(password ?? "").isEmpty
        recomputeMenuState()
    }

    private func handleEngineStateChange(_ state: EngineSupervisor.RunState) {
        engineState = state
        recomputeMenuState()
    }

    /// handleStatusUpdate keeps the last successfully fetched status on a
    /// failed fetch, rather than replacing it with nil: a poll fails for
    /// as ordinary a reason as the engine being stopped or between
    /// restarts, and none of those mean the reading it last reported is
    /// no longer real. Discarding it there would make the menu claim
    /// there has never been a reading right after it showed one. Only a
    /// fresh, successful fetch ever replaces what is shown.
    private func handleStatusUpdate(_ status: EngineStatus?) {
        if let status {
            latestStatus = status
        }
        recomputeMenuState()
    }

    private func recomputeMenuState() {
        menuState = .make(
            credentialsConfigured: credentialsConfigured,
            engineState: engineState,
            status: latestStatus,
            now: Date()
        )
    }

    private static func statusURL(for statusAddr: String) -> URL {
        URL(string: "http://\(statusAddr)/status") ?? URL(string: "http://127.0.0.1:1338/status")!
    }
}

/// AppModelRef is a plain weak box. It lets the supervisor's and
/// poller's update closures be created before `self` exists and still
/// reach it once it does, without ever holding AppModel alive on their
/// own account.
private final class AppModelRef: @unchecked Sendable {
    weak var value: AppModel?
}

import AppKit
import CGMRelayCore
import Foundation
import os

/// AppModel is CGM Relay's own coordinator: it bootstraps the app's
/// generated credentials, supervises the engine process, polls its
/// status, keeps the Settings window's own state, and exposes exactly
/// what the menu and Settings panes need to render as @Published state.
/// Everything it depends on is a CGMRelayCore protocol; the mapping,
/// supervision, polling, alert-episode, and settings-to-configuration
/// logic it wires together are each tested directly in
/// CGMRelayCoreTests, so this type carries no logic of its own worth
/// testing beyond that wiring.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var menuState: MenuDisplayState
    @Published private(set) var credentialsConfigured = false
    @Published private(set) var accountEmail: String?
    @Published private(set) var engineState: EngineSupervisor.RunState = .stopped
    @Published private(set) var settings: AppSettings
    @Published private(set) var loginItemStatus: LoginItemStatus = .disabled
    @Published private(set) var loginItemErrorMessage: String?
    /// retentionNotice carries why a retention entry was not saved when the
    /// General pane went away, for the pane to show the next time it appears.
    var retentionNotice: String?
    /// loginItemUnavailableReason is the system's own reason a registration
    /// failed, shown where Open at Login is unavailable. It lasts until the
    /// status is next read afresh, so a later visit offers Turn On again.
    @Published private(set) var loginItemUnavailableReason: String?
    @Published private(set) var notificationPermissionDenied = false
    /// menuPanelRequest counts the times the app itself asks for the menu
    /// panel to open (requestMenuPanel); the status item watches it.
    @Published private(set) var menuPanelRequest = 0
    /// tailnetAvailable, localNetworkAvailable, connectAddressAvailability
    /// and impliedBindHost are refreshed by refreshNetworkAddresses(),
    /// called whenever the menu opens or the Connect/Advanced pane
    /// appears: this Mac's network state can change at any time (Tailscale
    /// connects or disconnects, Wi-Fi changes), never only when a setting
    /// does.
    @Published private(set) var tailnetAvailable = false
    @Published private(set) var localNetworkAvailable = false
    @Published private(set) var connectAddressAvailability: ReachAddressAvailability = .available("127.0.0.1")
    /// impliedBindHost is what the current reach implies the engine is
    /// started against for this Mac's current network interfaces
    /// (EngineListenPlan.identity: the listen host, and on the local
    /// network route the private addresses and name too). Published beside
    /// connectAddressAvailability, rather than recomputed by
    /// connectPaneAddressState, so the Connect pane
    /// compares boundHost against the exact same answer that decides
    /// whether the engine needs restarting at all.
    @Published private(set) var impliedBindHost = "127.0.0.1"
    /// privateIPv4Addresses is every private IPv4 address this Mac has on a
    /// Wi-Fi or wired interface right now, the ones the local network route
    /// listens on and names in its certificate; primaryPrivateIPv4 is the
    /// one on the default route. localHostName is this Mac's `.local` name.
    @Published private(set) var privateIPv4Addresses: [String] = []
    @Published private(set) var primaryPrivateIPv4: String?
    @Published private(set) var localHostName = LocalHostName.fallback
    /// isCertificateStepPresented is true while the person is giving a phone
    /// the certificate; the Connect pane that asked shows the stepper while
    /// it is.
    @Published private(set) var isCertificateStepPresented = false
    /// certificateNotice is the sentence the menu shows after the
    /// certificate was made again, until the step is finished.
    @Published private(set) var certificateNotice: String?
    /// lanReadingClients mirrors the latest status's report of the apps that
    /// fetched readings over the encrypted local network address, published
    /// so a view watching for the first such fetch redraws when one lands.
    @Published private(set) var lanReadingClients: [String: Date] = [:]
    /// boundHost is the EngineListenPlan.identity the running engine was
    /// actually started against -- nil whenever nothing is currently running -- so the
    /// Connect pane can show the address the engine is really listening
    /// on rather than a freshly recomputed guess that could differ from
    /// it until the next restart.
    @Published private(set) var boundHost: String?
    /// tailscaleStatus and tailscaleServe are what Tailscale itself says
    /// right now (its state, and what it is serving), read together by
    /// refreshTailscale() wherever the person can act on them. Whether
    /// HTTPS is on is decided from these alone (httpsState), never from the
    /// saved choice.
    @Published private(set) var tailscaleStatus: TailscaleStatus = .unknown
    @Published private(set) var tailscaleServe: TailscaleServeConfig?
    @Published private(set) var isChangingTailscale = false
    @Published private(set) var tailscaleFailure: TailscaleFailure?
    /// setupPresentationRequest counts the times the app itself asks for
    /// first-launch setup to open: once, after launch finds setup
    /// incomplete. The scene that owns the window watches it.
    @Published private(set) var setupPresentationRequest = 0
    private var launchChecked = false
    /// setupPortNotice is the sentence setup shows when no port in the
    /// search range was free, with a way to open Advanced; nil otherwise.
    @Published private(set) var setupPortNotice: String?
    /// portIsPersonChosen is whether the port is one the person typed (or
    /// that finished setup saved), so it is never changed for them unless it
    /// is the relay's own status port, where the engine can never listen. Until
    /// then, each engine start during setup looks for a free port again,
    /// starting from the default only when the saved port is taken, on the
    /// addresses the chosen reach binds.
    private var portIsPersonChosen: Bool
    /// portChangeMenuNotice is whether the menu panel still owes the person
    /// a word that follower apps on the old address stop reading. It is
    /// shown while the panel is open and ends when the panel closes.
    @Published private(set) var portChangeMenuNotice = false

    /// TailscaleFailure is the plain sentence for a Tailscale change that
    /// did not work, with Tailscale's own page where one helps.
    struct TailscaleFailure: Equatable {
        let message: String
        let helpURL: URL?
    }

    private let credentialStore: any CredentialStore
    private let settingsStore: any SettingsStoring
    private let supervisor: EngineSupervisor
    private let statusPoller: StatusPoller
    private let accountSignIn: AccountSignIn
    private let alertEngine: AlertEngine
    private let notificationDelivering: any NotificationDelivering
    private let loginItemManager: any LoginItemManaging
    private let statusAddr: String
    private let pairingMinter: any PairingCodeMinting
    private let databasePath: String
    private let librelinkupBaseURL: String?
    private let tailscale: any TailscaleControlling
    private let portBinder: any PortBinding
    private let certificateAuthority: LocalCertificateAuthority
    /// certificateServer is the one live certificate download link's server,
    /// with the address and certificate it was made for.
    private var certificateServer: (server: CertificateDownloadServer, address: String, certificate: Data)?
    /// certificateLinkEpoch counts the times a certificate link was ended on
    /// purpose (the step closed or finished, or the app quitting), so a link
    /// still being made can tell it was asked for before one of those.
    private var certificateLinkEpoch = 0

    private var latestStatus: EngineStatus?

    /// recoveryLogger carries this file's own recovery diagnostics -- only
    /// ever a failure to move the old database aside, which is rare (a
    /// permissions problem) and never carries a secret. Not DEBUG-only:
    /// "Start Fresh…" is a real recovery path for every person running
    /// this app, not a development tool.
    private let recoveryLogger = Logger(subsystem: "com.yaanfpv.cgmrelay", category: "recovery")
    /// notificationLogger and loginItemLogger carry the permission the
    /// system reported and a refused login item change, never a secret.
    private let notificationLogger = Logger(subsystem: "com.yaanfpv.cgmrelay", category: "notifications")
    private let loginItemLogger = Logger(subsystem: "com.yaanfpv.cgmrelay", category: "login-item")

    /// needsSetup is true until the person has both a signed-in account and
    /// has finished the last setup step. It is false before launch has read
    /// the Keychain, so nothing flashes before the real answer is known.
    var needsSetup: Bool {
        launchChecked && !(settings.setupFinished && credentialsConfigured)
    }

    /// needsSafetyNotice is true until the current wording of the safety
    /// notice has been accepted; like needsSetup it waits for launch to have
    /// read the saved settings.
    var needsSafetyNotice: Bool {
        launchChecked && SafetyNotice.needsAcceptance(settings.safetyNoticeAcceptance)
    }

    /// httpsState is where Tailscale HTTPS stands for the relay's current
    /// port, from Tailscale's own report.
    var httpsState: TailscaleHTTPSState {
        TailscaleHTTPSState.evaluate(status: tailscaleStatus, config: tailscaleServe, relayPort: settings.port)
    }

    /// httpsLocked is whether the port and the reach choices must not change:
    /// while this app's handler is serving, and while the saved choice says
    /// HTTPS is on but Tailscale cannot be asked, since changing the port
    /// then would strand the handler already set up.
    var httpsLocked: Bool {
        switch httpsState {
        case .on:
            return true
        case .off, .noFreePort:
            return false
        case .unknown, .unavailable, .unreadable:
            return settings.tailscaleHTTPSEnabled
        }
    }

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
        case .failed(.configurationUnreadable), .failed(.storeInUse), .failed(.portInUse), .failed(.httpsOnStatusPort), .stopped, .starting, .running, .waitingToRestart:
            return false
        }
    }

    /// canTryAgain is true for the permanent failures a plain re-run can
    /// actually fix, since nothing was ever written to disk that a
    /// move-aside would need to recover first: configurationUnreadable,
    /// storeInUse and portInUse, since the other copy or app holding the
    /// lock or port may quit at any time, and this is what makes that quit
    /// take effect the moment the menu is next opened rather than needing a
    /// manual click; and httpsOnStatusPort, which a retry clears once
    /// Tailscale HTTPS is off.
    var canTryAgain: Bool {
        switch engineState {
        case .failed(.configurationUnreadable), .failed(.storeInUse), .failed(.portInUse), .failed(.httpsOnStatusPort):
            return true
        case .failed(.storeKeyMismatch), .failed(.storeDamaged), .failed(.recoveryMoveFailed), .stopped, .starting, .running, .waitingToRestart:
            return false
        }
    }

    init(
        engineURL: URL,
        credentialStore: any CredentialStore = KeychainCredentialStore(),
        settingsStore: any SettingsStoring = UserDefaultsSettingsStore(),
        statusAddr: String = RelayDefaults.statusAddr,
        databasePath: String,
        librelinkupBaseURL: String? = nil,
        tailscale: any TailscaleControlling = RealTailscaleController(executableURL: nil),
        loginItemManager: any LoginItemManaging = SystemLoginItemManager(),
        portBinder: any PortBinding = SystemPortBinder()
    ) {
        self.tailscale = tailscale
        self.portBinder = portBinder
        self.credentialStore = credentialStore
        certificateAuthority = LocalCertificateAuthority(store: credentialStore)
        self.settingsStore = settingsStore
        // notificationDelivering has no throwaway Debug counterpart the
        // way credentialStore and settingsStore do (notification permission
        // is never scoped per Keychain service), so, exactly like
        // supervisor's own RealProcessLauncher below, it is never exposed
        // as an init parameter at all. The login item is: a Debug build
        // must not register one for real, so the app decides which
        // manager a launch gets (LoginItemFakeLocator).
        notificationDelivering = UserNotificationCenterDelivering()
        self.loginItemManager = loginItemManager
        self.statusAddr = statusAddr
        let statusSecret = LocalStatusSecret()
        pairingMinter = URLSessionPairingCodeMinter(pairingURL: AppModel.pairingURL(for: statusAddr), secret: statusSecret)
        self.databasePath = databasePath
        self.librelinkupBaseURL = librelinkupBaseURL
        let loaded = settingsStore.load()
        settings = loaded
        portIsPersonChosen = loaded.setupFinished || loaded.port != AppSettings.defaultPort
        accountSignIn = AccountSignIn(checker: RealAccountChecker(engineURL: engineURL), store: credentialStore)
        alertEngine = AlertEngine()
        menuState = .make(credentialsConfigured: false, engineState: .stopped, status: nil, now: Date())

        // A weak box, rather than capturing self, because Swift forbids
        // referring to self in a class's own init before every stored
        // property has a value -- and the closures below are themselves
        // stored properties (via supervisor/statusPoller) that must be
        // built before that point.
        let ref = AppModelRef()
        supervisor = EngineSupervisor(engineURL: engineURL, launcher: RealProcessLauncher(), statusSecret: statusSecret) { state in
            Task { @MainActor in ref.value?.handleEngineStateChange(state) }
        }
        statusPoller = StatusPoller(
            fetcher: URLSessionStatusFetcher(statusURL: AppModel.statusURL(for: statusAddr), secret: statusSecret)
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
    /// store key on a first launch, ask for setup to open when it is
    /// incomplete, start the engine if a LibreLinkUp account is already on
    /// file, and begin polling its status. Starting the engine and starting
    /// the status poller run concurrently rather than one after the other,
    /// so a slow first Keychain read never delays the status display
    /// coming up.
    func onLaunch() async {
        try? CredentialsBootstrapper(store: credentialStore).ensureBootstrapped()
        refreshCredentialsConfigured()
        launchChecked = true
        if needsSetup || needsSafetyNotice {
            setupPresentationRequest += 1
        }
        await alertEngine.setNoReadingAlert(enabled: settings.noReadingAlertEnabled, minutes: settings.noReadingAlertMinutes)
        await alertEngine.setSignInFailingAlert(enabled: settings.signInFailingAlertEnabled)
        async let engineStarted: Void = canStart ? startEngine() : ()
        async let pollerStarted: Void = statusPoller.start()
        async let tailscaleRead: Void = settings.tailscaleHTTPSEnabled ? refreshTailscale() : ()
        _ = await (engineStarted, pollerStarted, tailscaleRead)
    }

    /// onMenuOpened refreshes the status immediately, so opening the menu
    /// never shows a reading that is stale only because the slow timer
    /// has not fired since it changed. It also retries every failure
    /// canTryAgain names on its own, so a Keychain that was only briefly
    /// unavailable, another copy that has since quit, or Tailscale HTTPS
    /// since turned off recovers the moment the menu is opened, with no
    /// click needed.
    func onMenuOpened() {
        refreshCredentialsConfigured()
        refreshNetworkAddresses()
        if settings.tailscaleHTTPSEnabled {
            Task { await refreshTailscale() }
        }
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
        Task {
            await supervisor.stop()
            boundHost = nil
            await alertEngine.pauseForEngineStop()
        }
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

    /// tryAgain re-runs the ordinary launch sequence for a failure
    /// canTryAgain names: clear the failure,
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

    /// quit ends the app, like every quit asked for inside it; the delegate
    /// runs shutDown before the process goes.
    func quit() {
        NSApplication.shared.terminate(nil)
    }

    /// shutDown stops the status poller and the engine and waits, briefly,
    /// for the engine process to be gone, so a relaunch never meets a store
    /// the old engine still holds.
    func shutDown() async {
        certificateLinkEpoch += 1
        await endCertificateLink()
        await statusPoller.stop()
        await supervisor.stopAndWait(timeout: .seconds(3))
        boundHost = nil
    }

    // MARK: - Account

    /// signIn checks email and password against LibreLinkUp before saving
    /// anything (AccountSignIn's own contract). On AccountCheckOutcome.signedIn
    /// it also starts the engine, since credentialsConfigured has just
    /// become true for the first time (or after a sign-out); on every
    /// other outcome nothing about the engine changes at all.
    func signIn(email: String, password: String) async -> AccountCheckOutcome {
        let outcome = await accountSignIn.signIn(email: email, password: password, librelinkupBaseURL: librelinkupBaseURL)
        if outcome == .signedIn {
            refreshCredentialsConfigured()
            if canStart {
                await startEngine()
            }
        }
        return outcome
    }

    /// signOut stops the engine and removes exactly the LibreLinkUp email
    /// and password (AccountSignIn's own contract keeps the token and
    /// store key). Returns whether the removal actually succeeded, so the
    /// Account pane can tell the person when it did not, rather than
    /// quietly leaving the old account in place while acting as if it
    /// were gone.
    @discardableResult
    func signOut() async -> Bool {
        await supervisor.stop()
        boundHost = nil
        await alertEngine.pauseForEngineStop()
        let succeeded: Bool
        do {
            try accountSignIn.signOut()
            succeeded = true
        } catch {
            succeeded = false
        }
        refreshCredentialsConfigured()
        return succeeded
    }

    // MARK: - Connect

    /// rotateToken generates and saves a fresh bearer token and restarts
    /// the engine with it, so every follower app presenting the old one
    /// is refused from the moment the engine comes back up. Returns the
    /// new token so the Connect pane can show it immediately, with no
    /// extra Keychain read.
    func rotateToken() async -> String? {
        guard let newToken = try? CredentialsBootstrapper(store: credentialStore).rotateToken() else {
            return nil
        }
        await restartEngineIfRunning()
        return newToken
    }

    /// updateConnectFollowerApp remembers which follower app the Connect
    /// pane last showed.
    func updateConnectFollowerApp(_ app: FollowerApp) {
        guard settings.connectFollowerApp != app else { return }
        settings.connectFollowerApp = app
        persistSettings()
    }

    /// mintPairingCode asks the running engine for a pairing code whose page
    /// carries the instructions for the address a phone reaches this Mac at;
    /// nil while the engine is not answering. A new code replaces the last.
    /// While the local network route still needs the certificate step, no
    /// page is made, since it would carry the token to a phone that cannot
    /// yet reach this Mac over https.
    func mintPairingCode(address: String) async -> PairingCode? {
        guard !settings.needsCertificateStep else { return nil }
        let route = localRoute
        return try? await pairingMinter.mint(apps: FollowerAppEntry.pairingApps { route?.address(for: $0) ?? address })
    }

    /// currentToken reads the follower-facing bearer token for the
    /// Connect pane to display; nil only if bootstrapping has somehow not
    /// run yet, or while the local network route still needs the
    /// certificate step.
    func currentToken() -> String? {
        guard !settings.needsCertificateStep else { return nil }
        return try? credentialStore.string(for: .token)
    }

    /// localRoute is how a follower app is given this Mac on the local
    /// network route, nil on every other route and while this Mac has no
    /// private address.
    var localRoute: LocalFollowerRoute? {
        guard settings.effectiveReach == .myLocalNetwork, let ipv4 = primaryPrivateIPv4 else { return nil }
        return LocalFollowerRoute(hostName: localHostName, ipv4: ipv4, port: settings.port)
    }

    /// followerAddress is the address app is given: readyAddress, or on the
    /// local network route the form that app takes.
    func followerAddress(for app: FollowerApp, readyAddress: String) -> String {
        localRoute?.address(for: app) ?? readyAddress
    }

    /// lanReadingFetch is the newest fetch of readings over the encrypted
    /// local network address at or after since, nil when there was none.
    func lanReadingFetch(since: Date) -> (userAgent: String, at: Date)? {
        latestStatus?.lanReadingFetch(since: since)
    }

    /// refreshNetworkAddresses re-reads this Mac's own network
    /// interfaces: called when the menu opens and from the Connect and
    /// Advanced panes' onAppear, since Tailscale connecting or a network
    /// change can happen at any time, never only when a setting does.
    /// When what the chosen reach implies (its address, or on the local
    /// network route the set of private addresses and this Mac's name) has
    /// since changed from whatever the engine is actually started against,
    /// it restarts the engine once onto the new one, which makes the
    /// certificate again, rather than leaving the Connect pane showing an
    /// address nothing is listening on.
    func refreshNetworkAddresses() {
        let interfaces = SystemNetworkInterfaces.currentIPv4Addresses()
        let primaryInterfaceName = SystemNetworkInterfaces.primaryInterfaceName()

        let hostName = SystemNetworkInterfaces.localHostName()

        tailnetAvailable = ReachAddressResolver.tailscaleIPv4(among: interfaces) != nil
        privateIPv4Addresses = ReachAddressResolver.privateLANIPv4s(among: interfaces)
        primaryPrivateIPv4 = ReachAddressResolver.primaryPrivateLANIPv4(among: interfaces, primaryInterfaceName: primaryInterfaceName)
        localHostName = hostName
        localNetworkAvailable = primaryPrivateIPv4 != nil
        connectAddressAvailability = ReachAddressResolver.displayHostAvailability(for: settings.effectiveReach, interfaces: interfaces, primaryInterfaceName: primaryInterfaceName)
        impliedBindHost = EngineListenPlan.make(reach: settings.effectiveReach, interfaces: interfaces, hostName: hostName).identity

        if BoundAddressDecision.decide(currentBoundHost: boundHost, impliedBindHost: impliedBindHost) == .restartNeeded {
            Task { await restartEngineIfRunning() }
        }
    }

    /// connectPaneAddressState is what the Connect pane shows and encodes
    /// into its QR code, decided by ConnectPaneAddressState.decide from
    /// the chosen reach (or, for a person who chose Tailscale HTTPS, the
    /// https address Tailscale itself reports serving), the address the
    /// running engine is actually bound
    /// to (boundHost), the address the current reach implies right now
    /// (impliedBindHost), the settings port, and the current display-host
    /// availability. No address logic lives here.
    var connectPaneAddressState: ConnectPaneAddressState {
        if settings.tailscaleHTTPSEnabled || httpsState.isOn {
            return ConnectPaneAddressState.decideTailscaleHTTPS(boundHost: boundHost, tailscale: tailscaleStatus, https: httpsState)
        }
        return ConnectPaneAddressState.decide(
            reach: settings.reach,
            boundHost: boundHost,
            impliedBindHost: impliedBindHost,
            port: settings.port,
            displayHostAvailability: connectAddressAvailability,
            localHostName: localHostName,
            certificateStepFinished: settings.localCertificateStepFinished
        )
    }

    /// phoneReachability is whether a phone can be given an address for this
    /// Mac by the choices made now: setup's reach step continues only when
    /// it is reachable, and the connect step is shown only then.
    var phoneReachability: PhoneReachability {
        PhoneReachability.decide(
            reach: settings.reach,
            httpsChosen: settings.tailscaleHTTPSEnabled,
            httpsServing: httpsState.isOn,
            tailnetAvailable: tailnetAvailable,
            localNetworkAvailable: localNetworkAvailable
        )
    }

    // MARK: - Settings

    func updatePort(_ port: Int) {
        // Tailscale serves to the port it was set up with, so the port is
        // fixed while HTTPS is on.
        guard !httpsLocked else { return }
        let previous = settings.port
        settings.port = port.clamped(to: AppSettings.portRange)
        if settings.port != previous { portChangeMenuNotice = true }
        portIsPersonChosen = true
        setupPortNotice = nil
        persistSettings()
        Task {
            // A relay that could not listen on the old port starts on the
            // new one at once; a running one restarts onto it.
            if engineState == .failed(.portInUse) {
                await supervisor.clearFailure()
                await startEngine()
            } else {
                await restartEngineIfRunning()
            }
        }
    }

    /// portChangeNoticeShown ends the menu panel's word about the new
    /// address; it is called as the panel closes.
    func portChangeNoticeShown() {
        portChangeMenuNotice = false
    }

    /// typedPortInUseMessage is the refusal for a typed port another app
    /// already holds on the addresses the chosen reach binds, or the one the
    /// relay's own status listener uses, nil when it is free. A typed port is
    /// never moved to another.
    func typedPortInUseMessage(_ port: Int) -> String? {
        let interfaces = SystemNetworkInterfaces.currentIPv4Addresses()
        let bindHost = ReachAddressResolver.portCheckHost(for: settings.effectiveReach, interfaces: interfaces)
        return PortAvailability.typedPortRefusal(port: port, bindHost: bindHost, binder: portBinder, reserved: PortAvailability.port(inAddress: statusAddr), localIPv4s: interfaces.map(\.address))
    }

    func updateReach(_ reach: NetworkReach) {
        guard !httpsLocked else { return }
        // Choosing a reach is choosing not to use Tailscale HTTPS.
        settings.tailscaleHTTPSEnabled = false
        settings.reach = reach
        persistSettings()
        recomputeMenuState()
        // refreshNetworkAddresses() is the one and only restart trigger
        // here: with the new reach already in settings, it detects the
        // implied bind host has changed from whatever is currently
        // running and restarts once onto it -- a second explicit restart
        // call here would double up and restart twice for one commit.
        refreshNetworkAddresses()
    }

    func updateRetentionDays(_ days: Int) {
        settings.retentionDays = days.clamped(to: AppSettings.retentionDaysRange)
        persistSettings()
        Task { await restartEngineIfRunning() }
    }

    func updateUnits(_ units: GlucoseUnit) {
        settings.units = units
        persistSettings()
        recomputeMenuState()
    }

    // MARK: - Certificate step

    /// CertificateLinkError is why a certificate link could not be made.
    enum CertificateLinkError: Error {
        /// This Mac has no private network address a phone could fetch it from.
        case noNetworkAddress
    }

    /// beginCertificateStep asks for the certificate stepper to be shown.
    func beginCertificateStep() {
        isCertificateStepPresented = true
    }

    /// finishCertificateStep records the person's word that their phone has
    /// the certificate, so the local network route shows its address, token
    /// and code, and ends the download link. The stepper stays open, so the
    /// person can set up their app and watch it connect.
    func finishCertificateStep() {
        certificateLinkEpoch += 1
        settings.localCertificateStepFinished = true
        persistSettings()
        certificateNotice = nil
        recomputeMenuState()
        Task { await endCertificateLink() }
    }

    /// closeCertificateStep closes the stepper, finished or not, and ends the
    /// download link.
    func closeCertificateStep() {
        certificateLinkEpoch += 1
        isCertificateStepPresented = false
        Task { await endCertificateLink() }
    }

    /// mintCertificateLink makes the one link a phone opens to get CGM
    /// Relay's certificate, served from this Mac's primary private address.
    /// A newer link ends the previous one; the link works once, for a
    /// couple of minutes. A link still being made when the step is closed,
    /// or the app quits, is ended and the call throws CancellationError. A
    /// cancelled caller does not end the link, since the phone may still be
    /// downloading it.
    func mintCertificateLink(format: CertificateDownloadFormat) async throws -> URL {
        let epoch = certificateLinkEpoch
        func stillWanted() -> Bool { isCertificateStepPresented && certificateLinkEpoch == epoch }
        let interfaces = SystemNetworkInterfaces.currentIPv4Addresses()
        let primaryInterfaceName = SystemNetworkInterfaces.primaryInterfaceName()
        guard let address = ReachAddressResolver.primaryPrivateLANIPv4(among: interfaces, primaryInterfaceName: primaryInterfaceName) else {
            throw CertificateLinkError.noNetworkAddress
        }
        let material = try certificateAuthority.currentMaterial(
            name: SystemNetworkInterfaces.localHostName(),
            ipv4s: ReachAddressResolver.privateLANIPv4s(among: interfaces)
        )
        if material.authorityChange != .unchanged {
            applyAuthorityChange(material.authorityChange)
            await restartEngineIfRunning()
            guard stillWanted() else { throw CancellationError() }
        }

        let server: CertificateDownloadServer
        if let live = certificateServer, live.address == address, live.certificate == material.authorityCertificateDER {
            server = live.server
        } else {
            await endCertificateLink()
            guard stillWanted() else { throw CancellationError() }
            server = try CertificateDownloadServer(authorityCertificateDER: material.authorityCertificateDER, address: address)
            certificateServer = (server, address, material.authorityCertificateDER)
        }
        let url: URL
        do {
            url = try await server.mint(format: format)
        } catch {
            if !stillWanted() { await endCertificateLink(ifServing: server) }
            throw error
        }
        guard stillWanted() else {
            await endCertificateLink(ifServing: server)
            throw CancellationError()
        }
        return url
    }

    /// endCertificateLink(ifServing:) ends the link only while `server` is
    /// still the one being served, so a newer link is left alone.
    private func endCertificateLink(ifServing server: CertificateDownloadServer) async {
        guard let live = certificateServer, live.server === server else { return }
        await endCertificateLink()
    }

    /// endCertificateLink stops serving the certificate; called when the step
    /// finishes or is cancelled and when the app quits.
    func endCertificateLink() async {
        guard let live = certificateServer else { return }
        certificateServer = nil
        await live.server.close()
    }

    // MARK: - Tailscale HTTPS and setup

    /// refreshTailscale reads this Mac's Tailscale state and, while it
    /// runs, what it is serving. Both reads are read-only and are the only
    /// Tailscale calls that run without a click. When Tailscale shows the
    /// app's handler serving, the saved choice follows it, so the relay is
    /// bound to this Mac only.
    func refreshTailscale() async {
        let status = await tailscale.status()
        var serve: TailscaleServeConfig?
        if case .running = status {
            serve = await tailscale.serveConfig()
        }
        tailscaleStatus = status
        tailscaleServe = serve
        if httpsState.isOn, !settings.tailscaleHTTPSEnabled {
            settings.tailscaleHTTPSEnabled = true
            persistSettings()
            refreshNetworkAddresses()
        }
        // A start refused while Tailscale's state was unknown can go ahead
        // once Tailscale shows nothing holds the port.
        if engineState == .failed(.httpsOnStatusPort), !httpsLocked {
            tryAgain()
        }
    }

    /// enableTailscaleHTTPS runs the one serve command the button shows, on
    /// the port it showed, only if Tailscale's settings read immediately
    /// before still show that port free. The check afterwards asks only
    /// whether this Mac's own entry is now serving. A transient failure is
    /// retried quietly (TailscaleChange), each attempt starting from a fresh
    /// read, and the spinner stays up until the last attempt has ended.
    func enableTailscaleHTTPS(shownPort: Int) async {
        guard !isChangingTailscale else { return }
        isChangingTailscale = true
        tailscaleFailure = nil
        defer { isChangingTailscale = false }

        let result = await TailscaleChange.turnOn(
            shownPort: shownPort,
            relayPort: settings.port,
            controller: tailscale,
            read: { [self] in await readHTTPSState() },
            wait: { try? await Task.sleep(for: $0) }
        )
        switch result {
        case .done:
            settings.tailscaleHTTPSEnabled = true
            persistSettings()
            refreshNetworkAddresses()
        case .unchanged:
            break
        case .refused:
            reportFailure(.settingsChanged, turningOn: true)
        case .failed(let outcome):
            reportFailure(outcome, turningOn: true)
        }
    }

    /// disableTailscaleHTTPS runs the one matching off command only if
    /// Tailscale's settings read immediately before show this Mac's own
    /// entry on the port shown. The check afterwards asks only whether that
    /// entry is gone, with the same quiet retries as turning on.
    func disableTailscaleHTTPS(shownPort: Int) async {
        guard !isChangingTailscale else { return }
        isChangingTailscale = true
        tailscaleFailure = nil
        defer { isChangingTailscale = false }

        let result = await TailscaleChange.turnOff(
            shownPort: shownPort,
            controller: tailscale,
            read: { [self] in await readHTTPSState() },
            wait: { try? await Task.sleep(for: $0) }
        )
        switch result {
        case .done:
            settings.tailscaleHTTPSEnabled = false
            persistSettings()
            refreshNetworkAddresses()
            // A start refused for Tailscale HTTPS on the status port can move
            // now that nothing holds the port.
            if engineState == .failed(.httpsOnStatusPort) {
                tryAgain()
            }
        case .unchanged:
            break
        case .refused:
            reportFailure(.settingsChanged, turningOn: false)
        case .failed(let outcome):
            reportFailure(outcome, turningOn: false)
        }
    }

    private func readHTTPSState() async -> TailscaleHTTPSState {
        await refreshTailscale()
        return httpsState
    }

    /// clearTailscaleFailure drops a failure sentence once the control that
    /// showed it is looked at again.
    func clearTailscaleFailure() {
        tailscaleFailure = nil
    }

    private func reportFailure(_ outcome: TailscaleServeOutcome, turningOn: Bool) {
        guard let message = outcome.message(turningOn: turningOn) else { return }
        tailscaleFailure = TailscaleFailure(message: message, helpURL: outcome.helpURL)
    }

    /// acceptSafetyNotice records that the person accepted the notice as
    /// worded now.
    func acceptSafetyNotice() {
        settings.safetyNoticeAcceptance = SafetyNotice.acceptance(appVersion: AppVersion.short)
        persistSettings()
    }

    /// completeSetup is setup's Done. It marks setup finished only while a
    /// phone can reach this Mac; otherwise setup stays open for next time.
    func completeSetup() {
        guard SetupCompletion.mayFinish(reachability: phoneReachability) else { return }
        settings.setupFinished = true
        persistSettings()
    }

    /// setNoReadingAlert asks for notification permission the first time
    /// the person turns this alert on, never proactively. A refusal is
    /// recorded (notificationPermissionDenied) rather than silently
    /// leaving the alert enabled with no way to ever notify anyone.
    func setNoReadingAlert(enabled: Bool, minutes: Int) async {
        let clampedMinutes = minutes.clamped(to: AppSettings.noReadingAlertMinutesRange)
        if enabled, !settings.noReadingAlertEnabled {
            guard await ensureNotificationPermission() else {
                settings.noReadingAlertMinutes = clampedMinutes
                persistSettings()
                return
            }
        }
        settings.noReadingAlertEnabled = enabled
        settings.noReadingAlertMinutes = clampedMinutes
        persistSettings()
        await alertEngine.setNoReadingAlert(enabled: enabled, minutes: clampedMinutes)
    }

    func setSignInFailingAlert(enabled: Bool) async {
        if enabled, !settings.signInFailingAlertEnabled {
            guard await ensureNotificationPermission() else { return }
        }
        settings.signInFailingAlertEnabled = enabled
        persistSettings()
        await alertEngine.setSignInFailingAlert(enabled: enabled)
    }

    /// ensureNotificationPermission reads what the system says now, asks
    /// only while nobody has been asked, and reads again. The denied notice
    /// follows the system's answer alone, so it never shows for a permission
    /// that was simply not asked for yet.
    private func ensureNotificationPermission() async -> Bool {
        var authorization = await notificationDelivering.authorization()
        notificationLogger.info("notification permission before asking: \(String(describing: authorization), privacy: .public)")
        if authorization == .notDetermined {
            _ = await notificationDelivering.requestAuthorization()
            authorization = await notificationDelivering.authorization()
            notificationLogger.info("notification permission after asking: \(String(describing: authorization), privacy: .public)")
        }
        notificationPermissionDenied = authorization == .denied
        return authorization == .allowed
    }

    /// refreshNotificationPermission drops the denied notice once the
    /// person has allowed notifications in System Settings: called when the
    /// Alerts pane appears and when the app becomes active again.
    func refreshNotificationPermission() {
        guard notificationPermissionDenied else { return }
        Task {
            if await notificationDelivering.authorization() != .denied {
                notificationPermissionDenied = false
            }
        }
    }

    private static var notificationSettingsURL: URL {
        let base = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        let identifier = Bundle.main.bundleIdentifier ?? ""
        return URL(string: identifier.isEmpty ? base : "\(base)?id=\(identifier)") ?? URL(fileURLWithPath: "/System/Applications/System Settings.app")
    }

    /// openNotificationSettings opens System Settings on CGM Relay's own
    /// entry in Notifications.
    func openNotificationSettings() {
        NSWorkspace.shared.open(Self.notificationSettingsURL)
    }

    /// openLoginItemsSettings opens System Settings' Login Items list, where
    /// a login item waiting for approval is approved.
    func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    /// refreshLoginItemStatus re-reads the login item's status, with no side
    /// effect: called when a pane or setup step that shows it appears, since
    /// the system's login items have no change notification of their own and
    /// the person may have approved or removed the item in System Settings
    /// since it was last shown.
    func refreshLoginItemStatus() {
        loginItemUnavailableReason = nil
        loginItemStatus = loginItemManager.status
    }

    /// setOpenAtLogin registers or unregisters CGM Relay as a login item,
    /// then re-reads the real status rather than assuming the call
    /// succeeded outright: register() can succeed while the result is
    /// .requiresApproval, which the General pane shows as its own state.
    /// A refused registration makes Open at Login unavailable, with the
    /// system's reason; a refused removal keeps the control and says so.
    func setOpenAtLogin(_ enabled: Bool) {
        loginItemErrorMessage = nil
        do {
            if enabled {
                try loginItemManager.register()
            } else {
                try loginItemManager.unregister()
            }
        } catch {
            loginItemLogger.error("could not change the login item registration: \(error, privacy: .public)")
            if enabled {
                loginItemUnavailableReason = LoginItemFailure.reason(for: error)
                loginItemStatus = .notFound
                return
            }
            loginItemErrorMessage = "Couldn't turn off Open at Login. Try again."
        }
        loginItemUnavailableReason = nil
        loginItemStatus = loginItemManager.status
    }

    // MARK: - Menu bar

    /// requestMenuPanel asks the status item to open the menu panel, the
    /// same panel a click on it opens.
    func requestMenuPanel() {
        menuPanelRequest += 1
    }

    /// menuBarItemState is what the menu bar item shows right now, with a
    /// mark for an update that is waiting.
    func menuBarItemState(update: PendingUpdate) -> MenuBarItemState {
        MenuBarItemState.make(menu: menuState, needsSetup: needsSetup, showReading: settings.showReadingInMenuBar, update: update)
    }

    func updateShowReadingInMenuBar(_ show: Bool) {
        settings.showReadingInMenuBar = show
        persistSettings()
    }

    // MARK: - Diagnostics

    /// diagnosticsText is the About pane's Copy Diagnostics payload.
    /// DiagnosticsReport.build's own signature guarantees it: no email,
    /// token, store key, bind address, or glucose value can reach it,
    /// whatever this app passes.
    func diagnosticsText(appVersion: String, buildNumber: String, macOSVersion: String) -> String {
        let now = Date()
        let followerAges: [(client: String, age: String)] = (latestStatus?.clients ?? [:])
            .map { (client: $0.key, age: MenuDisplayState.relativeAgeText(from: $0.value, to: now)) }
            .sorted { $0.client < $1.client }

        return DiagnosticsReport.build(
            appVersion: appVersion,
            buildNumber: buildNumber,
            macOSVersion: macOSVersion,
            engineState: engineState,
            lastError: latestStatus?.lastError,
            reach: settings.effectiveReach,
            port: settings.port,
            retentionDays: settings.retentionDays,
            units: settings.units,
            noReadingAlertEnabled: settings.noReadingAlertEnabled,
            noReadingAlertMinutes: settings.noReadingAlertMinutes,
            signInFailingAlertEnabled: settings.signInFailingAlertEnabled,
            followerAges: followerAges
        )
    }

    // MARK: - Private

    private func persistSettings() {
        settingsStore.save(settings)
    }

    /// restartEngineIfRunning stops and restarts the engine only while it
    /// is actually starting, running, or waiting to restart: a settings
    /// change never starts an engine a person explicitly stopped, and
    /// never disturbs a permanent failure, which stays exactly as
    /// reported until Try Again or Start Fresh.
    private func restartEngineIfRunning() async {
        switch engineState {
        case .starting, .running, .waitingToRestart:
            // Wait for the old process to be gone, so its own listener never
            // reads as another app holding the port when the new start checks.
            await supervisor.stopAndWait(timeout: .seconds(3))
            await startEngine()
        case .stopped, .failed:
            return
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
            boundHost = nil
            await supervisor.fail(.recoveryMoveFailed)
            return
        }
        let interfaces = SystemNetworkInterfaces.currentIPv4Addresses()
        if let refusal = choosePortBeforeStart(interfaces: interfaces) {
            boundHost = nil
            await supervisor.fail(refusal)
            return
        }
        guard
            let start = try? SettingsEngineConfigurationBuilder.start(
                settings: settings,
                from: credentialStore,
                interfaces: interfaces,
                statusAddr: statusAddr,
                databasePath: databasePath,
                librelinkupBaseURL: librelinkupBaseURL,
                hostName: SystemNetworkInterfaces.localHostName()
            )
        else {
            boundHost = nil
            await supervisor.fail(.configurationUnreadable)
            return
        }
        boundHost = start.plan.identity
        if let change = start.authorityChange {
            applyAuthorityChange(change)
        }
        await alertEngine.resumeAfterEngineStart()
        await supervisor.start(configuration: start.configuration)
    }

    /// choosePortBeforeStart settles the follower port before the engine
    /// starts (PortAvailability.startPort decides): during setup the saved
    /// port stays while it is still free, so an address already given to a
    /// phone keeps working, and only a taken one is replaced by the first
    /// free port from the default up, which is then saved. A saved port equal
    /// to the relay's own status port is replaced the same way at any time,
    /// since the engine can never listen there, except while Tailscale HTTPS
    /// holds it, which refuses the start instead. It returns the failure to
    /// report, nil to start: portInUse with the notice setup shows when every
    /// candidate is taken. A check reserves nothing, so an engine that still
    /// cannot listen is reported by its exit code.
    private func choosePortBeforeStart(interfaces: [NetworkInterfaceAddress]) -> EngineSupervisor.FailureReason? {
        let bindHost = ReachAddressResolver.portCheckHost(for: settings.effectiveReach, interfaces: interfaces)
        let decision = PortAvailability.startPort(
            current: settings.port,
            default: AppSettings.defaultPort,
            searching: !settings.setupFinished && !portIsPersonChosen,
            locked: httpsLocked,
            bindHost: bindHost,
            binder: portBinder,
            reserved: PortAvailability.port(inAddress: statusAddr),
            localIPv4s: interfaces.map(\.address)
        )
        switch decision {
        case .keep:
            return nil
        case .use(let port):
            setupPortNotice = nil
            if port != settings.port {
                settings.port = port
                persistSettings()
            }
            return nil
        case .exhausted(let first, let last):
            setupPortNotice = PortAvailability.exhaustedMessage(first: first, last: last)
            return .portInUse
        case .statusPortLocked:
            return .httpsOnStatusPort
        }
    }

    /// applyAuthorityChange asks for the certificate step again when the
    /// certificate authority was made anew, and keeps the menu's sentence
    /// about it until the step is finished.
    private func applyAuthorityChange(_ change: LocalCertificateMaterial.AuthorityChange) {
        let finishedBefore = settings.localCertificateStepFinished
        if let notice = settings.noteAuthorityChange(change) {
            certificateNotice = notice
        }
        if settings.localCertificateStepFinished != finishedBefore {
            persistSettings()
        }
        recomputeMenuState()
    }

    private func refreshCredentialsConfigured() {
        let email = try? credentialStore.string(for: .librelinkupEmail)
        let password = try? credentialStore.string(for: .librelinkupPassword)
        credentialsConfigured = !(email ?? "").isEmpty && !(password ?? "").isEmpty
        accountEmail = credentialsConfigured ? email : nil
        recomputeMenuState()
    }

    /// handleEngineStateChange clears boundHost whenever the engine
    /// reaches .stopped or .failed, so a permanent failure the supervisor
    /// discovers on its own after starting (a store key mismatch, a
    /// damaged file, another copy already holding the store) never leaves
    /// the Connect pane showing an address nothing is listening on; a
    /// crash-triggered restart (.waitingToRestart, then .starting) keeps
    /// it, since it restarts with the same configuration.
    private func handleEngineStateChange(_ state: EngineSupervisor.RunState) {
        switch state {
        case .stopped, .failed:
            boundHost = nil
        case .starting, .running, .waitingToRestart:
            break
        }
        engineState = state
        recomputeMenuState()
    }

    /// handleStatusUpdate keeps the last successfully fetched status on a
    /// failed fetch, rather than replacing it with nil: a poll fails for
    /// as ordinary a reason as the engine being stopped or between
    /// restarts, and none of those mean the reading it last reported is
    /// no longer real. Discarding it there would make the menu claim
    /// there has never been a reading right after it showed one. Only a
    /// fresh, successful fetch ever replaces what is shown. Every update,
    /// successful or not, is also handed to alertEngine, whose own fired
    /// alerts are delivered as real notifications.
    private func handleStatusUpdate(_ status: EngineStatus?) {
        if let status {
            latestStatus = status
            let lanClients = status.lanReadingClients ?? [:]
            if lanClients != lanReadingClients { lanReadingClients = lanClients }
        }
        recomputeMenuState()

        Task {
            let fired = await alertEngine.handleStatusUpdate(status)
            for kind in fired {
                await deliverAlert(kind)
            }
        }
    }

    private func deliverAlert(_ kind: AlertKind) async {
        switch kind {
        case .noReading:
            await notificationDelivering.deliver(
                title: "No new reading",
                body: "CGM Relay hasn't seen a new reading in a while."
            )
        case .signInFailing:
            await notificationDelivering.deliver(
                title: "Sign-in failing",
                body: "CGM Relay can't sign in to LibreLinkUp. Check your email and password in Settings."
            )
        }
    }

    /// recomputeMenuState assigns only a state that differs from the one
    /// already shown, so a poll that changes nothing the menu displays
    /// causes no SwiftUI update.
    private func recomputeMenuState() {
        let next = MenuDisplayState.make(
            credentialsConfigured: credentialsConfigured,
            engineState: engineState,
            status: latestStatus,
            now: Date(),
            units: settings.units,
            port: settings.port,
            certificateNotice: settings.needsCertificateStep ? certificateNotice : nil
        )
        if next != menuState {
            menuState = next
        }
    }

    private static func pairingURL(for statusAddr: String) -> URL {
        URL(string: "http://\(statusAddr)/pairing") ?? URL(string: "http://\(RelayDefaults.statusAddr)/pairing")!
    }

    private static func statusURL(for statusAddr: String) -> URL {
        URL(string: "http://\(statusAddr)/status") ?? URL(string: "http://\(RelayDefaults.statusAddr)/status")!
    }
}

/// AppModelRef is a plain weak box. It lets the supervisor's and
/// poller's update closures be created before `self` exists and still
/// reach it once it does, without ever holding AppModel alive on their
/// own account.
private final class AppModelRef: @unchecked Sendable {
    weak var value: AppModel?
}

private extension Int {
    /// clamped keeps a person's typed or scrolled value inside range,
    /// rather than saving something the engine or the store would
    /// refuse. Qualified as Swift.min/Swift.max: inside an extension on
    /// Int, an unqualified min/max resolves to the static properties
    /// Int.min/Int.max instead of the global functions of the same name.
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

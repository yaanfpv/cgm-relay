import AppKit
import CGMRelayCore
import SwiftUI
#if DEBUG
import os
#endif

#if DEBUG
/// devLogger carries this file's own development-only diagnostics: why a
/// DEBUG-only launch argument was refused, or a seed attempt failed.
/// Nothing here ever carries a secret; `log show`/`log stream` reach it
/// by the app's own bundle identifier. Compiled out of Release with
/// every other DEBUG-only symbol on this file, so it never sits unused
/// there.
private let devLogger = Logger(subsystem: "com.yaanfpv.cgmrelay", category: "debug-launch-arguments")
#endif

/// CGMRelayApp is the whole app: a menu bar item, with no Dock icon
/// (LSUIElement, set in Info.plist) except while Settings or setup is open.
/// It shows a window on launch only while first-launch setup is
/// incomplete.
@main
struct CGMRelayApp: App {
    @StateObject private var model: AppModel

    init() {
        let explicitKeychainServiceOverride = CGMRelayApp.explicitKeychainServiceOverride()
        let keychainServiceOverride = CGMRelayApp.validatedThrowawayKeychainService(explicitOverride: explicitKeychainServiceOverride)
        let store = CGMRelayApp.credentialStore(keychainServiceOverride: keychainServiceOverride)
        CGMRelayApp.seedSyntheticAccountIfRequested(into: store, explicitKeychainServiceOverride: explicitKeychainServiceOverride)
        _model = StateObject(
            wrappedValue: AppModel(
                engineURL: CGMRelayApp.engineURL(),
                credentialStore: store,
                settingsStore: UserDefaultsSettingsStore(suiteName: keychainServiceOverride),
                databasePath: CGMRelayApp.databasePath(keychainServiceOverride: keychainServiceOverride),
                librelinkupBaseURL: CGMRelayApp.librelinkupBaseURL(),
                tailscale: RealTailscaleController(
                    executableURL: CGMRelayApp.tailscaleExecutable(explicitKeychainServiceOverride: explicitKeychainServiceOverride)
                )
            )
        )
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            MenuBarLabel(dot: model.menuState.dot, statusDescription: model.menuState.shortStatus)
                .modifier(SetupPresenter(model: model))
        }
        .menuBarExtraStyle(.window)

        // First-launch setup: opened by SetupPresenter after a launch that
        // finds setup incomplete, and by the menu's "Finish setup…", never
        // by the system on its own.
        Window("Set Up CGM Relay", id: SetupWindow.id) {
            SetupView(model: model)
                .onDisappear { WindowActivation.returnToMenuBarOnlyIfNoWindowsRemain() }
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        // A Settings scene, not a plain Window: the system titles and
        // manages the window itself (a Cmd-, shortcut and a Settings…/
        // Preferences… app-menu item come for free), and .contentSize
        // resizability lets the window follow each pane's own natural
        // height as the tab selection changes, rather than every pane
        // sharing one fixed size. Opening it still goes through the menu's
        // own openSettings() call, which keeps the same before-and-after
        // activation-policy toggle the onDisappear below relies on, since
        // that toggle is plain AppKit and never depended on which scene
        // type hosted the window.
        Settings {
            SettingsView(model: model)
                .onDisappear { WindowActivation.returnToMenuBarOnlyIfNoWindowsRemain() }
        }
        .windowResizability(.contentSize)
        // A starting guess only: matches SettingsView's own fixed pane
        // width, before .contentSize resizability settles the height onto
        // the front pane's own measured size.
        .defaultSize(width: 600, height: 460)
    }

    /// engineURL locates the universal engine binary the build embeds at
    /// Contents/Resources/cgm-relay (see macos/project.yml's embed
    /// script). A missing binary means the app bundle itself is broken --
    /// there is no user-facing recovery for that, so it fails loudly
    /// rather than silently running with no engine at all.
    private static func engineURL() -> URL {
        guard let url = Bundle.main.url(forResource: "cgm-relay", withExtension: nil) else {
            fatalError("cgm-relay: the engine binary is missing from the app bundle")
        }
        return url
    }

    /// explicitKeychainServiceOverride reads `-CGMRelayKeychainService`
    /// exactly as given, with no validation and no substitution: nil only
    /// when the argument was never given at all, distinct from an
    /// argument given as an empty string. Read once, up front, and kept
    /// as its own value (rather than folded into
    /// validatedThrowawayKeychainService's own result) because two
    /// different callers need two different questions answered about it:
    /// validatedThrowawayKeychainService needs "which Keychain service
    /// should this launch actually use", which always resolves to some
    /// throwaway service in Debug even when this is nil, while
    /// seedSyntheticAccountIfRequested needs "did the caller explicitly
    /// ask for a throwaway service", which a resolved default must never
    /// answer on the caller's behalf. Always nil in Release, where the
    /// argument is never read.
    private static func explicitKeychainServiceOverride() -> String? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "CGMRelayKeychainService")
        #else
        return nil
        #endif
    }

    /// validatedThrowawayKeychainService turns explicitOverride into the
    /// one Keychain service every downstream call (credentialStore,
    /// databasePath) is backed by. The actual decision is
    /// SyntheticAccountSeeder.resolveKeychainService: a debug build always
    /// ends up on a throwaway service, whether that is the override it was
    /// given or, when none was given at all, a fixed development default,
    /// so a plain debug launch with no argument still never reaches the
    /// real Keychain item or database. An override that fails
    /// isThrowawayService (empty, the app's own real service name, or
    /// anything not safe to use as a single folder name) fails loudly
    /// instead of silently falling back to anything. Absent entirely in
    /// Release, where the result is always the real service.
    private static func validatedThrowawayKeychainService(explicitOverride: String?) -> String? {
        #if DEBUG
        switch SyntheticAccountSeeder.resolveKeychainService(isDebugBuild: true, override: explicitOverride) {
        case .useRealService:
            return nil
        case .useThrowawayService(let service):
            return service
        case .refused(let service):
            fatalError("cgm-relay: -CGMRelayKeychainService \(service) is not a throwaway service (it is empty, names the app's own real Keychain service, or is not a single plain name safe to use as a folder name -- \".\", \"..\", and anything containing \"/\" are refused); refusing to start rather than risk touching the real Keychain item or database")
        }
        #else
        return nil
        #endif
    }

    /// credentialStore returns the production Keychain-backed store when
    /// keychainServiceOverride is nil -- always true in Release, and never
    /// true in Debug, since validatedThrowawayKeychainService always
    /// resolves a debug build onto some throwaway service -- or, otherwise,
    /// one backed by that already-resolved throwaway service instead, so
    /// a development run never touches the owner's real Keychain item.
    private static func credentialStore(keychainServiceOverride: String?) -> any CredentialStore {
        guard let service = keychainServiceOverride else {
            return KeychainCredentialStore()
        }
        return KeychainCredentialStore(service: service)
    }

    /// librelinkupBaseURL is the engine's own escape for pointing sign-in
    /// and every fetch at something other than the official LibreLinkUp
    /// service: a launch argument of `-CGMRelayLibreLinkUpBaseURL <url>`,
    /// read only in a DEBUG build and passed through to the engine's
    /// stdin configuration unchanged. The engine itself refuses anything
    /// but https, or plain http to a loopback address, at load time; a
    /// release build never looks at the argument at all.
    private static func librelinkupBaseURL() -> String? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "CGMRelayLibreLinkUpBaseURL")
        #else
        return nil
        #endif
    }

    /// tailscaleExecutable is the Tailscale command line tool this launch
    /// uses. A release build looks in Tailscale's standard locations; a
    /// debug build never touches the real Tailscale and only runs a fake
    /// named by `-CGMRelayTailscalePath <path>`, honoured only together
    /// with an explicit throwaway `-CGMRelayKeychainService`, exactly like
    /// the synthetic account seed (TailscaleLocator holds the decision).
    private static func tailscaleExecutable(explicitKeychainServiceOverride: String?) -> URL? {
        #if DEBUG
        return TailscaleLocator.resolve(
            isDebugBuild: true,
            fakePath: UserDefaults.standard.string(forKey: "CGMRelayTailscalePath"),
            explicitKeychainServiceOverride: explicitKeychainServiceOverride
        )
        #else
        return TailscaleLocator.resolve(isDebugBuild: false, fakePath: nil, explicitKeychainServiceOverride: nil)
        #endif
    }

    /// seedSyntheticAccountIfRequested writes CGM Relay's fixed
    /// development account into store when the app is launched with
    /// `-CGMRelaySeedSyntheticAccount YES`, so a development run can
    /// reach every menu state with no real account. It passes
    /// explicitKeychainServiceOverride -- the raw, unresolved launch
    /// argument, never the default validatedThrowawayKeychainService
    /// falls back to when none was given -- straight through to
    /// SyntheticAccountSeeder.seed, which is what actually judges whether
    /// it names a throwaway service (SyntheticAccountSeeder.isThrowawayService).
    /// This keeps seeding gated on the caller having explicitly asked for
    /// a throwaway service, exactly as before a debug build with no
    /// `-CGMRelayKeychainService` at all started resolving to one of its
    /// own: store may now be backed by a throwaway service even when
    /// explicitKeychainServiceOverride is nil, but seeding still refuses
    /// in that case, since a synthetic account must never land anywhere
    /// the caller did not explicitly ask to put it. The decision itself
    /// lives in SyntheticAccountSeeder, tested directly against the
    /// CredentialStore protocol; this only reads the one remaining launch
    /// argument and reports the outcome. Called unconditionally from
    /// init(), like credentialStore(): its own body is compiled out of
    /// Release entirely, so it does nothing there and a release build
    /// never looks at either argument.
    private static func seedSyntheticAccountIfRequested(into store: any CredentialStore, explicitKeychainServiceOverride: String?) {
        #if DEBUG
        let seedRequested = UserDefaults.standard.bool(forKey: "CGMRelaySeedSyntheticAccount")
        do {
            let outcome = try SyntheticAccountSeeder.seed(
                into: store,
                seedRequested: seedRequested,
                keychainServiceOverride: explicitKeychainServiceOverride
            )
            if outcome == .refusedNoThrowawayService {
                devLogger.error("-CGMRelaySeedSyntheticAccount was given without a throwaway -CGMRelayKeychainService; refusing to seed a synthetic account anywhere the caller did not explicitly name")
            }
        } catch {
            devLogger.error("failed to seed the synthetic development account: \(error, privacy: .public)")
        }
        #endif
    }

    /// databasePath is where the engine keeps its encrypted reading
    /// store, under this app's own Application Support directory so it
    /// is never beside another app's data. There is no fallback to a
    /// temporary location: a database that silently lands in a temp
    /// directory would lose every reading on the next reboot with
    /// nothing to show anything went wrong, so a directory this cannot
    /// resolve or create fails loudly instead. When
    /// keychainServiceOverride is non-nil (in Release, never; in Debug,
    /// always -- see validatedThrowawayKeychainService), the path is
    /// scoped under DatabasePathResolver's own throwaway location instead
    /// of the real one, so a development run backed by a throwaway
    /// Keychain service can never write, and can never fail to open, the
    /// real database: the two credential stores it could be pointed at
    /// over separate launches never collide, and neither ever collides
    /// with the real store.
    private static func databasePath(keychainServiceOverride: String?) -> String {
        let base: URL
        do {
            base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            fatalError("cgm-relay: could not resolve or create the Application Support directory: \(error)")
        }

        let directory = base.appendingPathComponent("CGM Relay", isDirectory: true)
        let resolved = DatabasePathResolver.resolve(baseDirectory: directory, keychainServiceOverride: keychainServiceOverride)
        let parent = resolved.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            fatalError("cgm-relay: could not create \(parent.path): \(error)")
        }
        return resolved.path
    }
}

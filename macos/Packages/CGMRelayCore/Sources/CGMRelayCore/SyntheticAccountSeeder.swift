import Foundation

/// SyntheticAccountSeeder decides whether to write a fixed, obviously-fake
/// LibreLinkUp account into a credential store, so a development run can
/// reach every menu state with no real account. The decision itself is
/// pure and tested directly against the CredentialStore protocol; the App
/// target only ever reads the two launch arguments and calls seed(...),
/// so this is the one place the actual logic lives and is worth testing.
public enum SyntheticAccountSeeder {
    /// email and password are fixed and obviously synthetic: llufake, the
    /// fake this seeds an account for, accepts any credentials at all, so
    /// their exact values carry no meaning beyond being unmistakably not
    /// a real account.
    public static let email = "synthetic-dev-account@example.invalid"
    public static let password = "synthetic-dev-password"

    /// Outcome names what seed(...) actually did, so a caller (and a
    /// test) can tell "wrote a fresh account" apart from "left an
    /// existing one alone" and "refused" without inspecting the store
    /// itself.
    public enum Outcome: Sendable, Equatable {
        case notRequested
        case seeded
        case alreadyConfigured
        case refusedNoThrowawayService
    }

    /// isThrowawayService reports whether serviceOverride names a
    /// Keychain service distinct from the app's own real one
    /// (KeychainCredentialStore.defaultService): non-nil, non-empty, not
    /// equal to that name, and a single plain path component (never ".",
    /// "..", or anything containing "/"). This is the ONE predicate both
    /// seed(...) below and CGMRelayApp's own
    /// validatedThrowawayKeychainService() trust -- DatabasePathResolver
    /// uses the override as a folder name with no check of its own, so a
    /// launch with no override, an override of "", one that spells out
    /// the production service name, and one that is "." or ".." or
    /// contains "/" (any of which a standardized path can resolve outside
    /// the development folder or onto another service's own folder) are
    /// all refused alike, never treated as "throwaway" merely because
    /// something was passed.
    public static func isThrowawayService(_ serviceOverride: String?) -> Bool {
        guard let serviceOverride, !serviceOverride.isEmpty else { return false }
        guard serviceOverride != KeychainCredentialStore.defaultService else { return false }
        guard serviceOverride != ".", serviceOverride != ".." else { return false }
        return !serviceOverride.contains("/")
    }

    /// developmentDefaultService is the Keychain service (and, through
    /// DatabasePathResolver, the database folder) a debug build uses when
    /// it was given no `-CGMRelayKeychainService` override at all: never
    /// the app's own real service, so a plain debug launch with no
    /// argument can never touch the real Keychain item or the real
    /// database either.
    public static let developmentDefaultService = "com.yaanfpv.cgmrelay.dev.default"

    /// KeychainServiceDecision is which Keychain service (and database
    /// scope) a launch should actually use, given whether the build is
    /// debug and whatever `-CGMRelayKeychainService` override it was
    /// given. It is the pure decision behind CGMRelayApp's own launch
    /// handling, tested directly here rather than only through a running
    /// app.
    public enum KeychainServiceDecision: Sendable, Equatable {
        /// useRealService is the app's own production Keychain service
        /// and database: the only outcome for a release build, whatever
        /// it was given, since a release build never reads the override
        /// at all.
        case useRealService
        /// useThrowawayService names a service distinct from the real
        /// one: either the caller's own override, once proven throwaway,
        /// or, when a debug build was given none, developmentDefaultService.
        case useThrowawayService(String)
        /// refused is a debug build given an override that failed
        /// isThrowawayService (empty, the real service name, or not a
        /// single plain path component); the associated value is that
        /// override, unexamined further, so a caller can report why it
        /// was refused.
        case refused(String)
    }

    /// resolveKeychainService is deliberately fed isDebugBuild rather than
    /// reading a compile-time flag itself, so a test can exercise every
    /// combination without needing a second build. override is exactly
    /// what `-CGMRelayKeychainService` read, or nil if the argument was
    /// never given at all -- distinct from an override that was given as
    /// an empty string, which isThrowawayService refuses.
    public static func resolveKeychainService(isDebugBuild: Bool, override: String?) -> KeychainServiceDecision {
        guard isDebugBuild else { return .useRealService }
        guard let override else { return .useThrowawayService(developmentDefaultService) }
        guard isThrowawayService(override) else { return .refused(override) }
        return .useThrowawayService(override)
    }

    /// seed writes the fixed synthetic account into store, but only when
    /// seedRequested is true AND isThrowawayService(keychainServiceOverride)
    /// is true. keychainServiceOverride is the caller's own
    /// -CGMRelayKeychainService argument, unexamined by this function
    /// beyond that one predicate: it never touches a Keychain itself, so
    /// it cannot independently verify which service store is actually
    /// backed by, and trusts the predicate instead of a bare "something
    /// was passed" check. An existing librelinkup_email is left untouched
    /// either way: seeding never overwrites a real account a person
    /// entered.
    public static func seed(
        into store: any CredentialStore,
        seedRequested: Bool,
        keychainServiceOverride: String?
    ) throws -> Outcome {
        guard seedRequested else { return .notRequested }
        guard isThrowawayService(keychainServiceOverride) else { return .refusedNoThrowawayService }

        if let existing = try store.string(for: .librelinkupEmail), !existing.isEmpty {
            return .alreadyConfigured
        }

        try store.setString(email, for: .librelinkupEmail)
        try store.setString(password, for: .librelinkupPassword)
        return .seeded
    }
}

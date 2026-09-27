import Testing
@testable import CGMRelayCore

@Suite("SyntheticAccountSeeder")
struct SyntheticAccountSeederTests {
    @Test("isThrowawayService accepts only a non-empty, single-component override that differs from the real Keychain service")
    func isThrowawayServiceCases() throws {
        let cases: [(override: String?, want: Bool)] = [
            (nil, false),
            ("", false),
            (KeychainCredentialStore.defaultService, false),
            (".", false),
            ("..", false),
            ("../..", false),
            ("a/b", false),
            ("com.yaanfpv.cgmrelay.dev.test", true),
        ]
        for c in cases {
            #expect(
                SyntheticAccountSeeder.isThrowawayService(c.override) == c.want,
                "isThrowawayService(\(String(describing: c.override)))"
            )
        }
    }

    @Test("resolveKeychainService always keeps a debug build off the real service, resolving no override to a fixed development default, and never lets a release build read the argument at all")
    func resolveKeychainServiceCases() throws {
        let validOverride = "com.yaanfpv.cgmrelay.dev.test"
        let cases: [(isDebugBuild: Bool, override: String?, want: SyntheticAccountSeeder.KeychainServiceDecision)] = [
            (true, nil, .useThrowawayService(SyntheticAccountSeeder.developmentDefaultService)),
            (true, validOverride, .useThrowawayService(validOverride)),
            (true, "", .refused("")),
            (true, KeychainCredentialStore.defaultService, .refused(KeychainCredentialStore.defaultService)),
            (true, "..", .refused("..")),
            (false, nil, .useRealService),
            (false, validOverride, .useRealService),
        ]
        for c in cases {
            let got = SyntheticAccountSeeder.resolveKeychainService(isDebugBuild: c.isDebugBuild, override: c.override)
            #expect(got == c.want, "isDebugBuild: \(c.isDebugBuild), override: \(String(describing: c.override))")
        }
    }

    @Test("does nothing when seeding was not requested")
    func doesNothingWhenNotRequested() throws {
        let store = FakeCredentialStore()

        let outcome = try SyntheticAccountSeeder.seed(
            into: store,
            seedRequested: false,
            keychainServiceOverride: "com.yaanfpv.cgmrelay.dev.test"
        )

        #expect(outcome == .notRequested)
        #expect(store.snapshot()[.librelinkupEmail] == nil)
    }

    @Test("refuses every override that is not proven throwaway: absent, empty, the real service name, or not a single plain path component")
    func refusesEveryNonThrowawayOverride() throws {
        let cases: [String?] = [nil, "", KeychainCredentialStore.defaultService, ".", "..", "../..", "a/b"]
        for override in cases {
            let store = FakeCredentialStore()

            let outcome = try SyntheticAccountSeeder.seed(into: store, seedRequested: true, keychainServiceOverride: override)

            #expect(outcome == .refusedNoThrowawayService, "keychainServiceOverride = \(String(describing: override))")
            #expect(store.snapshot()[.librelinkupEmail] == nil)
            #expect(store.snapshot()[.librelinkupPassword] == nil)
        }
    }

    @Test("seeds only when requested against a genuinely different, non-empty service name")
    func seedsWhenRequestedAndThrowaway() throws {
        let store = FakeCredentialStore()

        let outcome = try SyntheticAccountSeeder.seed(
            into: store,
            seedRequested: true,
            keychainServiceOverride: "com.yaanfpv.cgmrelay.dev.test"
        )

        #expect(outcome == .seeded)
        #expect(store.snapshot()[.librelinkupEmail] == SyntheticAccountSeeder.email)
        #expect(store.snapshot()[.librelinkupPassword] == SyntheticAccountSeeder.password)
    }

    @Test("never overwrites an account already on file")
    func leavesAnExistingAccountUntouched() throws {
        let store = FakeCredentialStore(values: [
            .librelinkupEmail: "real-person@example.invalid",
            .librelinkupPassword: "a-real-password",
        ])

        let outcome = try SyntheticAccountSeeder.seed(
            into: store,
            seedRequested: true,
            keychainServiceOverride: "com.yaanfpv.cgmrelay.dev.test"
        )

        #expect(outcome == .alreadyConfigured)
        #expect(store.snapshot()[.librelinkupEmail] == "real-person@example.invalid")
        #expect(store.snapshot()[.librelinkupPassword] == "a-real-password")
    }
}

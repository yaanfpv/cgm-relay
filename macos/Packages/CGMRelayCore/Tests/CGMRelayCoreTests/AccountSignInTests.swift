import Testing
@testable import CGMRelayCore

@Suite("AccountSignIn")
struct AccountSignInTests {
    @Test("a successful check saves the email and password")
    func signInSavesOnSuccess() async throws {
        let store = FakeCredentialStore()
        let checker = FakeAccountCheckRunning(outcome: .signedIn)
        let signIn = AccountSignIn(checker: checker, store: store)

        let outcome = await signIn.signIn(email: "person@example.invalid", password: "not-a-real-password", librelinkupBaseURL: nil)

        #expect(outcome == .signedIn)
        #expect(store.snapshot()[.librelinkupEmail] == "person@example.invalid")
        #expect(store.snapshot()[.librelinkupPassword] == "not-a-real-password")
    }

    @Test(
        "a refused check saves nothing",
        arguments: [
            AccountCheckOutcome.invalidCredentials,
            .termsNotAccepted,
            .noConnections,
            .rateLimited,
            .unreachable,
            .other,
        ]
    )
    func refusedCheckSavesNothing(_ outcome: AccountCheckOutcome) async throws {
        let store = FakeCredentialStore()
        let checker = FakeAccountCheckRunning(outcome: outcome)
        let signIn = AccountSignIn(checker: checker, store: store)

        let got = await signIn.signIn(email: "person@example.invalid", password: "not-a-real-password", librelinkupBaseURL: nil)

        #expect(got == outcome)
        #expect(store.snapshot()[.librelinkupEmail] == nil)
        #expect(store.snapshot()[.librelinkupPassword] == nil)
    }

    @Test("a refused check on an already-signed-in account leaves the existing account alone")
    func refusedCheckLeavesExistingAccount() async throws {
        let store = FakeCredentialStore(values: [
            .librelinkupEmail: "existing@example.invalid",
            .librelinkupPassword: "existing-password",
        ])
        let checker = FakeAccountCheckRunning(outcome: .invalidCredentials)
        let signIn = AccountSignIn(checker: checker, store: store)

        _ = await signIn.signIn(email: "attempted@example.invalid", password: "wrong-password", librelinkupBaseURL: nil)

        #expect(store.snapshot()[.librelinkupEmail] == "existing@example.invalid")
        #expect(store.snapshot()[.librelinkupPassword] == "existing-password")
    }

    @Test("sign-out removes exactly the email and password, keeping the token and store key")
    func signOutRemovesExactlyEmailAndPassword() throws {
        let store = FakeCredentialStore(values: [
            .librelinkupEmail: "person@example.invalid",
            .librelinkupPassword: "not-a-real-password",
            .token: "a-token",
            .storeKey: "a-key",
        ])
        let signIn = AccountSignIn(checker: FakeAccountCheckRunning(outcome: .signedIn), store: store)

        try signIn.signOut()

        let values = store.snapshot()
        #expect(values[.librelinkupEmail] == nil)
        #expect(values[.librelinkupPassword] == nil)
        #expect(values[.token] == "a-token")
        #expect(values[.storeKey] == "a-key")
    }

    @Test("a save failure after a successful check reports saveFailed and leaves the store exactly as before, never a mixed email and password")
    func saveFailureLeavesStoreUnchanged() async throws {
        let store = FakeCredentialStore(values: [
            .librelinkupEmail: "existing@example.invalid",
            .librelinkupPassword: "existing-password",
        ])
        store.failNextSetStrings = true
        let checker = FakeAccountCheckRunning(outcome: .signedIn)
        let signIn = AccountSignIn(checker: checker, store: store)

        let outcome = await signIn.signIn(email: "new@example.invalid", password: "new-password", librelinkupBaseURL: nil)

        #expect(outcome == .saveFailed)
        #expect(store.snapshot()[.librelinkupEmail] == "existing@example.invalid")
        #expect(store.snapshot()[.librelinkupPassword] == "existing-password")
    }

    @Test("a sign-out failure throws and leaves the email and password exactly as they were")
    func signOutFailureLeavesStoreUnchanged() throws {
        let store = FakeCredentialStore(values: [
            .librelinkupEmail: "person@example.invalid",
            .librelinkupPassword: "not-a-real-password",
        ])
        store.failNextRemoveAll = true
        let signIn = AccountSignIn(checker: FakeAccountCheckRunning(outcome: .signedIn), store: store)

        #expect(throws: (any Error).self) { try signIn.signOut() }

        let values = store.snapshot()
        #expect(values[.librelinkupEmail] == "person@example.invalid")
        #expect(values[.librelinkupPassword] == "not-a-real-password")
    }

    @Test("signIn passes librelinkupBaseURL through to the checker")
    func passesBaseURLThrough() async throws {
        let store = FakeCredentialStore()
        let checker = FakeAccountCheckRunning(outcome: .signedIn)
        let signIn = AccountSignIn(checker: checker, store: store)

        _ = await signIn.signIn(email: "person@example.invalid", password: "not-a-real-password", librelinkupBaseURL: "http://127.0.0.1:9999")

        #expect(checker.calls.count == 1)
        #expect(checker.calls[0].librelinkupBaseURL == "http://127.0.0.1:9999")
    }
}

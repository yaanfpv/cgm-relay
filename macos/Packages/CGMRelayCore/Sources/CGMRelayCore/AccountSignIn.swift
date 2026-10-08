import Foundation

/// AccountSignIn coordinates the Account pane's sign-in and sign-out
/// actions, so both are tested directly against a fake AccountCheckRunning
/// and a fake CredentialStore, with no real check-account process or
/// Keychain access anywhere in the test.
public struct AccountSignIn: Sendable {
    private let checker: any AccountCheckRunning
    private let store: any CredentialStore

    public init(checker: any AccountCheckRunning, store: any CredentialStore) {
        self.checker = checker
        self.store = store
    }

    /// signIn checks email and password against LibreLinkUp before saving
    /// anything: only a successful check ever writes them to store, in
    /// one atomic write (CredentialStore.setStrings's own contract), so a
    /// failure partway through a save can never leave a new email paired
    /// with an old password or vice versa -- that failure is reported as
    /// .saveFailed instead of .signedIn. Every other outcome, including
    /// .other, leaves store exactly as it was, so a refused check never
    /// overwrites a previously working account.
    ///
    /// The email is trimmed first, and an email that is not
    /// local@domain.tld is refused as .malformedEmail without starting
    /// any check; the trimmed value is what is checked and saved.
    public func signIn(email rawEmail: String, password: String, librelinkupBaseURL: String?) async -> AccountCheckOutcome {
        guard let email = AccountEmail.trimmedIfValid(rawEmail) else { return .malformedEmail }
        let outcome = await checker.checkAccount(email: email, password: password, librelinkupBaseURL: librelinkupBaseURL)
        guard outcome == .signedIn else { return outcome }
        do {
            try store.setStrings([.librelinkupEmail: email, .librelinkupPassword: password])
            return .signedIn
        } catch {
            return .saveFailed
        }
    }

    /// signOut removes exactly the LibreLinkUp email and password from
    /// store, in one atomic write (CredentialStore.removeAll's own
    /// contract), so a failure partway through can never leave one
    /// removed and the other still in place. The generated token and
    /// store key are never touched: they belong to this Mac's own
    /// follower apps and reading history, not to the LibreLinkUp account,
    /// and a follower app must keep working (against whatever readings
    /// are already saved) through a sign-out. Throws, rather than
    /// swallowing the failure, so a caller can tell the person it did not
    /// happen instead of claiming it did.
    public func signOut() throws {
        try store.removeAll([.librelinkupEmail, .librelinkupPassword])
    }
}

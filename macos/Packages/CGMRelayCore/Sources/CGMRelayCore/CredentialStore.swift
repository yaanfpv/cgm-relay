import Foundation

/// CredentialKey names every value CGM Relay keeps in the Keychain: the
/// two a person enters (the LibreLinkUp account) and the two the app
/// generates for itself (the Nightscout token and the store key).
public enum CredentialKey: String, Sendable, CaseIterable {
    case librelinkupEmail = "librelinkup_email"
    case librelinkupPassword = "librelinkup_password"
    case token = "token"
    case storeKey = "store_key"
}

/// CredentialStore reads and writes CGM Relay's secrets. Production code
/// uses KeychainCredentialStore; tests use an in-memory store behind this
/// same protocol, so the credentials logic is exercised with no Keychain
/// access at all.
public protocol CredentialStore: Sendable {
    func string(for key: CredentialKey) throws -> String?
    func setString(_ value: String, for key: CredentialKey) throws
    /// setStrings writes every value in values as a single atomic update
    /// to the one underlying item: either all of them land, or none do,
    /// so two related secrets (an account's email and its password) can
    /// never end up mixed between an old and a new value because the
    /// second of two separate writes failed.
    func setStrings(_ values: [CredentialKey: String]) throws
    /// removeAll deletes every key in keys as a single atomic update:
    /// either all of them are removed, or none are.
    func removeAll(_ keys: [CredentialKey]) throws
    /// removeRawKeys deletes the entries stored under names as a single
    /// atomic update, for names no CredentialKey case carries any more: a
    /// name that is not stored is ignored, and nothing else is touched.
    func removeRawKeys(_ names: [String]) throws
    /// addMissing stores each value in newValues whose key has no value
    /// yet, leaves every key that already has one untouched, and returns
    /// what is stored for every key given. The check and the write are one
    /// step, so two copies of the app starting together both end up with
    /// the first writer's values.
    func addMissing(_ newValues: [CredentialKey: String]) throws -> [CredentialKey: String]
}

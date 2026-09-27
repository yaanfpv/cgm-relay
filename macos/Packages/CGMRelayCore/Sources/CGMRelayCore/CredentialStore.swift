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
}

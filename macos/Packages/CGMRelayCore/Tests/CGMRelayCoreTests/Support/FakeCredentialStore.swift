import CGMRelayCore
import Foundation

/// FakeCredentialStore is an in-memory CredentialStore, so credentials
/// logic (bootstrapping, configuration building) is tested with no
/// Keychain access at all.
final class FakeCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CredentialKey: String]

    init(values: [CredentialKey: String] = [:]) {
        self.values = values
    }

    func string(for key: CredentialKey) throws -> String? {
        lock.withLock { values[key] }
    }

    func setString(_ value: String, for key: CredentialKey) throws {
        lock.withLock { values[key] = value }
    }

    func snapshot() -> [CredentialKey: String] {
        lock.withLock { values }
    }
}

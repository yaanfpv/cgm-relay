import CGMRelayCore
import Foundation

/// FakeCredentialStoreError is the one error FakeCredentialStore ever
/// throws, when a test has asked it to simulate a write failing.
enum FakeCredentialStoreError: Error {
    case simulatedFailure
}

/// FakeCredentialStore is an in-memory CredentialStore, so credentials
/// logic (bootstrapping, configuration building) is tested with no
/// Keychain access at all. failNextSetStrings and failNextRemoveAll let a
/// test prove that a simulated write failure never leaves values in a
/// mixed state: each flag is consumed (reset to false) by the one call it
/// fails, exactly like a real, one-shot Keychain write failing once.
final class FakeCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CredentialKey: String]
    var failNextSetStrings = false
    var failNextRemoveAll = false

    init(values: [CredentialKey: String] = [:]) {
        self.values = values
    }

    func string(for key: CredentialKey) throws -> String? {
        lock.withLock { values[key] }
    }

    func setString(_ value: String, for key: CredentialKey) throws {
        lock.withLock { values[key] = value }
    }

    func setStrings(_ newValues: [CredentialKey: String]) throws {
        try lock.withLock {
            if failNextSetStrings {
                failNextSetStrings = false
                throw FakeCredentialStoreError.simulatedFailure
            }
            for (key, value) in newValues {
                values[key] = value
            }
        }
    }

    func removeAll(_ keys: [CredentialKey]) throws {
        try lock.withLock {
            if failNextRemoveAll {
                failNextRemoveAll = false
                throw FakeCredentialStoreError.simulatedFailure
            }
            for key in keys {
                values.removeValue(forKey: key)
            }
        }
    }

    func snapshot() -> [CredentialKey: String] {
        lock.withLock { values }
    }
}

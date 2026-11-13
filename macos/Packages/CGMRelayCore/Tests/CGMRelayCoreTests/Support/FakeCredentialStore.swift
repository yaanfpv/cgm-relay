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
/// Values are held under their raw key names, like the one Keychain item
/// they stand in for, so a test can seed or inspect a name that no
/// CredentialKey case carries (rawValues, rawSnapshot).
final class FakeCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    var failNextSetStrings = false
    var failNextRemoveAll = false
    var failNextRemoveRawKeys = false

    init(values: [CredentialKey: String] = [:], rawValues: [String: String] = [:]) {
        var seeded = rawValues
        for (key, value) in values {
            seeded[key.rawValue] = value
        }
        self.values = seeded
    }

    func string(for key: CredentialKey) throws -> String? {
        lock.withLock { values[key.rawValue] }
    }

    func setString(_ value: String, for key: CredentialKey) throws {
        lock.withLock { values[key.rawValue] = value }
    }

    func setStrings(_ newValues: [CredentialKey: String]) throws {
        try lock.withLock {
            if failNextSetStrings {
                failNextSetStrings = false
                throw FakeCredentialStoreError.simulatedFailure
            }
            for (key, value) in newValues {
                values[key.rawValue] = value
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
                values.removeValue(forKey: key.rawValue)
            }
        }
    }

    func removeRawKeys(_ names: [String]) throws {
        try lock.withLock {
            if failNextRemoveRawKeys {
                failNextRemoveRawKeys = false
                throw FakeCredentialStoreError.simulatedFailure
            }
            for name in names {
                values.removeValue(forKey: name)
            }
        }
    }

    func addMissing(_ newValues: [CredentialKey: String]) throws -> [CredentialKey: String] {
        lock.withLock {
            var stored: [CredentialKey: String] = [:]
            for (key, value) in newValues {
                if values[key.rawValue] == nil { values[key.rawValue] = value }
                stored[key] = values[key.rawValue]
            }
            return stored
        }
    }

    func snapshot() -> [CredentialKey: String] {
        lock.withLock {
            var known: [CredentialKey: String] = [:]
            for (name, value) in values {
                if let key = CredentialKey(rawValue: name) { known[key] = value }
            }
            return known
        }
    }

    /// rawSnapshot is every stored value under its raw key name, including
    /// names no CredentialKey case carries.
    func rawSnapshot() -> [String: String] {
        lock.withLock { values }
    }
}

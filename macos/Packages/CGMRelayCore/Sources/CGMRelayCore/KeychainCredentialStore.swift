import Foundation
import Security

/// KeychainError wraps a Keychain operation's own OSStatus, or a failure
/// converting to or from the JSON document a Keychain item stores.
public enum KeychainError: Error, Sendable, Equatable {
    case osStatus(OSStatus)
    case decodingFailed
    case encodingFailed
}

/// KeychainCredentialStore holds every one of CGM Relay's secrets inside a
/// single generic password item, one JSON document under one account name
/// and service: reading four separate items, each its own system access
/// check, is what turned an ordinary launch into a run of Keychain
/// prompts. The item is read at most once per process, the first time any
/// secret is asked for, and kept in memory after that; a write updates the
/// cache and rewrites the whole item, only when something actually
/// changes.
public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    /// defaultService is the Keychain service the credentials item is
    /// stored under, matching the app's own bundle identifier.
    public static let defaultService = "com.yaanfpv.cgmrelay"

    /// account is fixed: every secret lives inside the one item's JSON
    /// body, so there is nothing left to distinguish by account name.
    private static let account = "credentials"

    private let service: String
    private let lock = NSLock()
    /// cache is nil only before the item has been read for the first
    /// time; once loaded (whether the item existed or not) it is always
    /// present, so every later string(for:) is an in-memory lookup.
    private var cache: [String: String]?

    public init(service: String = KeychainCredentialStore.defaultService) {
        self.service = service
    }

    public func string(for key: CredentialKey) throws -> String? {
        try lock.withLock {
            try loadIfNeeded()
            return cache?[key.rawValue]
        }
    }

    public func setString(_ value: String, for key: CredentialKey) throws {
        try lock.withLock {
            try loadIfNeeded()
            var updated = cache ?? [:]
            updated[key.rawValue] = value
            try write(updated)
            cache = updated
        }
    }

    private func loadIfNeeded() throws {
        guard cache == nil else { return }

        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainError.decodingFailed
            }
            do {
                cache = try JSONDecoder().decode([String: String].self, from: data)
            } catch {
                throw KeychainError.decodingFailed
            }
        case errSecItemNotFound:
            cache = [:]
        default:
            throw KeychainError.osStatus(status)
        }
    }

    private func write(_ values: [String: String]) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(values)
        } catch {
            throw KeychainError.encodingFailed
        }

        let query = baseQuery()
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.osStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.osStatus(addStatus)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
        ]
    }
}

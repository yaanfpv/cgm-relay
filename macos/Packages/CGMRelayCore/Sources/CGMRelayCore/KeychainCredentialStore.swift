import Foundation
import Security

/// KeychainError wraps a Keychain operation's own OSStatus, a failure
/// converting to or from the JSON document a Keychain item stores, or a
/// change abandoned because another running copy held the credentials lock
/// past the timeout.
public enum KeychainError: Error, Sendable, Equatable {
    case osStatus(OSStatus)
    case decodingFailed
    case encodingFailed
    case lockTimeout
    case lockUnavailable(Int32)
}

/// CredentialItemBacking is the one stored item's raw bytes: where
/// KeychainCredentialStore reads and writes the JSON document. Production
/// uses the Keychain; a test shares one in-memory item between two stores
/// the way two running copies of the app share the real one.
public protocol CredentialItemBacking: Sendable {
    /// read returns the item's bytes, or nil when no item exists.
    func read() throws -> Data?
    /// write replaces the item's bytes, creating the item when absent.
    func write(_ data: Data) throws
}

/// KeychainItemBacking is the production backing: one generic password
/// item under a fixed account and the given service.
public struct KeychainItemBacking: CredentialItemBacking {
    /// account is fixed: every secret lives inside the one item's JSON
    /// body, so there is nothing left to distinguish by account name.
    private static let account = "credentials"

    private let service: String

    public init(service: String) {
        self.service = service
    }

    public func read() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError.decodingFailed }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.osStatus(status)
        }
    }

    public func write(_ data: Data) throws {
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

/// KeychainCredentialStore holds every one of CGM Relay's secrets inside a
/// single item, one JSON document: reading four separate items, each its
/// own system access check, is what turned an ordinary launch into a run
/// of Keychain prompts. Reads are served from a copy kept in memory after
/// the first one.
///
/// Several copies of the app can run against the same item, each with its
/// own in-memory copy, so every change goes through one locked step: take
/// an exclusive lock on a file shared by all copies, read the item again,
/// apply the change to what was just read, write it only when something
/// changed, refresh the in-memory copy, and release the lock. A change
/// therefore never rewrites a value another copy saved since this one
/// last looked, and a check followed by a write (addMissing) is one step.
/// When the lock cannot be taken within lockTimeout the change is
/// abandoned with KeychainError.lockTimeout and nothing is written.
public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    /// defaultService is the Keychain service the credentials item is
    /// stored under, matching the app's own bundle identifier.
    public static let defaultService = "com.yaanfpv.cgmrelay"

    /// defaultLockTimeout is how long a change waits for another copy to
    /// finish its own before giving up.
    public static let defaultLockTimeout: TimeInterval = 5

    private static let lockPollInterval: useconds_t = 25_000

    private let backing: any CredentialItemBacking
    private let lockURL: URL
    private let lockTimeout: TimeInterval
    private let lock = NSLock()
    /// cache is nil only before the item has been read for the first
    /// time; once loaded (whether the item existed or not) it is always
    /// present, so every later string(for:) is an in-memory lookup. Every
    /// locked change replaces it with what that change read and wrote.
    private var cache: [String: String]?

    /// init stores credentials in backing, serialising changes across
    /// running copies with the file at lockURL. Without a lockURL the file
    /// is credentials.lock beside the reading database for service, so a
    /// throwaway service gets a lock of its own.
    public init(
        service: String = KeychainCredentialStore.defaultService,
        backing: (any CredentialItemBacking)? = nil,
        lockURL: URL? = nil,
        lockTimeout: TimeInterval = KeychainCredentialStore.defaultLockTimeout
    ) {
        self.backing = backing ?? KeychainItemBacking(service: service)
        self.lockURL = lockURL ?? Self.defaultLockURL(service: service)
        self.lockTimeout = lockTimeout
    }

    public func string(for key: CredentialKey) throws -> String? {
        try lock.withLock {
            try loadIfNeeded()
            return cache?[key.rawValue]
        }
    }

    public func setString(_ value: String, for key: CredentialKey) throws {
        try mutate { items in
            items[key.rawValue] = value
            return true
        }
    }

    public func setStrings(_ values: [CredentialKey: String]) throws {
        try mutate { items in
            for (key, value) in values {
                items[key.rawValue] = value
            }
            return true
        }
    }

    public func removeAll(_ keys: [CredentialKey]) throws {
        try removeNames(keys.map(\.rawValue))
    }

    public func removeRawKeys(_ names: [String]) throws {
        try removeNames(names)
    }

    public func addMissing(_ newValues: [CredentialKey: String]) throws -> [CredentialKey: String] {
        var stored: [CredentialKey: String] = [:]
        try mutate { items in
            var changed = false
            stored = [:]
            for (key, value) in newValues {
                if items[key.rawValue] == nil {
                    items[key.rawValue] = value
                    changed = true
                }
                stored[key] = items[key.rawValue]
            }
            return changed
        }
        return stored
    }

    private func removeNames(_ names: [String]) throws {
        try mutate { items in
            var changed = false
            for name in names where items.removeValue(forKey: name) != nil {
                changed = true
            }
            return changed
        }
    }

    /// mutate is the only way the item changes. body receives what is in
    /// the item right now and returns whether it changed it; the item is
    /// written only then.
    private func mutate(_ body: (inout [String: String]) throws -> Bool) throws {
        try lock.withLock {
            let descriptor = try acquireFileLock()
            defer {
                flock(descriptor, LOCK_UN)
                close(descriptor)
            }
            var items = try readItem()
            if try body(&items) {
                try writeItem(items)
            }
            cache = items
        }
    }

    private func loadIfNeeded() throws {
        guard cache == nil else { return }
        cache = try readItem()
    }

    private func readItem() throws -> [String: String] {
        guard let data = try backing.read() else { return [:] }
        do {
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            throw KeychainError.decodingFailed
        }
    }

    private func writeItem(_ items: [String: String]) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(items)
        } catch {
            throw KeychainError.encodingFailed
        }
        try backing.write(data)
    }

    /// acquireFileLock opens the lock file, creating it and its folder when
    /// missing, and takes an exclusive lock on it, polling until
    /// lockTimeout. The lock belongs to the descriptor, so it is dropped
    /// when the descriptor closes, including when the process dies.
    private func acquireFileLock() throws -> Int32 {
        do {
            try FileManager.default.createDirectory(
                at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw KeychainError.lockUnavailable(errno)
        }
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw KeychainError.lockUnavailable(errno) }

        let deadline = Date().addingTimeInterval(lockTimeout)
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return descriptor }
            let reason = errno
            guard reason == EWOULDBLOCK || reason == EINTR else {
                close(descriptor)
                throw KeychainError.lockUnavailable(reason)
            }
            guard Date() < deadline else {
                close(descriptor)
                throw KeychainError.lockTimeout
            }
            usleep(Self.lockPollInterval)
        }
    }

    private static func defaultLockURL(service: String) -> URL {
        let support =
            (try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return DatabasePathResolver.credentialLockURL(
            baseDirectory: support.appendingPathComponent("CGM Relay", isDirectory: true),
            keychainServiceOverride: service == defaultService ? nil : service)
    }
}

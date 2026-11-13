import Testing
import Foundation
@testable import CGMRelayCore

@Suite("CredentialsBootstrapper")
struct CredentialsBootstrapperTests {
    @Test("generates and stores a token and a store key on first run")
    func generatesOnFirstRun() throws {
        let store = FakeCredentialStore()
        let bootstrapper = CredentialsBootstrapper(store: store, randomBytes: FakeRandomBytesGenerator())

        try bootstrapper.ensureBootstrapped()

        let values = store.snapshot()
        #expect(values[.token] != nil)
        #expect(values[.storeKey] != nil)
        // The fake generator returns a fixed, distinguishable byte
        // pattern, so the exact encodings can be checked rather than just
        // their presence.
        let expectedBytes = Data((0..<32).map { UInt8($0 % 256) })
        #expect(values[.token] == expectedBytes.base64URLEncodedStringWithoutPadding())
        #expect(values[.storeKey] == expectedBytes.base64EncodedString())
    }

    @Test("never overwrites an existing token or key")
    func doesNotOverwriteExisting() throws {
        let store = FakeCredentialStore(values: [.token: "existing-token", .storeKey: "existing-key"])
        let bootstrapper = CredentialsBootstrapper(store: store, randomBytes: FakeRandomBytesGenerator())

        try bootstrapper.ensureBootstrapped()

        let values = store.snapshot()
        #expect(values[.token] == "existing-token")
        #expect(values[.storeKey] == "existing-key")
    }

    @Test("is safe to call repeatedly")
    func repeatedCallsAreIdempotent() throws {
        let store = FakeCredentialStore()
        let bootstrapper = CredentialsBootstrapper(store: store, randomBytes: FakeRandomBytesGenerator())

        try bootstrapper.ensureBootstrapped()
        let firstToken = store.snapshot()[.token]
        try bootstrapper.ensureBootstrapped()
        let secondToken = store.snapshot()[.token]

        #expect(firstToken == secondToken)
    }

    @Test("rotateToken always overwrites an existing token, and returns the value it saved")
    func rotateTokenAlwaysOverwrites() throws {
        let store = FakeCredentialStore(values: [.token: "old-token"])
        let bootstrapper = CredentialsBootstrapper(store: store, randomBytes: FakeRandomBytesGenerator())

        let rotated = try bootstrapper.rotateToken()

        #expect(rotated != "old-token")
        #expect(store.snapshot()[.token] == rotated)
    }

    @Test("rotateToken uses the same encoding ensureBootstrapped's own first-run token uses")
    func rotateTokenUsesTheSameEncoding() throws {
        let store = FakeCredentialStore()
        let bootstrapper = CredentialsBootstrapper(store: store, randomBytes: FakeRandomBytesGenerator())

        let rotated = try bootstrapper.rotateToken()

        let expectedBytes = Data((0..<32).map { UInt8($0 % 256) })
        #expect(rotated == expectedBytes.base64URLEncodedStringWithoutPadding())
    }

    // MARK: retired certificate secrets

    private static let retiredRawKeys = ["authority_key", "authority_certificate", "server_key", "server_certificate"]

    private static let currentSecrets: [CredentialKey: String] = [
        .librelinkupEmail: "person@example.invalid",
        .librelinkupPassword: "not-a-real-password",
        .token: "synthetic-token",
        .storeKey: "synthetic-store-key",
    ]

    private static func seededWithAllEight() -> FakeCredentialStore {
        FakeCredentialStore(values: currentSecrets, rawValues: [
            "authority_key": "synthetic-authority-key",
            "authority_certificate": "synthetic-authority-certificate",
            "server_key": "synthetic-server-key",
            "server_certificate": "synthetic-server-certificate",
        ])
    }

    private static func rawCurrent() -> [String: String] {
        Dictionary(uniqueKeysWithValues: currentSecrets.map { ($0.key.rawValue, $0.value) })
    }

    @Test("the retired certificate raw keys are exactly the four the old route stored")
    func retiredRawKeysAreTheFour() {
        #expect(RetiredCertificateSecrets.rawKeys == Self.retiredRawKeys)
    }

    @Test("remove deletes the four certificate keys and leaves the email, password, token and store key exactly as seeded")
    func removeDeletesOnlyTheCertificateKeys() throws {
        let store = Self.seededWithAllEight()

        try RetiredCertificateSecrets.remove(from: store)

        #expect(store.rawSnapshot() == Self.rawCurrent())
    }

    @Test("a second remove succeeds and changes nothing")
    func secondRemoveChangesNothing() throws {
        let store = Self.seededWithAllEight()
        try RetiredCertificateSecrets.remove(from: store)
        let afterFirst = store.rawSnapshot()

        try RetiredCertificateSecrets.remove(from: store)

        #expect(store.rawSnapshot() == afterFirst)
        #expect(afterFirst == Self.rawCurrent())
    }

    @Test("a store that never held the certificate keys is left unchanged, and an empty store stays empty")
    func removeOnStoreWithoutThemChangesNothing() throws {
        let store = FakeCredentialStore(values: Self.currentSecrets)
        try RetiredCertificateSecrets.remove(from: store)
        #expect(store.rawSnapshot() == Self.rawCurrent())

        let empty = FakeCredentialStore()
        try RetiredCertificateSecrets.remove(from: empty)
        #expect(empty.rawSnapshot().isEmpty)
    }

    @Test("remove with only some of the four present removes those and touches nothing else")
    func removeWithSomePresent() throws {
        let store = FakeCredentialStore(values: Self.currentSecrets, rawValues: ["server_key": "synthetic-server-key", "authority_certificate": "synthetic-authority-certificate"])

        try RetiredCertificateSecrets.remove(from: store)

        #expect(store.rawSnapshot() == Self.rawCurrent())
    }

    @Test("a failing removeRawKeys throws out of remove and leaves all eight exactly as seeded, never a partial removal")
    func removeFailureLeavesStoreUnchanged() throws {
        let store = Self.seededWithAllEight()
        let before = store.rawSnapshot()
        store.failNextRemoveRawKeys = true

        #expect(throws: (any Error).self) { try RetiredCertificateSecrets.remove(from: store) }

        #expect(store.rawSnapshot() == before)
        #expect(before.count == 8)
    }

    @Test("removeRawKeys deletes the named keys in one update and leaves every other key byte-identical")
    func removeRawKeysDeletesNamedOnly() throws {
        let store = FakeCredentialStore(values: Self.currentSecrets, rawValues: ["some_other_name": "kept"])

        try store.removeRawKeys(["token", "some_other_name", "never_stored"])

        var expected = Self.rawCurrent()
        expected.removeValue(forKey: "token")
        #expect(store.rawSnapshot() == expected)
    }

    @Test("a removeRawKeys failure leaves the store exactly as before and is consumed by that one call")
    func removeRawKeysFailureIsAtomicAndOneShot() throws {
        let store = FakeCredentialStore(values: Self.currentSecrets)
        store.failNextRemoveRawKeys = true

        #expect(throws: (any Error).self) { try store.removeRawKeys(["token", "store_key"]) }
        #expect(store.rawSnapshot() == Self.rawCurrent())

        try store.removeRawKeys(["token", "store_key"])
        #expect(store.rawSnapshot()["token"] == nil && store.rawSnapshot()["store_key"] == nil)
        #expect(store.snapshot()[.librelinkupEmail] == "person@example.invalid")
    }
}

@Suite("KeychainCredentialStore across two running copies")
struct KeychainCredentialStoreSharedItemTests {
    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kc-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func store(_ backing: InMemoryCredentialBacking, lock: URL, timeout: TimeInterval = 5) -> KeychainCredentialStore {
        KeychainCredentialStore(service: "test.\(UUID().uuidString)", backing: backing, lockURL: lock, lockTimeout: timeout)
    }

    /// holdLock takes the lock file the way another process would: its own
    /// open file description, exclusive, until released.
    private func holdLock(_ url: URL) throws -> Int32 {
        let fd = open(url.path, O_RDWR | O_CREAT, 0o600)
        try #require(fd >= 0)
        try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
        return fd
    }

    private func release(_ fd: Int32) {
        flock(fd, LOCK_UN)
        close(fd)
    }

    fileprivate enum Mutation: String, CaseIterable, Sendable {
        case removeRawKeys, setString, setStrings, removeAll

        func apply(to store: KeychainCredentialStore) throws {
            switch self {
            case .removeRawKeys: try store.removeRawKeys(["authority_key"])
            case .setString: try store.setString("a@example.com", for: .librelinkupEmail)
            case .setStrings: try store.setStrings([.librelinkupEmail: "a@example.com", .librelinkupPassword: "pw-a"])
            case .removeAll: try store.removeAll([.storeKey])
            }
        }

        func expectedChange(in items: [String: String]) -> Bool {
            switch self {
            case .removeRawKeys: items["authority_key"] == nil
            case .setString: items["librelinkup_email"] == "a@example.com"
            case .setStrings: items["librelinkup_email"] == "a@example.com" && items["librelinkup_password"] == "pw-a"
            case .removeAll: items["store_key"] == nil
            }
        }
    }

    @Test("a mutation by one copy never undoes another copy's earlier change, whatever the mutation", arguments: Mutation.allCases)
    fileprivate func staleCacheCannotUndoAnotherCopy(mutation: Mutation) throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let lock = dir.appendingPathComponent("credentials.lock")
        let backing = InMemoryCredentialBacking(items: ["store_key": "sk", "authority_key": "old"])
        let a = store(backing, lock: lock)
        let b = store(backing, lock: lock)

        #expect(try a.string(for: .token) == nil)  // A now holds the item in its cache
        try b.setString("token-b", for: .token)
        try mutation.apply(to: a)

        let items = try #require(backing.items)
        #expect(items["token"] == "token-b")
        #expect(mutation.expectedChange(in: items))
        #expect(try a.string(for: .token) == "token-b")
    }

    @Test("two copies bootstrapping one after the other agree on one token and one store key, the first writer's")
    func firstRunRaceKeepsFirstWriter() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let lock = dir.appendingPathComponent("credentials.lock")
        let backing = InMemoryCredentialBacking()
        let a = store(backing, lock: lock)
        let b = store(backing, lock: lock)
        #expect(try a.string(for: .token) == nil)  // A read the empty item before B ran

        try CredentialsBootstrapper(store: b, randomBytes: ConstantByteGenerator(byte: 2)).ensureBootstrapped()
        try CredentialsBootstrapper(store: a, randomBytes: ConstantByteGenerator(byte: 1)).ensureBootstrapped()

        let bytes = Data(repeating: 2, count: CredentialsBootstrapper.keySizeBytes)
        let token = bytes.base64URLEncodedStringWithoutPadding()
        let storeKey = bytes.base64EncodedString()
        #expect(try a.string(for: .token) == token)
        #expect(try b.string(for: .token) == token)
        #expect(try a.string(for: .storeKey) == storeKey)
        #expect(try b.string(for: .storeKey) == storeKey)
        #expect(backing.items == ["token": token, "store_key": storeKey])
    }

    @Test("addMissing writes only absent keys and returns what is stored for every key given")
    func addMissingKeepsExisting() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backing = InMemoryCredentialBacking(items: ["token": "existing"])
        let kc = store(backing, lock: dir.appendingPathComponent("credentials.lock"))
        let fake = FakeCredentialStore(values: [.token: "existing"])

        for target in [kc as any CredentialStore, fake as any CredentialStore] {
            let stored = try target.addMissing([.token: "new-token", .storeKey: "new-key"])
            #expect(stored == [.token: "existing", .storeKey: "new-key"])
            #expect(try target.string(for: .token) == "existing")
            #expect(try target.string(for: .storeKey) == "new-key")
        }
        #expect(backing.items == ["token": "existing", "store_key": "new-key"])
    }

    @Test("a mutation times out with lockTimeout while the lock is held, writes nothing, and succeeds once it is released")
    func lockTimeout() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let lock = dir.appendingPathComponent("credentials.lock")
        let backing = InMemoryCredentialBacking(items: ["store_key": "sk"])
        let kc = store(backing, lock: lock, timeout: 0.2)
        let fd = try holdLock(lock)

        #expect(throws: KeychainError.lockTimeout) { try kc.setString("t", for: .token) }
        #expect(throws: KeychainError.lockTimeout) { try kc.removeRawKeys(["store_key"]) }
        #expect(throws: KeychainError.lockTimeout) { _ = try kc.addMissing([.token: "t"]) }
        #expect(backing.items == ["store_key": "sk"])

        release(fd)
        try kc.setString("t", for: .token)
        #expect(backing.items == ["store_key": "sk", "token": "t"])
    }

    @Test("a lock held by another process is released when that process exits on end of input")
    func lockReleasedWhenHolderExitsOnEndOfInput() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let lock = dir.appendingPathComponent("credentials.lock")
        let backing = InMemoryCredentialBacking(items: [:])
        let kc = store(backing, lock: lock, timeout: 0.2)

        // The child takes the lock, reports it, then blocks reading stdin and
        // exits when stdin reaches end of file: no signal is ever sent.
        let child = try TestChild(
            executable: "/usr/bin/python3",
            arguments: [
                "-I", "-c",
                "import fcntl,sys\nf=open(sys.argv[1],'a')\nfcntl.flock(f,fcntl.LOCK_EX)\nprint('locked',flush=True)\nsys.stdin.read()",
                lock.path,
            ]
        )
        defer { child.endRecordingUnknown() }

        // Wait for the child's own report that it holds the lock, up to the hang bound.
        var pollFD = pollfd(fd: child.standardOutput.fileDescriptor, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pollFD, 1, TestChild.hangCeilingMilliseconds)
        try #require(ready > 0, "child did not report holding the lock within \(TestChild.hangCeilingMilliseconds) ms")
        let line = child.standardOutput.availableData
        try #require(String(decoding: line, as: UTF8.self).hasPrefix("locked"))

        #expect(throws: KeychainError.lockTimeout) { try kc.setString("t", for: .token) }
        #expect(backing.items == [:])

        let outcome = child.end()
        try #require(outcome == .ended, "holder did not end: \(outcome)")

        try kc.setString("t", for: .token)
        #expect(backing.items == ["token": "t"])
    }
}

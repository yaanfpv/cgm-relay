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

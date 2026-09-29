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
}

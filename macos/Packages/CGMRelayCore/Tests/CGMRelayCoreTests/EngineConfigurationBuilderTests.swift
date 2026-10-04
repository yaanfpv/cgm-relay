import Foundation
import Testing
@testable import CGMRelayCore

@Suite("EngineConfigurationBuilder")
struct EngineConfigurationBuilderTests {
    @Test("builds a configuration once every credential is present")
    func buildsWhenComplete() throws {
        let store = FakeCredentialStore(values: [
            .librelinkupEmail: "person@example.invalid",
            .librelinkupPassword: "not-a-real-password",
            .token: "a-token",
            .storeKey: "a-key",
        ])

        let config = try EngineConfigurationBuilder.build(
            from: store,
            listenAddr: "127.0.0.1:1337",
            statusAddr: "127.0.0.1:1338",
            databasePath: "/tmp/readings.db",
            retentionDays: 15
        )

        #expect(config != nil)
        #expect(config?.librelinkupEmail == "person@example.invalid")
        #expect(config?.token == "a-token")
        #expect(config?.key == "a-key")
    }

    @Test("passes librelinkupBaseURL through when given, and leaves it nil when not")
    func passesLibrelinkupBaseURLThrough() throws {
        let store = FakeCredentialStore(values: [
            .librelinkupEmail: "person@example.invalid",
            .librelinkupPassword: "not-a-real-password",
            .token: "a-token",
            .storeKey: "a-key",
        ])

        let withoutOverride = try EngineConfigurationBuilder.build(
            from: store,
            listenAddr: "127.0.0.1:1337",
            statusAddr: "127.0.0.1:1338",
            databasePath: "/tmp/readings.db",
            retentionDays: 15
        )
        #expect(withoutOverride?.librelinkupBaseURL == nil)

        let withOverride = try EngineConfigurationBuilder.build(
            from: store,
            listenAddr: "127.0.0.1:1337",
            statusAddr: "127.0.0.1:1338",
            databasePath: "/tmp/readings.db",
            retentionDays: 15,
            librelinkupBaseURL: "http://127.0.0.1:9999"
        )
        #expect(withOverride?.librelinkupBaseURL == "http://127.0.0.1:9999")
    }

    @Test("refuses to build without an email or a password, which the engine is never started without")
    func nilWhenAccountMissing() throws {
        let store = FakeCredentialStore(values: [
            .token: "a-token",
            .storeKey: "a-key",
        ])

        let config = try EngineConfigurationBuilder.build(
            from: store,
            listenAddr: "127.0.0.1:1337",
            statusAddr: "127.0.0.1:1338",
            databasePath: "/tmp/readings.db",
            retentionDays: 15
        )

        #expect(config == nil)
    }

    @Test("refuses to build before the token and key have been generated")
    func nilBeforeBootstrapped() throws {
        let store = FakeCredentialStore(values: [
            .librelinkupEmail: "person@example.invalid",
            .librelinkupPassword: "not-a-real-password",
        ])

        let config = try EngineConfigurationBuilder.build(
            from: store,
            listenAddr: "127.0.0.1:1337",
            statusAddr: "127.0.0.1:1338",
            databasePath: "/tmp/readings.db",
            retentionDays: 15
        )

        #expect(config == nil)
    }

    @Test("passes the launch's status secret through into the stdin JSON, and omits the field without one")
    func carriesStatusSecretIntoStandardInput() throws {
        let store = FakeCredentialStore(values: [
            .librelinkupEmail: "person@example.invalid",
            .librelinkupPassword: "not-a-real-password",
            .token: "a-token",
            .storeKey: "a-key",
        ])

        let withSecret = try EngineConfigurationBuilder.build(
            from: store,
            listenAddr: "127.0.0.1:1337",
            statusAddr: "127.0.0.1:1338",
            databasePath: "/tmp/readings.db",
            retentionDays: 15,
            statusSecret: "a-launch-secret"
        )
        let sentData = try #require(withSecret).encodedForStandardInput()
        let sent = try #require(JSONSerialization.jsonObject(with: sentData) as? [String: Any])
        #expect(sent["status_secret"] as? String == "a-launch-secret")

        let withoutSecret = try EngineConfigurationBuilder.build(
            from: store,
            listenAddr: "127.0.0.1:1337",
            statusAddr: "127.0.0.1:1338",
            databasePath: "/tmp/readings.db",
            retentionDays: 15
        )
        let unsentData = try #require(withoutSecret).encodedForStandardInput()
        let unsent = try #require(JSONSerialization.jsonObject(with: unsentData) as? [String: Any])
        #expect(unsent["status_secret"] == nil)
    }

    @Test("each renewal makes a new 32-byte URL-safe secret and replaces the last, and a failed one leaves none")
    func renewMakesAFreshSecret() throws {
        let secret = LocalStatusSecret(randomBytes: FakeRandomBytesGenerator())
        #expect(secret.current == nil)

        let first = try secret.renew()
        #expect(secret.current == first)
        #expect(Data(base64Encoded: first.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=")?.count == 32)

        let real = LocalStatusSecret()
        let a = try real.renew()
        let b = try real.renew()
        #expect(a != b)
        #expect(real.current == b)

        struct Failing: RandomBytesGenerating {
            func randomBytes(count: Int) throws -> Data { throw RandomBytesError.generationFailed(-1) }
        }
        let failing = LocalStatusSecret(randomBytes: Failing())
        #expect(throws: RandomBytesError.self) { try failing.renew() }
        #expect(failing.current == nil)
    }
}

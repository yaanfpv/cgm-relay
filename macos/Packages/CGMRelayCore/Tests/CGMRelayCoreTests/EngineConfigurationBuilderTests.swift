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

    @Test("withStatusSecret sets the stdin JSON's status_secret and leaves every other field alone, and no secret omits the field")
    func carriesStatusSecretIntoStandardInput() throws {
        let base = EngineConfiguration.fixture()

        let withSecret = base.withStatusSecret("a-process-secret")
        let sent = try #require(JSONSerialization.jsonObject(with: withSecret.encodedForStandardInput()) as? [String: Any])
        #expect(sent["status_secret"] as? String == "a-process-secret")
        #expect(withSecret.withStatusSecret(nil) == base)

        let unsent = try #require(JSONSerialization.jsonObject(with: base.encodedForStandardInput()) as? [String: Any])
        #expect(unsent["status_secret"] == nil)
    }

    @Test("the LAN listener fields reach stdin only when there is a listener, with the key among them")
    func lanFieldsAreEncodedOnlyWhenNonEmpty() throws {
        let base = EngineConfiguration.fixture()
        let plain = try #require(JSONSerialization.jsonObject(with: base.encodedForStandardInput()) as? [String: Any])
        #expect(plain["lan_listen_addrs"] == nil && plain["tls_cert_pem"] == nil && plain["tls_key_pem"] == nil)

        let withListener = EngineConfiguration(
            librelinkupEmail: base.librelinkupEmail, librelinkupPassword: base.librelinkupPassword, token: base.token,
            listenAddr: base.listenAddr, statusAddr: base.statusAddr, databasePath: base.databasePath,
            retentionDays: base.retentionDays, key: base.key,
            lanListenAddrs: ["192.168.1.42:1337"], tlsCertPEM: "CERT", tlsKeyPEM: "KEY"
        )
        let sent = try #require(JSONSerialization.jsonObject(with: withListener.encodedForStandardInput()) as? [String: Any])
        #expect(sent["lan_listen_addrs"] as? [String] == ["192.168.1.42:1337"])
        #expect(sent["tls_cert_pem"] as? String == "CERT")
        #expect(sent["tls_key_pem"] as? String == "KEY")

        let empty = EngineConfiguration(
            librelinkupEmail: base.librelinkupEmail, librelinkupPassword: base.librelinkupPassword, token: base.token,
            listenAddr: base.listenAddr, statusAddr: base.statusAddr, databasePath: base.databasePath,
            retentionDays: base.retentionDays, key: base.key,
            lanListenAddrs: [], tlsCertPEM: "CERT", tlsKeyPEM: "KEY"
        )
        let none = try #require(JSONSerialization.jsonObject(with: empty.encodedForStandardInput()) as? [String: Any])
        #expect(none["lan_listen_addrs"] == nil && none["tls_cert_pem"] == nil && none["tls_key_pem"] == nil, "a certificate with no listener is never sent")
    }

    @Test("each renewal makes a new 32-byte URL-safe secret that stays unusable until armed, arming ignores any other value, and clear forgets it")
    func secretLifecycle() throws {
        let secret = LocalStatusSecret(randomBytes: FakeRandomBytesGenerator())
        var request = URLRequest(url: URL(string: "http://127.0.0.1:1/status")!)
        #expect(!secret.isArmed)
        #expect(!secret.authorize(&request))

        let first = try secret.renew()
        #expect(Data(base64Encoded: first.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=")?.count == 32)
        #expect(!secret.isArmed)
        #expect(!secret.authorize(&request))
        #expect(request.value(forHTTPHeaderField: LocalStatusSecret.headerName) == nil, "a pending secret is never presented")

        secret.arm("not-the-pending-secret")
        #expect(!secret.isArmed, "a stale arm from an older engine process is ignored")

        secret.arm(first)
        #expect(secret.authorize(&request))
        #expect(request.value(forHTTPHeaderField: LocalStatusSecret.headerName) == first)

        let real = LocalStatusSecret()
        let a = try real.renew()
        real.arm(a)
        let b = try real.renew()
        #expect(a != b)
        #expect(!real.isArmed, "a renewal discards the armed secret")
        real.arm(a)
        #expect(!real.isArmed, "the replaced secret can never be armed again")

        secret.clear()
        #expect(!secret.isArmed)
        var cleared = URLRequest(url: request.url!)
        #expect(!secret.authorize(&cleared))
    }

    @Test("a failed renewal leaves no secret")
    func failedRenewalLeavesNone() throws {
        final class FailsOnSecondCall: RandomBytesGenerating, @unchecked Sendable {
            private var calls = 0
            func randomBytes(count: Int) throws -> Data {
                calls += 1
                if calls > 1 { throw RandomBytesError.generationFailed(-1) }
                return Data(repeating: 1, count: count)
            }
        }
        let secret = LocalStatusSecret(randomBytes: FailsOnSecondCall())
        secret.arm(try secret.renew())
        #expect(secret.isArmed)

        #expect(throws: RandomBytesError.self) { try secret.renew() }
        #expect(!secret.isArmed)
    }
}

import Testing
import Foundation
@testable import CGMRelayCore

@Suite("DiagnosticsReport")
struct DiagnosticsReportTests {
    @Test("names the engine's own failure reason in plain words when it has one")
    func namesFailureReason() {
        let report = DiagnosticsReport.build(
            appVersion: "0.1.0",
            buildNumber: "1",
            macOSVersion: "15.0",
            engineState: .failed(.storeKeyMismatch),
            lastError: nil,
            reach: .thisMacOnly,
            port: 1337,
            retentionDays: 15,
            units: .mgDl,
            noReadingAlertEnabled: false,
            noReadingAlertMinutes: 20,
            signInFailingAlertEnabled: false,
            followerAges: []
        )
        #expect(report.contains("failed"))
        #expect(report.contains("saved readings can't be opened"))
    }

    @Test("lists no followers when none have polled")
    func noFollowersListedWhenEmpty() {
        let report = DiagnosticsReport.build(
            appVersion: "0.1.0",
            buildNumber: "1",
            macOSVersion: "15.0",
            engineState: .running,
            lastError: nil,
            reach: .thisMacOnly,
            port: 1337,
            retentionDays: 15,
            units: .mgDl,
            noReadingAlertEnabled: false,
            noReadingAlertMinutes: 20,
            signInFailingAlertEnabled: false,
            followerAges: []
        )
        #expect(report.contains("none yet"))
    }

    /// bodies are the base64 of each PEM block's key material, the text a
    /// leak of that key would carry in any of its PEM forms.
    private static func bodies(of pem: String) -> [String] {
        [pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()]
    }

    @Test("neither the leaf key nor the authority key reaches the diagnostics, the saved settings or the menu, and the key travels only in the engine's stdin")
    func certificateKeysStayOutOfEverythingShown() throws {
        let store = FakeCredentialStore(values: [
            .librelinkupEmail: "person@example.invalid",
            .librelinkupPassword: "not-a-real-password",
            .token: "a-token",
            .storeKey: "a-key",
        ])
        var settings = AppSettings.default
        settings.reach = .myLocalNetwork
        let start = try #require(try SettingsEngineConfigurationBuilder.start(
            settings: settings, from: store,
            interfaces: [NetworkInterfaceAddress(name: "en0", address: "192.168.1.42")],
            statusAddr: "127.0.0.1:1338", databasePath: "/tmp/readings.db", hostName: "relay-mac.local"
        ))
        let leafKey = try #require(start.configuration.tlsKeyPEM)
        let authorityKey = try #require(store.snapshot()[.authorityKey])
        #expect(leafKey != authorityKey)
        let needles = Self.bodies(of: leafKey) + Self.bodies(of: authorityKey) + ["PRIVATE KEY"]

        let report = DiagnosticsReport.build(
            appVersion: "0.1.0", buildNumber: "1", macOSVersion: "15.0",
            engineState: .running, lastError: nil, reach: settings.effectiveReach, port: settings.port,
            retentionDays: settings.retentionDays, units: settings.units,
            noReadingAlertEnabled: false, noReadingAlertMinutes: 20, signInFailingAlertEnabled: false,
            followerAges: [(client: "xDrip4iOS", age: "just now")]
        )
        let savedSettings = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        let menu = String(describing: MenuDisplayState.make(
            credentialsConfigured: true, engineState: .running, status: nil, now: Date(),
            certificateNotice: AppSettings.authorityReplacedNotice(.madeForAnotherName)
        ))
        let shown = String(describing: [report, savedSettings, menu, String(describing: start.plan), String(describing: start.authorityChange)])

        // The search finds a key where one is.
        #expect(needles.contains { (shown + leafKey).contains($0) })
        for needle in needles {
            #expect(!shown.contains(needle), "a certificate key reached something shown or saved")
        }

        let sent = try #require(JSONSerialization.jsonObject(with: start.configuration.encodedForStandardInput()) as? [String: Any])
        #expect(sent["tls_key_pem"] as? String == leafKey)
        #expect(!String(describing: sent.filter { $0.key != "tls_key_pem" }).contains(Self.bodies(of: authorityKey)[0]), "the authority key never goes to the engine")
    }
}

import Testing
import Foundation
@testable import CGMRelayCore

@Suite("AppSettings")
struct AppSettingsTests {
    @Test("decoding JSON missing one field keeps every other field, falling back to that field's own default")
    func missingFieldKeepsOthersAndFallsBackForItself() throws {
        let json = """
        {
          "port": 4000,
          "reach": "myLocalNetwork",
          "retentionDays": 30,
          "units": "mmolL",
          "noReadingAlertMinutes": 45,
          "signInFailingAlertEnabled": true
        }
        """
        // noReadingAlertEnabled is missing entirely, exactly as a field
        // added in a later version would be missing from a JSON blob
        // saved by an earlier one.
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        #expect(decoded.port == 4000)
        #expect(decoded.reach == .myLocalNetwork)
        #expect(decoded.retentionDays == 30)
        #expect(decoded.units == .mmolL)
        #expect(decoded.noReadingAlertMinutes == 45)
        #expect(decoded.signInFailingAlertEnabled == true)
        #expect(decoded.noReadingAlertEnabled == AppSettings.default.noReadingAlertEnabled, "the missing field must fall back to its own default rather than resetting the whole struct")
    }

    @Test("an empty JSON object decodes to every field's own default")
    func emptyObjectDecodesToDefaults() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(decoded == AppSettings.default)
    }

    @Test("a value round-trips through encode and decode unchanged")
    func roundTrips() throws {
        let original = AppSettings(
            port: 5001, reach: .myTailnet, retentionDays: 7, units: .mmolL,
            noReadingAlertEnabled: true, noReadingAlertMinutes: 30, signInFailingAlertEnabled: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded == original)
    }

    @Test("Tailscale HTTPS on binds this Mac only whatever reach was chosen; off leaves the chosen reach")
    func effectiveReachFollowsTailscaleHTTPS() {
        var settings = AppSettings.default
        settings.reach = .myLocalNetwork
        #expect(settings.effectiveReach == .myLocalNetwork)
        settings.tailscaleHTTPSEnabled = true
        #expect(settings.effectiveReach == .thisMacOnly)
        #expect(settings.reach == .myLocalNetwork, "the earlier choice comes back when HTTPS is turned off")
    }

    @Test("setup and Tailscale HTTPS default off and survive a round trip")
    func setupFieldsRoundTrip() throws {
        #expect(AppSettings.default.setupFinished == false)
        #expect(AppSettings.default.tailscaleHTTPSEnabled == false)
        var settings = AppSettings.default
        settings.setupFinished = true
        settings.tailscaleHTTPSEnabled = true
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }

    @Test("the reading in the menu bar is off by default, absent from an older settings file, and survives a round trip")
    func showReadingInMenuBar() throws {
        #expect(AppSettings.default.showReadingInMenuBar == false)
        let older = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"port": 4000, "setupFinished": true}"#.utf8))
        #expect(older.showReadingInMenuBar == false)
        #expect(older.port == 4000, "an older file keeps every other field")
        var settings = AppSettings.default
        settings.showReadingInMenuBar = true
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.showReadingInMenuBar == true)
    }

    @Test("the chosen follower app defaults to xDrip4iOS, is absent from an older settings file, and survives a round trip")
    func connectFollowerApp() throws {
        #expect(AppSettings.default.connectFollowerApp == .xDrip4iOS)
        let older = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"port": 4000}"#.utf8))
        #expect(older.connectFollowerApp == .xDrip4iOS)
        let unknown = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"port": 4000, "connectFollowerApp": "someNewerApp"}"#.utf8))
        #expect(unknown.connectFollowerApp == .xDrip4iOS)
        #expect(unknown.port == 4000, "an unknown follower app keeps every other field")
        var settings = AppSettings.default
        settings.connectFollowerApp = .loopFollow
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.connectFollowerApp == .loopFollow)
    }
}

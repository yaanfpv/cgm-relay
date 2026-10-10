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

    @Test("the default follower port and status address are the build configuration's own pair")
    func defaultsFollowTheBuildConfiguration() {
        #if DEBUG
        #expect(AppSettings.default.port == 1347)
        #expect(AppSettings.defaultPort == 1347)
        #expect(RelayDefaults.statusAddr == "127.0.0.1:1348")
        #else
        #expect(AppSettings.default.port == 1337)
        #expect(AppSettings.defaultPort == 1337)
        #expect(RelayDefaults.statusAddr == "127.0.0.1:1338")
        #endif
    }

    @Test("a saved port is honoured exactly, whatever the default is")
    func savedPortWinsOverDefault() throws {
        for saved in [1337, 1347, 5001] {
            var settings = AppSettings.default
            settings.port = saved
            let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            #expect(decoded.port == saved)
        }
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

    @Test("the certificate step flag is off for a fresh or older saved value, and survives a round trip")
    func certificateStepFlag() throws {
        #expect(AppSettings.default.localCertificateStepFinished == false)
        let older = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"port": 4000, "reach": "myLocalNetwork", "setupFinished": true}"#.utf8))
        #expect(older.localCertificateStepFinished == false)
        #expect(older.port == 4000 && older.setupFinished, "the other fields are kept")
        var settings = AppSettings.default
        settings.localCertificateStepFinished = true
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.localCertificateStepFinished)
    }

    @Test("a fresh install shows the reading in the menu bar and keeps 30 days")
    func freshInstallDefaults() throws {
        #expect(AppSettings.default.showReadingInMenuBar == true)
        #expect(AppSettings.default.retentionDays == 30)
        let fresh = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(fresh.showReadingInMenuBar == true)
        #expect(fresh.retentionDays == 30)
    }

    @Test("explicitly saved menu bar and retention choices are kept, including off and 15 days")
    func explicitSavedChoicesSurvive() throws {
        var settings = AppSettings.default
        settings.showReadingInMenuBar = false
        settings.retentionDays = 15
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.showReadingInMenuBar == false)
        #expect(decoded.retentionDays == 15)
        let handWritten = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"showReadingInMenuBar": false, "retentionDays": 15}"#.utf8))
        #expect(handWritten.showReadingInMenuBar == false)
        #expect(handWritten.retentionDays == 15)
    }

    @Test("an older settings file takes the new defaults only for the keys it never saved")
    func legacyMissingKeysTakeNewDefaults() throws {
        let noMenuBarKey = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"port": 4000, "retentionDays": 15, "setupFinished": true}"#.utf8))
        #expect(noMenuBarKey.showReadingInMenuBar == true)
        #expect(noMenuBarKey.retentionDays == 15, "a saved retention is not replaced")
        #expect(noMenuBarKey.port == 4000, "an older file keeps every other field")
        let noRetentionKey = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"showReadingInMenuBar": false}"#.utf8))
        #expect(noRetentionKey.retentionDays == 30)
        #expect(noRetentionKey.showReadingInMenuBar == false, "a saved off is not replaced")
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

    @Test("the safety notice is asked until its current wording is accepted, then asked again only if the wording changes")
    func safetyNoticeAcceptance() throws {
        #expect(AppSettings.default.safetyNoticeAcceptance == nil)
        #expect(SafetyNotice.needsAcceptance(nil))
        var settings = AppSettings.default
        settings.safetyNoticeAcceptance = SafetyNotice.acceptance(appVersion: "1.0.0")
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.safetyNoticeAcceptance?.appVersion == "1.0.0")
        #expect(!SafetyNotice.needsAcceptance(decoded.safetyNoticeAcceptance))
        let otherVersionOfApp = SafetyNoticeAcceptance(noticeVersion: SafetyNotice.version, appVersion: "2.0.0")
        #expect(!SafetyNotice.needsAcceptance(otherVersionOfApp), "a new app version alone does not ask again")
        let oldWording = SafetyNoticeAcceptance(noticeVersion: "an older wording", appVersion: "1.0.0")
        #expect(SafetyNotice.needsAcceptance(oldWording))
        let older = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"port": 4000}"#.utf8))
        #expect(older.safetyNoticeAcceptance == nil)
    }
}

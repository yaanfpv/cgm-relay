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
}

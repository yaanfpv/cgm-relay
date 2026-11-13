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
        #expect(decoded.reach == .thisMacOnly)
        #expect(decoded.movedFromLocalRoute == true)
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
        settings.reach = .myTailnet
        #expect(settings.effectiveReach == .myTailnet)
        settings.tailscaleHTTPSEnabled = true
        #expect(settings.effectiveReach == .thisMacOnly)
        #expect(settings.reach == .myTailnet, "the earlier choice comes back when HTTPS is turned off")
    }

    @Test("settings saved before Tailscale HTTPS was one of the ways load unchanged: true reads as Tailscale HTTPS chosen, false as the saved reach")
    func savedChoiceReadsAsTheSameWay() throws {
        let on = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"reach":"myTailnet","tailscaleHTTPSEnabled":true}"#.utf8))
        #expect(on.chosenWay == .tailscaleHTTPS)
        #expect(on.reach == .myTailnet)
        let off = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"reach":"myTailnet","tailscaleHTTPSEnabled":false}"#.utf8))
        #expect(off.chosenWay == .myTailnet)
        #expect(AppSettings.default.chosenWay == .thisMacOnly)
    }

    @Test("choosing any way from any other changes only the choice, and the relay binds as that way implies", arguments: ReachWay.allCases)
    func choosingAWay(_ way: ReachWay) {
        for start in ReachWay.allCases {
            var settings = AppSettings.default.choosing(start)
            settings.port = 5001
            settings.setupFinished = true
            let next = settings.choosing(way)
            #expect(next.chosenWay == way, "from \(start) to \(way)")
            var expected = settings
            expected.tailscaleHTTPSEnabled = way == .tailscaleHTTPS
            switch way {
            case .tailscaleHTTPS:
                #expect(next.effectiveReach == .thisMacOnly, "Tailscale does the reaching, so the relay stays on this Mac")
            case .thisMacOnly:
                expected.reach = .thisMacOnly
                #expect(next.effectiveReach == .thisMacOnly)
            case .myTailnet:
                expected.reach = .myTailnet
                #expect(next.effectiveReach == .myTailnet)
            }
            #expect(next == expected, "only the choice changes, from \(start) to \(way)")
        }
    }

    @Test("the last confirmed handler state is absent from an older settings file, survives a round trip, and an unknown value reads as nothing observed")
    func lastHandlerObservation() throws {
        #expect(AppSettings.default.lastHandlerObservation == nil)
        let older = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"port": 4000, "tailscaleHTTPSEnabled": true}"#.utf8))
        #expect(older.lastHandlerObservation == nil)
        #expect(older.tailscaleHTTPSEnabled && older.port == 4000, "the other fields are kept")
        for seen in [HandlerObservation.serving, .notServing] {
            var settings = AppSettings.default
            settings.lastHandlerObservation = seen
            let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            #expect(decoded.lastHandlerObservation == seen)
        }
        let unknown = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"port": 4000, "lastHandlerObservation": "someNewerState"}"#.utf8))
        #expect(unknown.lastHandlerObservation == nil)
        #expect(unknown.port == 4000)
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

    // MARK: - settings that outlive a removed choice

    /// A settings value shaped like the one 1.0.2 wrote, with the given
    /// reach and no setupVersion, movedFromLocalRoute or stayAwake key.
    private func legacyJSON(reach: String) -> String {
        """
        {
          "port": 4242,
          "reach": "\(reach)",
          "retentionDays": 45,
          "units": "mmolL",
          "noReadingAlertEnabled": true,
          "noReadingAlertMinutes": 45,
          "signInFailingAlertEnabled": true,
          "tailscaleHTTPSEnabled": false,
          "setupFinished": true,
          "showReadingInMenuBar": false,
          "connectFollowerApp": "xDrip4iOS",
          "localCertificateStepFinished": true
        }
        """
    }

    private func expectSavedFieldsKept(_ s: AppSettings) {
        #expect(s.port == 4242)
        #expect(s.retentionDays == 45)
        #expect(s.units == .mmolL)
        #expect(s.noReadingAlertEnabled == true)
        #expect(s.noReadingAlertMinutes == 45)
        #expect(s.signInFailingAlertEnabled == true)
        #expect(s.setupFinished == true)
        #expect(s.showReadingInMenuBar == false)
    }

    /// load() on a throwaway suite holding the given settings JSON.
    private func loadFromThrowawaySuite(_ json: String) -> AppSettings {
        let suite = "cgmrelay.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(json.utf8), forKey: "com.yaanfpv.cgmrelay.settings")
        return UserDefaultsSettingsStore(suiteName: suite).load()
    }

    @Test("a stored reach of the removed local-network choice becomes this-Mac-only, notes the move, and keeps every other field")
    func legacyLocalReachIsMovedNotReset() throws {
        let json = legacyJSON(reach: "myLocalNetwork")
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(decoded.reach == .thisMacOnly)
        #expect(decoded.movedFromLocalRoute == true)
        expectSavedFieldsKept(decoded)

        let loaded = loadFromThrowawaySuite(json)
        #expect(loaded != AppSettings.default, "load() must not fall back to the defaults")
        #expect(loaded.reach == .thisMacOnly)
        #expect(loaded.movedFromLocalRoute == true)
        expectSavedFieldsKept(loaded)
    }

    @Test("a legacy local reach under Tailscale HTTPS is not a move: the person was on Tailscale")
    func legacyLocalReachUnderTailscaleHTTPSIsNotAMove() throws {
        let json = legacyJSON(reach: "myLocalNetwork")
            .replacingOccurrences(of: #""tailscaleHTTPSEnabled": false"#, with: #""tailscaleHTTPSEnabled": true"#)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(decoded.tailscaleHTTPSEnabled == true)
        #expect(decoded.chosenWay == .tailscaleHTTPS)
        #expect(decoded.reach == .thisMacOnly)
        #expect(decoded.movedFromLocalRoute == false)
        #expect(decoded.port == 4242)
        #expect(decoded.retentionDays == 45)
        #expect(decoded.setupFinished == true)
    }

    @Test("any other unknown reach becomes this-Mac-only without the moved note, and keeps every other field")
    func unknownReachFallsBackQuietly() throws {
        let json = legacyJSON(reach: "somethingNew")
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(decoded.reach == .thisMacOnly)
        #expect(decoded.movedFromLocalRoute == false)
        expectSavedFieldsKept(decoded)

        let loaded = loadFromThrowawaySuite(json)
        #expect(loaded != AppSettings.default, "load() must not fall back to the defaults")
        #expect(loaded.reach == .thisMacOnly)
        #expect(loaded.movedFromLocalRoute == false)
        expectSavedFieldsKept(loaded)
    }

    @Test("a known reach is still honoured as stored")
    func knownReachStillHonoured() throws {
        for (raw, expected) in [("thisMacOnly", NetworkReach.thisMacOnly), ("myTailnet", .myTailnet)] {
            let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacyJSON(reach: raw).utf8))
            #expect(decoded.reach == expected)
            #expect(decoded.movedFromLocalRoute == false)
        }
    }

    @Test("setupVersion reads 0 for a fresh install, 1 for a 1.0.x install, and a stored value as stored")
    func setupVersionDecoding() throws {
        #expect(AppSettings.currentSetupVersion == 2)
        let fresh = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"port": 4000, "setupFinished": false}"#.utf8))
        #expect(fresh.setupVersion == 0)
        let noKeys = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(noKeys.setupVersion == 0)
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"port": 4000, "setupFinished": true}"#.utf8))
        #expect(legacy.setupVersion == 1)
        #expect(AppSettings.default.setupVersion == 0)
        for stored in [0, 1, 2, 7] {
            let json = #"{"setupFinished": true, "setupVersion": \#(stored)}"#
            let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
            #expect(decoded.setupVersion == stored)
        }
        let storedWhileUnfinished = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"setupFinished": false, "setupVersion": 2}"#.utf8))
        #expect(storedWhileUnfinished.setupVersion == 2)
    }

    @Test("finishingSetup marks setup finished at the current version and changes nothing else")
    func finishingSetupChangesOnlyTwoFields() {
        var base = AppSettings.default
        base.port = 4242
        base.retentionDays = 45
        base.units = .mmolL
        base.noReadingAlertEnabled = true
        base.stayAwake = .on
        base.movedFromLocalRoute = true
        let finished = base.finishingSetup()
        #expect(finished.setupFinished == true)
        #expect(finished.setupVersion == AppSettings.currentSetupVersion)

        var expected = base
        expected.setupFinished = true
        expected.setupVersion = AppSettings.currentSetupVersion
        #expect(finished == expected)

        var legacy = AppSettings.default
        legacy.setupFinished = true
        legacy.setupVersion = 1
        #expect(legacy.finishingSetup().setupVersion == AppSettings.currentSetupVersion)
    }

    @Test("setupVersion survives an encode and decode round trip")
    func setupVersionRoundTrip() throws {
        for version in [0, 1, 2] {
            var settings = AppSettings.default
            settings.setupFinished = version > 0
            settings.setupVersion = version
            let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            #expect(decoded.setupVersion == version)
        }
        let finished = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings.default.finishingSetup()))
        #expect(finished.setupVersion == AppSettings.currentSetupVersion)
    }

    @Test("stayAwake is nil until asked, decodes on and off, and an unknown value reads as nil without failing the decode")
    func stayAwakeDecoding() throws {
        #expect(AppSettings.default.stayAwake == nil)
        let missing = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"port": 4000}"#.utf8))
        #expect(missing.stayAwake == nil)
        let on = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"port": 4000, "stayAwake": "on"}"#.utf8))
        #expect(on.stayAwake == .on)
        let off = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"port": 4000, "stayAwake": "off"}"#.utf8))
        #expect(off.stayAwake == StayAwakeChoice.off)
        let unknown = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"port": 4000, "retentionDays": 45, "stayAwake": "always"}"#.utf8))
        #expect(unknown.stayAwake == nil)
        #expect(unknown.port == 4000, "an unknown stayAwake keeps every other field")
        #expect(unknown.retentionDays == 45)
    }

    @Test("stayAwake survives an encode and decode round trip, including nil")
    func stayAwakeRoundTrip() throws {
        for choice in [StayAwakeChoice?.none, .on, .off] {
            var settings = AppSettings.default
            settings.stayAwake = choice
            let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            #expect(decoded.stayAwake == choice)
        }
    }

    @Test("movedFromLocalRoute defaults to false, survives a round trip, and a stored value without the key reads false")
    func movedFromLocalRouteRoundTrip() throws {
        #expect(AppSettings.default.movedFromLocalRoute == false)
        for flag in [true, false] {
            var settings = AppSettings.default
            settings.movedFromLocalRoute = flag
            let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            #expect(decoded.movedFromLocalRoute == flag)
        }
        let missing = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"port": 4000, "reach": "myTailnet"}"#.utf8))
        #expect(missing.movedFromLocalRoute == false)
        let stored = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"reach": "thisMacOnly", "movedFromLocalRoute": true}"#.utf8))
        #expect(stored.movedFromLocalRoute == true)
    }

    @Test("the reach choices offered are exactly the three kept ways and the two kept reaches, none of them a local network way")
    func reachChoicesHaveNoLocalNetworkWay() {
        #expect(Set(ReachWay.allCases) == [.tailscaleHTTPS, .thisMacOnly, .myTailnet])
        #expect(ReachWay.allCases.count == 3)
        #expect(Set(NetworkReach.allCases) == [.thisMacOnly, .myTailnet])
        #expect(NetworkReach.allCases.count == 2)
        #expect(Set(NetworkReach.allCases.map(\.rawValue)) == ["thisMacOnly", "myTailnet"])
    }

    @Test("settings stored by an earlier version with the certificate step finished and the local network reach still decode, keeping every other field")
    func olderSettingsWithCertificateFieldStillDecode() throws {
        let json = """
        {
          "port": 4000,
          "reach": "myLocalNetwork",
          "localCertificateStepFinished": true,
          "setupFinished": true,
          "retentionDays": 45,
          "units": "mmolL",
          "noReadingAlertMinutes": 50,
          "signInFailingAlertEnabled": true
        }
        """

        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        #expect(decoded.reach == .thisMacOnly)
        #expect(decoded.movedFromLocalRoute == true)
        #expect(decoded.port == 4000)
        #expect(decoded.setupFinished == true)
        #expect(decoded.retentionDays == 45)
        #expect(decoded.units == .mmolL)
        #expect(decoded.noReadingAlertMinutes == 50)
        #expect(decoded.signInFailingAlertEnabled == true)
    }
}

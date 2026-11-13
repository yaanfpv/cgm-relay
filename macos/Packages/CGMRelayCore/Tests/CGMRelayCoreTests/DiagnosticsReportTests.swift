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
}

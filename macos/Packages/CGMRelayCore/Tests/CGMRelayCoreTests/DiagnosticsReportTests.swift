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

    private func report(routeCounts: [String: Int]) -> String {
        DiagnosticsReport.build(
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
            followerAges: [],
            routeCounts: routeCounts
        )
    }

    @Test("includes the engine's counts of Tailscale log lines and of each failure class")
    func includesRouteCounts() {
        let text = report(routeCounts: ["ingress_denied": 417, "handshake": 29, "tls_failure": 3141])
        for expected in ["ingress_denied", "417", "handshake", "29", "tls_failure", "3141"] {
            #expect(text.contains(expected), Comment(rawValue: expected))
        }
    }

    @Test("a count under a name the engine does not define never reaches the report")
    func dropsUnknownCountNames() {
        let text = report(routeCounts: ["relay.example-tailnet.ts.net": 8675, "100.64.0.9": 309, "ingress_denied": 2])
        #expect(!text.contains("relay.example-tailnet"))
        #expect(!text.contains("100.64.0.9"))
        #expect(!text.contains("8675"))
        #expect(text.contains("ingress_denied"))
    }
}

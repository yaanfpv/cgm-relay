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

    private func report(routeCounts: [String: Int] = [:], routeErrorClass: String?) -> String {
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
            routeCounts: routeCounts,
            routeErrorClass: routeErrorClass
        )
    }

    @Test("a name that was not published is counted under its own name")
    func countsNamesNotPublished() {
        let text = report(routeCounts: ["name_not_published": 7])
        #expect(text.contains("name_not_published 7"))
    }

    @Test("a reconnect of the node's control connection is counted under its own name")
    func countsControlReconnects() {
        let text = report(routeCounts: ["control_reconnect": 5, "relay.example-tailnet.ts.net": 11])
        #expect(text.contains("control_reconnect 5"))
        #expect(!text.contains("relay.example-tailnet"))
    }

    @Test("a Tailscale error shows only as one of its three classes")
    func carriesOnlyTheErrorClass() {
        for cls in ["listen_failed", "https_disabled", "node_attribute_missing"] {
            #expect(report(routeErrorClass: cls).contains(cls), Comment(rawValue: cls))
        }
        #expect(!report(routeErrorClass: nil).lowercased().contains("tailscale error"))
    }

    @Test("a class that is really text, an address or a host never reaches the report")
    func dropsTextPassedAsAClass() {
        for leaked in [
            "Funnel not available; HTTPS must be enabled. See https://tailscale.com/s/https.",
            "listen tcp 100.64.0.9:443: bind: address already in use",
            "relay.example-tailnet.ts.net",
        ] {
            let text = report(routeErrorClass: leaked)
            #expect(!text.contains("Funnel not available"), Comment(rawValue: leaked))
            #expect(!text.contains("100.64.0.9"), Comment(rawValue: leaked))
            #expect(!text.contains("ts.net"), Comment(rawValue: leaked))
            #expect(!text.contains("bind"), Comment(rawValue: leaked))
        }
    }
}

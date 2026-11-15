import Testing
import Foundation
@testable import CGMRelayCore

// No existing test file covers BuiltInRouteState, so it gets its own.
@Suite("BuiltInRouteState")
struct BuiltInRouteStateTests {
    /// Builds a BuiltInStatus the way the app does, by decoding /status.
    private func route(_ fields: String) throws -> BuiltInRouteState {
        let json = #"{"running": true, "sign_in_failing": false, \#(fields)}"#
        let status = try JSONDecoder.engineStatusDecoder.decode(EngineStatus.self, from: Data(json.utf8))
        return BuiltInRouteState.from(status.builtIn)
    }

    @Test("no built-in status is starting")
    func nilIsStarting() {
        #expect(BuiltInRouteState.from(nil) == .starting)
    }

    @Test("starting maps to starting")
    func startingState() throws {
        #expect(try route(#""ts_state": "starting""#) == .starting)
    }

    @Test("needs-login with a Tailscale https URL is signIn")
    func signIn() throws {
        let got = try route(#""ts_state": "needs-login", "ts_login_url": "https://login.tailscale.com/a/abc123""#)
        #expect(got == .signIn(URL(string: "https://login.tailscale.com/a/abc123")!))
    }

    @Test("needs-approval is approve")
    func approve() throws {
        let got = try route(#""ts_state": "needs-approval", "ts_approve_url": "https://login.tailscale.com/admin/machines""#)
        #expect(got == .approve(URL(string: "https://login.tailscale.com/admin/machines")!))
    }

    @Test("needs-funnel with a URL is enableFunnel")
    func enableFunnel() throws {
        let got = try route(#""ts_state": "needs-funnel", "ts_funnel_url": "https://login.tailscale.com/f/funnel""#)
        #expect(got == .enableFunnel(URL(string: "https://login.tailscale.com/f/funnel")!))
    }

    @Test("setting-up with a host is settingUp")
    func settingUp() throws {
        let got = try route(#""ts_state": "setting-up", "ts_public_host": "relay.example-tailnet.ts.net""#)
        #expect(got == .settingUp(host: "relay.example-tailnet.ts.net"))
    }

    @Test("running with a host is ready")
    func ready() throws {
        let got = try route(#""ts_state": "running", "ts_public_host": "relay.example-tailnet.ts.net""#)
        #expect(got == .ready(host: "relay.example-tailnet.ts.net"))
    }

    @Test("error carries the engine's message")
    func failed() throws {
        let got = try route(#""ts_state": "error", "ts_error": "could not reach the control server""#)
        #expect(got == .failed("could not reach the control server"))
    }

    @Test("a sign-in URL that is http, off Tailscale, or malformed is never signIn", arguments: [
        "http://login.tailscale.com/a/abc123",
        "https://evil.example.com/a",
        "https://tailscale.com.evil.example/a",
        "https://eviltailscale.com/a",
        "not a url",
        "",
    ])
    func unsafeLoginURLIsRefused(raw: String) throws {
        let got = try route(#""ts_state": "needs-login", "ts_login_url": "\#(raw)""#)
        if case .signIn = got { Issue.record("\(raw) must not become signIn, got \(got)") }
    }

    @Test("an unsafe approve or funnel URL is never offered either")
    func unsafeOtherURLsRefused() throws {
        let approve = try route(#""ts_state": "needs-approval", "ts_approve_url": "https://evil.example.com/a""#)
        if case .approve = approve { Issue.record("off-host approve URL was offered") }
        let funnel = try route(#""ts_state": "needs-funnel", "ts_funnel_url": "http://login.tailscale.com/f""#)
        if case .enableFunnel = funnel { Issue.record("http funnel URL was offered") }
    }

    @Test("openable admits https on tailscale.com and its subdomains")
    func openableAdmits() {
        #expect(BuiltInRouteState.openable("https://login.tailscale.com/a/x") == URL(string: "https://login.tailscale.com/a/x"))
        #expect(BuiltInRouteState.openable("https://console.tailscale.com/admin") == URL(string: "https://console.tailscale.com/admin"))
        #expect(BuiltInRouteState.openable("https://tailscale.com/kb") == URL(string: "https://tailscale.com/kb"))
    }

    @Test("openable rejects http, other hosts, look-alikes and nil", arguments: [
        "http://login.tailscale.com/a/x",
        "https://evil.example.com/a",
        "https://tailscale.com.evil.example/a",
        "https://eviltailscale.com/a",
        "https://evil.example.com/?u=https://login.tailscale.com",
        "ftp://login.tailscale.com/a",
        "garbage",
        "",
    ])
    func openableRejects(raw: String) {
        #expect(BuiltInRouteState.openable(raw) == nil)
    }

    @Test("openable rejects nil")
    func openableNil() {
        #expect(BuiltInRouteState.openable(nil) == nil)
    }
}

/// The public address's health: a time on Ready, not answering, waiting for the
/// internet and stopped, each its own state and none of them a failure or Ready.
@Suite("BuiltInRouteState address health")
struct BuiltInRouteStateHealthTests {
    private let host = "relay.example-tailnet.ts.net"
    /// 2026-11-15 10:12:00 UTC, which is 15:42 in Asia/Kolkata.
    private let checked = Date(timeIntervalSince1970: 1_794_737_520)
    /// two minutes before checked: 15:40 in Asia/Kolkata.
    private let since = Date(timeIntervalSince1970: 1_794_737_400)
    private let kolkata = TimeZone(identifier: "Asia/Kolkata")!
    private let utc = TimeZone(identifier: "UTC")!

    private func route(_ fields: String) throws -> BuiltInRouteState {
        let json = #"{"running": true, "sign_in_failing": false, \#(fields)}"#
        let status = try JSONDecoder.engineStatusDecoder.decode(EngineStatus.self, from: Data(json.utf8))
        return BuiltInRouteState.from(status.builtIn)
    }

    @Test("the time of the last successful test reaches Ready")
    func readyCarriesTheCheckedTime() throws {
        let got = try route(#""ts_state": "running", "ts_public_host": "\#(host)", "ts_checked_at": "2026-11-15T10:12:00Z""#)
        #expect(got == .ready(host: host, checkedAt: checked))
    }

    @Test("not answering carries the time of the first failure and keeps the host")
    func notAnswering() throws {
        let got = try route(#""ts_state": "not-answering", "ts_public_host": "\#(host)", "ts_not_answering_since": "2026-11-15T10:10:00Z""#)
        #expect(got == .notAnswering(host: host, since: since))
    }

    @Test("waiting for the internet keeps the host")
    func waitingForInternet() throws {
        let got = try route(#""ts_state": "waiting-for-internet", "ts_public_host": "\#(host)""#)
        #expect(got == .waitingForInternet(host: host))
    }

    @Test("a state this version does not know is still a failure the person can retry")
    func unknownStateStaysFailed() throws {
        #expect(try route(#""ts_state": "some-future-state""#).isFailed)
    }

    @Test("a new state is never a failure, never Ready, and offers no address")
    func newStatesAreNeitherFailureNorReady() throws {
        let states: [BuiltInRouteState] = [
            try route(#""ts_state": "not-answering", "ts_public_host": "\#(host)", "ts_not_answering_since": "2026-11-15T10:10:00Z""#),
            try route(#""ts_state": "waiting-for-internet", "ts_public_host": "\#(host)""#),
            .stopped,
        ]
        for state in states {
            #expect(!state.isFailed, Comment(rawValue: "\(state)"))
            #expect(state.address == nil, Comment(rawValue: "\(state)"))
            #expect(!state.notReadyReason.isEmpty, Comment(rawValue: "\(state)"))
            #expect(state.notReadyReason != BuiltInRouteState.from(BuiltInStatus(state: "some-future-state")).notReadyReason, Comment(rawValue: "\(state)"))
        }
    }

    @Test("Settings reads Ready with the checked time in the viewer's time zone")
    func readyText() {
        let ready = BuiltInRouteState.ready(host: host, checkedAt: checked)
        #expect(ready.settingsStatusText(timeZone: kolkata) == "Ready · checked 15:42")
        #expect(ready.settingsStatusText(timeZone: utc) == "Ready · checked 10:12")
        #expect(BuiltInRouteState.ready(host: host, checkedAt: nil).settingsStatusText(timeZone: kolkata) == "Ready")
    }

    @Test("Settings reads not answering with the first failure's time and says it is reconnecting")
    func notAnsweringText() {
        let state = BuiltInRouteState.notAnswering(host: host, since: since)
        #expect(state.settingsStatusText(timeZone: kolkata) == "Not answering since 15:40, reconnecting…")
        #expect(state.settingsStatusText(timeZone: utc) == "Not answering since 10:10, reconnecting…")
    }

    @Test("Settings reads waiting for the internet, and stopped without the word Ready")
    func otherText() {
        #expect(BuiltInRouteState.waitingForInternet(host: host).settingsStatusText(timeZone: utc) == "Waiting for the internet")
        let stopped = BuiltInRouteState.stopped.settingsStatusText(timeZone: utc)
        #expect(stopped.lowercased().contains("stopped"))
        #expect(!stopped.lowercased().contains("ready"))
    }

    @Test("with the engine stopped or down the route is stopped, whatever the last status said")
    func engineDownIsStopped() {
        let stale = BuiltInStatus(state: "running", publicHost: host, checkedAt: checked)
        #expect(BuiltInRouteState.resolve(engineState: .stopped, status: stale) == .stopped)
        #expect(BuiltInRouteState.resolve(engineState: .waitingToRestart(attempt: 1, delay: .seconds(2)), status: stale) == .stopped)
        #expect(BuiltInRouteState.resolve(engineState: .stopped, status: nil) == .stopped)
    }

    @Test("a starting or failed engine never shows the last status's Ready")
    func engineNotRunningIsNeverReady() {
        let stale = BuiltInStatus(state: "running", publicHost: host, checkedAt: checked)
        for engine in [EngineSupervisor.RunState.starting, .failed(.portInUse)] {
            let got = BuiltInRouteState.resolve(engineState: engine, status: stale)
            #expect(got.address == nil, Comment(rawValue: "\(engine)"))
        }
        if case .failed = BuiltInRouteState.resolve(engineState: .failed(.portInUse), status: stale) {} else {
            Issue.record("a failed engine must stay a failure the person can retry")
        }
    }

    @Test("with the engine running the route is what the engine reported")
    func engineRunningUsesTheReport() {
        let report = BuiltInStatus(state: "running", publicHost: host, checkedAt: checked)
        #expect(BuiltInRouteState.resolve(engineState: .running, status: report) == .ready(host: host, checkedAt: checked))
        let slow = BuiltInStatus(state: "not-answering", publicHost: host, notAnsweringSince: since)
        #expect(BuiltInRouteState.resolve(engineState: .running, status: slow) == .notAnswering(host: host, since: since))
    }

    @Test("a Ready whose last test is older than six minutes is no longer Ready, however long ago the report arrived")
    func readyExpiresWhenReportsStopArriving() {
        let ready = BuiltInRouteState.ready(host: host, checkedAt: checked)
        #expect(ready.expiredAt(checked.addingTimeInterval(359)) == ready)
        #expect(ready.expiredAt(checked.addingTimeInterval(361)) == .settingUp(host: host))
        #expect(BuiltInRouteState.notAnswering(host: host, since: since).expiredAt(checked.addingTimeInterval(3600)) == .notAnswering(host: host, since: since))
    }
}

extension BuiltInRouteState {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

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

/// The wait for a new address: publishing while the first public answer has not
/// come, not reachable after the window, and what each says to the person.
@Suite("BuiltInRouteState publishing")
struct BuiltInRouteStatePublishingTests {
    private let host = "relay.example-tailnet.ts.net"
    /// 2026-11-15 10:10:00 UTC, which is 15:40 in Asia/Kolkata.
    private let since = Date(timeIntervalSince1970: 1_794_737_400)
    private let utc = TimeZone(identifier: "UTC")!
    private let publishingText = "Publishing your address… This can take up to 10 minutes"

    private func route(_ fields: String) throws -> BuiltInRouteState {
        let json = #"{"running": true, "sign_in_failing": false, \#(fields)}"#
        let status = try JSONDecoder.engineStatusDecoder.decode(EngineStatus.self, from: Data(json.utf8))
        return BuiltInRouteState.from(status.builtIn)
    }

    @Test("publishing carries the host and the time it began")
    func publishing() throws {
        let got = try route(#""ts_state": "publishing", "ts_public_host": "\#(host)", "ts_publishing_since": "2026-11-15T10:10:00Z""#)
        #expect(got == .publishing(host: host, since: since))
        #expect(got.address == nil)
        #expect(!got.isFailed)
    }

    @Test("not reachable is its own state with the host, never a failure and never an address")
    func notReachable() throws {
        let got = try route(#""ts_state": "not-reachable", "ts_public_host": "\#(host)""#)
        #expect(got == .notReachable(host: host))
        #expect(got.address == nil)
        #expect(!got.isFailed)
    }

    @Test("with the engine running the route is the engine's publishing, and a stale-report check leaves it alone")
    func resolvedAndNotExpired() {
        let report = BuiltInStatus(state: "publishing", publicHost: host, publishingSince: since)
        let got = BuiltInRouteState.resolve(engineState: .running, status: report)
        #expect(got == .publishing(host: host, since: since))
        #expect(got.expiredAt(since.addingTimeInterval(3600)) == got)
        #expect(BuiltInRouteState.resolve(engineState: .stopped, status: report) == .stopped)
    }

    @Test("setup reads Publishing your address with the ten minutes, and nothing about the internet")
    func publishingReason() {
        let state = BuiltInRouteState.publishing(host: host, since: since)
        #expect(state.notReadyReason == publishingText)
        #expect(!state.notReadyReason.lowercased().contains("internet"))
    }

    @Test("Settings reads the same line with the elapsed time", arguments: [
        (0.0, "less than 1 min so far"),
        (59.0, "less than 1 min so far"),
        (60.0, "1 min so far"),
        (120.0, "2 min so far"),
        (14 * 60.0 + 59, "14 min so far"),
        (16 * 60.0, "16 min so far"),
    ])
    func publishingSettingsText(elapsed: Double, clause: String) {
        let state = BuiltInRouteState.publishing(host: host, since: since)
        let text = state.settingsStatusText(timeZone: utc, now: since.addingTimeInterval(elapsed))
        #expect(text == "\(publishingText) (\(clause))")
        #expect(!text.lowercased().contains("internet"))
    }

    @Test("with no start time Settings gives the line without an elapsed clause")
    func publishingWithoutTime() {
        let state = BuiltInRouteState.publishing(host: host, since: nil)
        #expect(state.settingsStatusText(timeZone: utc, now: since) == publishingText)
    }

    @Test("a clock that ran backwards never shows a negative elapsed time")
    func publishingClockBackwards() {
        let state = BuiltInRouteState.publishing(host: host, since: since)
        let text = state.settingsStatusText(timeZone: utc, now: since.addingTimeInterval(-300))
        #expect(!text.contains("-"))
    }

    @Test("not reachable says so plainly, offers Try Again, and never blames the connection")
    func notReachableText() {
        let state = BuiltInRouteState.notReachable(host: host)
        #expect(state.notReadyReason == "Your address isn't reachable yet")
        #expect(state.settingsStatusText(timeZone: utc, now: since) == "Your address isn't reachable yet")
        #expect(state.showsTryAgain)
        for text in [state.notReadyReason, state.settingsStatusText(timeZone: utc, now: since)] {
            #expect(!text.lowercased().contains("internet"))
            #expect(!text.lowercased().contains("connection"))
        }
        #expect(!BuiltInRouteState.publishing(host: host, since: since).showsTryAgain)
        #expect(!BuiltInRouteState.ready(host: host).showsTryAgain)
    }

    @Test("the last Tailscale error shows only while the address is in trouble, never on Turn On, Publishing or Ready")
    func tailscaleErrorShown() {
        let text = "Funnel not available; HTTPS must be enabled."
        for state in ["not-reachable", "not-answering"] {
            let status = BuiltInStatus(state: state, publicHost: host, tailscaleError: text)
            #expect(BuiltInRouteState.tailscaleErrorText(from: status) == text, Comment(rawValue: state))
        }
        for state in ["needs-funnel", "publishing", "setting-up", "running", "starting", "needs-login", "needs-approval", "waiting-for-internet", "error"] {
            let status = BuiltInStatus(state: state, funnelURL: "https://login.tailscale.com/f/funnel", publicHost: host, tailscaleError: text)
            #expect(BuiltInRouteState.tailscaleErrorText(from: status) == nil, Comment(rawValue: state))
        }
        #expect(BuiltInRouteState.tailscaleErrorText(from: BuiltInStatus(state: "not-reachable", tailscaleError: "  \n ")) == nil)
        #expect(BuiltInRouteState.tailscaleErrorText(from: BuiltInStatus(state: "not-reachable")) == nil)
        #expect(BuiltInRouteState.tailscaleErrorText(from: nil) == nil)
    }

    @Test("an error left over from Turn On clears the moment the status moves to Publishing or Ready")
    func tailscaleErrorClearsWhenFunnelIsAllowed() {
        let text = "Funnel not available; HTTPS must be enabled."
        let before = BuiltInStatus(state: "needs-funnel", funnelURL: "https://login.tailscale.com/f/funnel", tailscaleError: text)
        #expect(BuiltInRouteState.tailscaleErrorText(from: before) == nil)
        let after = BuiltInStatus(state: "publishing", publicHost: host, tailscaleError: text)
        #expect(BuiltInRouteState.tailscaleErrorText(from: after) == nil)
        let answered = BuiltInStatus(state: "running", publicHost: host, checkedAt: checked, tailscaleError: text)
        #expect(BuiltInRouteState.tailscaleErrorText(from: answered) == nil)
    }

    @Test("the Tailscale error and its class decode from the engine's report")
    func errorFieldsDecode() throws {
        let json = #"{"running": true, "sign_in_failing": false, "ts_state": "publishing", "ts_tailscale_error": "HTTPS must be enabled", "ts_error_class": "https_disabled", "ts_publishing_since": "2026-11-15T10:10:00Z"}"#
        let status = try JSONDecoder.engineStatusDecoder.decode(EngineStatus.self, from: Data(json.utf8))
        #expect(status.builtIn?.tailscaleError == "HTTPS must be enabled")
        #expect(status.builtIn?.errorClass == "https_disabled")
        #expect(status.builtIn?.publishingSince == since)
    }
}

/// The sign-in expiry warning in Settings.
@Suite("BuiltInKeyExpiry")
struct BuiltInKeyExpiryTests {
    /// 2026-11-15 10:12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_794_737_520)
    private let day: TimeInterval = 86_400
    private let utc = TimeZone(identifier: "UTC")!
    private let kolkata = TimeZone(identifier: "Asia/Kolkata")!

    private func notice(expiringIn seconds: TimeInterval) -> BuiltInKeyExpiry? {
        BuiltInKeyExpiry.notice(for: BuiltInStatus(state: "running", publicHost: "relay.example-tailnet.ts.net", keyExpiry: now.addingTimeInterval(seconds)), now: now)
    }

    @Test("the expiry decodes from the engine's report")
    func decodes() throws {
        let json = #"{"running": true, "sign_in_failing": false, "ts_state": "running", "ts_public_host": "h.example.ts.net", "ts_key_expiry": "2026-11-29T23:30:00Z"}"#
        let status = try JSONDecoder.engineStatusDecoder.decode(EngineStatus.self, from: Data(json.utf8))
        #expect(status.builtIn?.keyExpiry == now.addingTimeInterval(14 * day + 47_880))
    }

    @Test("there is a warning within 14 days of expiry, inclusive, and none before")
    func windowEdges() {
        #expect(notice(expiringIn: 14 * day) != nil)
        #expect(notice(expiringIn: 14 * day - 1) != nil)
        #expect(notice(expiringIn: day) != nil)
        #expect(notice(expiringIn: 1) != nil)
        #expect(notice(expiringIn: 14 * day + 1) == nil)
        #expect(notice(expiringIn: 90 * day) == nil)
    }

    @Test("after expiry there is no warning, since the sign-in state applies")
    func afterExpiry() {
        #expect(notice(expiringIn: 0) == nil)
        #expect(notice(expiringIn: -1) == nil)
        #expect(notice(expiringIn: -30 * day) == nil)
    }

    @Test("no known expiry and no status give no warning")
    func unknown() {
        #expect(BuiltInKeyExpiry.notice(for: BuiltInStatus(state: "running"), now: now) == nil)
        #expect(BuiltInKeyExpiry.notice(for: nil, now: now) == nil)
    }

    @Test("the warning names the date in the viewer's time zone")
    func text() {
        // 2026-11-28 23:30 UTC is already the 29th in Asia/Kolkata.
        let near = BuiltInKeyExpiry.notice(for: BuiltInStatus(state: "running", keyExpiry: now.addingTimeInterval(13 * day + 47_880)), now: now)
        #expect(near?.text(timeZone: utc) == "Tailscale sign-in expires on 28 Nov 2026")
        #expect(near?.text(timeZone: kolkata) == "Tailscale sign-in expires on 29 Nov 2026")
    }

    @Test("the button reads Sign In Again")
    func buttonTitle() {
        #expect(BuiltInKeyExpiry.signInAgainTitle == "Sign In Again")
    }

    @Test("the page Sign In Again opens is only ever an https page on Tailscale")
    func signInAgainURL() {
        let ok = BuiltInStatus(state: "running", signInAgainURL: "https://login.tailscale.com/a/abc123")
        #expect(BuiltInKeyExpiry.signInAgainURL(from: ok) == URL(string: "https://login.tailscale.com/a/abc123"))
        for raw in ["http://login.tailscale.com/a/x", "https://evil.example.com/a", "https://tailscale.com.evil.example/a", "garbage", ""] {
            #expect(BuiltInKeyExpiry.signInAgainURL(from: BuiltInStatus(state: "running", signInAgainURL: raw)) == nil, Comment(rawValue: raw))
        }
        #expect(BuiltInKeyExpiry.signInAgainURL(from: nil) == nil)
    }

    @Test("a press of Sign In Again opens the page, or says plainly why it did not")
    func signInAgainOutcome() throws {
        let page = try #require(URL(string: "https://login.tailscale.com/a/abc123"))
        #expect(BuiltInKeyExpiry.outcome(engineStarted: true, page: page) == .open(page))
        #expect(BuiltInKeyExpiry.outcome(engineStarted: true, page: page).message == nil)
        #expect(BuiltInKeyExpiry.outcome(engineStarted: false, page: nil) == .refused)
        #expect(BuiltInKeyExpiry.outcome(engineStarted: false, page: page) == .refused)
        #expect(BuiltInKeyExpiry.outcome(engineStarted: true, page: nil) == .timedOut)
        for outcome in [BuiltInKeyExpiry.SignInAgainOutcome.refused, .timedOut] {
            #expect(outcome.message == "Couldn't start Tailscale sign-in. Try again in a moment.")
        }
    }

    @Test("an expiry date never makes the route a failure or hides Ready")
    func routeUntouched() {
        let status = BuiltInStatus(state: "running", publicHost: "relay.example-tailnet.ts.net", checkedAt: now, keyExpiry: now.addingTimeInterval(2 * day))
        #expect(BuiltInRouteState.from(status) == .ready(host: "relay.example-tailnet.ts.net", checkedAt: now))
    }
}

extension BuiltInRouteState {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// After the Enable Funnel page closes, the row says the address is being
/// turned on and does not offer Turn On again until the engine has had two
/// minutes to notice.
@Suite("BuiltInFunnelRecheck")
struct BuiltInFunnelRecheckTests {
    private let page = URL(string: "https://login.tailscale.com/f/funnel")!
    private let closed = Date(timeIntervalSince1970: 1_794_737_400)

    @Test("the wait is two minutes and the row says it is turning the address on")
    func constants() {
        #expect(BuiltInFunnelRecheck.window == 120)
        #expect(BuiltInFunnelRecheck.checkingTitle == "Turning on your address…")
    }

    @Test("right after the page closes, a row still reporting Funnel not allowed is a check, not Turn On")
    func checksRightAfterClose() {
        let route = BuiltInRouteState.enableFunnel(page)
        #expect(BuiltInFunnelRecheck.isChecking(route: route, sheetClosedAt: closed, now: closed))
        #expect(BuiltInFunnelRecheck.isChecking(route: route, sheetClosedAt: closed, now: closed.addingTimeInterval(1)))
        #expect(BuiltInFunnelRecheck.isChecking(route: route, sheetClosedAt: closed, now: closed.addingTimeInterval(119.9)))
    }

    @Test("two minutes on, an engine that still reports Funnel not allowed shows Turn On again")
    func turnOnReturnsAfterTwoMinutes() {
        let route = BuiltInRouteState.enableFunnel(page)
        #expect(!BuiltInFunnelRecheck.isChecking(route: route, sheetClosedAt: closed, now: closed.addingTimeInterval(120)))
        #expect(!BuiltInFunnelRecheck.isChecking(route: route, sheetClosedAt: closed, now: closed.addingTimeInterval(600)))
    }

    @Test("with no page closed, Turn On is shown as it is")
    func neverClosed() {
        #expect(!BuiltInFunnelRecheck.isChecking(route: .enableFunnel(page), sheetClosedAt: nil, now: closed))
    }

    @Test("a state other than Funnel not allowed is never turned into a check", arguments: [
        BuiltInRouteState.starting,
        .settingUp(host: "relay.example-tailnet.ts.net"),
        .publishing(host: "relay.example-tailnet.ts.net", since: nil),
        .notReachable(host: "relay.example-tailnet.ts.net"),
        .ready(host: "relay.example-tailnet.ts.net"),
        .notAnswering(host: "relay.example-tailnet.ts.net", since: nil),
        .waitingForInternet(host: "relay.example-tailnet.ts.net"),
        .stopped,
        .failed("Tailscale stopped with an error."),
    ])
    func otherStatesKeepTheirOwnRow(route: BuiltInRouteState) {
        #expect(!BuiltInFunnelRecheck.isChecking(route: route, sheetClosedAt: closed, now: closed.addingTimeInterval(1)))
    }
}

/// Continue on the Reach This Mac step goes forward only when that means
/// something: the address answers, or the person chose Set Up Later.
@Suite("Reach step Continue")
struct ReachContinueTests {
    private let host = "relay.example-tailnet.ts.net"
    private let page = URL(string: "https://login.tailscale.com/a/abc123")!
    private let now = Date(timeIntervalSince1970: 1_794_737_520)

    @Test("Continue is enabled when the address is Ready")
    func readyEnables() {
        #expect(SetupCompletion.mayContinueFromReach(route: .ready(host: host), choseSetUpLater: false, now: now))
        #expect(SetupCompletion.mayContinueFromReach(route: .ready(host: host, checkedAt: now), choseSetUpLater: false, now: now))
    }

    @Test("Continue stays off in every state that is not Ready, however the wait looks", arguments: [
        BuiltInRouteState.starting,
        .signIn(URL(string: "https://login.tailscale.com/a/abc123")!),
        .approve(URL(string: "https://login.tailscale.com/admin/machines")!),
        .enableFunnel(URL(string: "https://login.tailscale.com/f/funnel")!),
        .settingUp(host: "relay.example-tailnet.ts.net"),
        .publishing(host: "relay.example-tailnet.ts.net", since: nil),
        .notReachable(host: "relay.example-tailnet.ts.net"),
        .notAnswering(host: "relay.example-tailnet.ts.net", since: nil),
        .waitingForInternet(host: "relay.example-tailnet.ts.net"),
        .stopped,
        .failed("Tailscale stopped with an error."),
    ])
    func notReadyDisables(route: BuiltInRouteState) {
        #expect(!SetupCompletion.mayContinueFromReach(route: route, choseSetUpLater: false, now: now))
    }

    @Test("a Ready whose last test is too old is the setting-up row, so Continue is off")
    func staleReadyDisables() {
        let route = BuiltInRouteState.ready(host: host, checkedAt: now.addingTimeInterval(-10 * 60))
        #expect(!SetupCompletion.mayContinueFromReach(route: route, choseSetUpLater: false, now: now))
    }

    @Test("choosing Set Up Later lets the person go on from any state")
    func setUpLaterEnables() {
        for route in [BuiltInRouteState.starting, .settingUp(host: host), .publishing(host: host, since: nil), .notAnswering(host: host, since: nil), .stopped] {
            #expect(SetupCompletion.mayContinueFromReach(route: route, choseSetUpLater: true, now: now))
        }
    }
}

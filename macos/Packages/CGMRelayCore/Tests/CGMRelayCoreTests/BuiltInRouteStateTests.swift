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

extension BuiltInRouteState {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

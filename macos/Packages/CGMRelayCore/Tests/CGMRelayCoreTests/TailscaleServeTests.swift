import Foundation
import Testing
@testable import CGMRelayCore

/// A fake Tailscale executable: records every call and the environment it
/// was started with, answers `status --json` and `serve status --json` from
/// files, and ends each change command the way the next line of the mode
/// file says (the last line repeats), applying the change it was asked for
/// or leaving it alone. Nothing here ever runs the real Tailscale.
private struct FakeTailscale {
    let directory: URL
    var executable: URL { directory.appendingPathComponent("tailscale") }
    var recordedEnvironment: String {
        (try? String(contentsOf: directory.appendingPathComponent("env"), encoding: .utf8)) ?? ""
    }
    var calls: [String] {
        ((try? String(contentsOf: directory.appendingPathComponent("calls"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    init(
        mode: String,
        statusJSON: String = #"{"BackendState":"Running","Self":{"DNSName":"relay-mac.example-tailnet.ts.net."}}"#,
        serveJSON: String = "{}"
    ) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("fake-tailscale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try mode.write(to: directory.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        try statusJSON.write(to: directory.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)
        try serveJSON.write(to: directory.appendingPathComponent("serve.json"), atomically: true, encoding: .utf8)
        let script = """
        #!/bin/sh
        here=$(dirname "$0")
        echo "$@" >> "$here/calls"
        echo "TAILSCALE_BE_CLI=${TAILSCALE_BE_CLI}" >> "$here/env"
        case "$1" in
          status) cat "$here/status.json" ;;
          serve)
            if [ "$2" = status ]; then cat "$here/serve.json"; exit 0; fi
            mode=$(sed -n 1p "$here/mode")
            if [ "$(grep -c '' "$here/mode")" -gt 1 ]; then tail -n +2 "$here/mode" > "$here/mode.next"; mv "$here/mode.next" "$here/mode"; fi
            case "$mode" in
              ok|okquiet)
                if [ "$mode" = ok ]; then
                  if [ "$2" = "--bg" ]; then
                    p=${3#--https=}
                    printf '{"TCP":{"%s":{"HTTPS":true}},"Web":{"relay-mac.example-tailnet.ts.net:%s":{"Handlers":{"/":{"Proxy":"%s"}}}}}' "$p" "$p" "$4" > "$here/serve.json"
                  else
                    echo '{}' > "$here/serve.json"
                  fi
                fi
                exit 0 ;;
              nohttps) echo "error enabling https feature: HTTPS is not enabled for this tailnet" >&2; exit 1 ;;
              stopped) echo "Tailscale is stopped." >&2; exit 1 ;;
              hang) sleep 60 ;;
              *) echo "something unexpected 100.64.0.1 secret-name" >&2; exit 1 ;;
            esac ;;
        esac
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private actor WaitLog {
    private(set) var values: [Duration] = []
    func record(_ wait: Duration) { values.append(wait) }
}

@Suite("Tailscale HTTPS")
struct TailscaleServeTests {
    @Test("the commands are exactly the two serve invocations, and the shown text is the text that runs")
    func commands() {
        let on = TailscaleServeCommand.enableHTTPS(proxyingToPort: 1337, httpsPort: 443)
        #expect(on.arguments == ["serve", "--bg", "--https=443", "http://127.0.0.1:1337"])
        #expect(on.displayText == "tailscale serve --bg --https=443 http://127.0.0.1:1337")
        #expect(TailscaleServeCommand.enableHTTPS(proxyingToPort: 1337, httpsPort: 8443).displayText == "tailscale serve --bg --https=8443 http://127.0.0.1:1337")
        let off = TailscaleServeCommand.disableHTTPS(httpsPort: 8443)
        #expect(off.arguments == ["serve", "--https=8443", "--set-path=/", "off"])
        #expect(off.displayText == "tailscale serve --https=8443 --set-path=/ off")
    }

    static let other443 = #"{"TCP":{"443":{"HTTPS":true}},"Web":{"relay-mac.example-tailnet.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}}}}"#
    static let ours443 = #"{"TCP":{"443":{"HTTPS":true}},"Web":{"relay-mac.example-tailnet.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:1337"}}}}}"#
    static let ours8443 = #"{"TCP":{"443":{"HTTPS":true},"8443":{"HTTPS":true}},"Web":{"relay-mac.example-tailnet.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}},"relay-mac.example-tailnet.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:1337"},"/other":{"Proxy":"http://127.0.0.1:9"}}}}}"#
    static let host = "relay-mac.example-tailnet.ts.net"
    static let httpOnlyTCP = #"{"TCP":{"8443":{"HTTP":true}},"Web":{"relay-mac.example-tailnet.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:1337"}}}}}"#
    static let otherHost443 = #"{"TCP":{"443":{"HTTPS":true}},"Web":{"other-mac.example-tailnet.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:1337"}}}}}"#
    static let foregroundOurs443 = #"{"Foreground":{"session":{"TCP":{"443":{"HTTPS":true}},"Web":{"relay-mac.example-tailnet.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:1337"}}}}}}}"#
    static let upperCaseDotHost = #"{"TCP":{"443":{"HTTPS":true}},"Web":{"Relay-Mac.Example-Tailnet.ts.net.:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:1337"}}}}}"#
    static let noHTTPSFlag = #"{"TCP":{"443":{"TCPForward":"127.0.0.1:22"}},"Web":{"relay-mac.example-tailnet.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:1337"}}}}}"#
    static let tcpOnly443 = #"{"TCP":{"443":{"TCPForward":"127.0.0.1:22"}}}"#
    static let foreground443 = #"{"Foreground":{"session":{"TCP":{"443":{"HTTPS":true}},"Web":{"relay-mac.example-tailnet.ts.net:443":{"Handlers":{"/":{"Text":"hi"}}}}}}}"#
    static let allTaken = #"{"TCP":{"443":{"HTTPS":true},"8443":{"HTTPS":true},"10000":{"HTTPS":true}},"Web":{"h.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}},"h.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3001"}}},"h.ts.net:10000":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3002"}}}}}"#

    static let serveCases: [(name: String, json: String, wantOccupied: Set<Int>?, wantRoot443: String?)] = [
        ("nothing served", "{}", [], nil),
        ("null is an empty config", "null", [], nil),
        ("another service on 443", other443, [443], "http://127.0.0.1:3000"),
        ("TCP forwarding alone occupies its port", tcpOnly443, [443], nil),
        ("a foreground session occupies its ports but its handlers are not the background ones", foreground443, [443], nil),
        ("another host on the same port occupies it", otherHost443, [443], nil),
        ("not JSON is unreadable, never empty", "No serve config", nil, nil),
        ("empty output is unreadable, never empty", "", nil, nil),
    ]

    @Test("serve status parsing reads occupied ports and the handler at / , and refuses unreadable output", arguments: serveCases)
    func serveParsing(_ testCase: (name: String, json: String, wantOccupied: Set<Int>?, wantRoot443: String?)) {
        let parsed = TailscaleServeConfigParser.parse(Data(testCase.json.utf8))
        #expect(parsed?.occupiedPorts == testCase.wantOccupied)
        if testCase.wantOccupied != nil { #expect(parsed?.rootProxies[TailscaleServeConfig.webKey(host: Self.host, port: 443)] == testCase.wantRoot443) }
    }

    static let running = TailscaleStatus.running(name: "relay-mac.example-tailnet.ts.net")
    static let stateCases: [(name: String, status: TailscaleStatus, json: String?, want: TailscaleHTTPSState)] = [
        ("443 free", running, "{}", .off(port: 443)),
        ("443 taken by something else: the next free port", running, other443, .off(port: 8443)),
        ("443 taken by TCP forwarding", running, tcpOnly443, .off(port: 8443)),
        ("443 taken by a foreground session", running, foreground443, .off(port: 8443)),
        ("every listed port taken", running, allTaken, .noFreePort),
        ("ours present on 443", running, ours443, .on(port: 443)),
        ("ours present on 8443, beside another service on 443", running, ours8443, .on(port: 8443)),
        ("ours gone: 443 holds only another service", running, other443, .off(port: 8443)),
        ("its proxy points at another relay port, so not ours", running, ours443.replacingOccurrences(of: "1337", with: "1338"), .off(port: 8443)),
        ("plain HTTP on 8443 with our proxy is not ours, and the port stays taken", running, httpOnlyTCP, .off(port: 443)),
        ("another host's entry on 443 is not ours, and 443 stays taken", running, otherHost443, .off(port: 8443)),
        ("a foreground session's handler with our proxy is not ours, and its port stays taken", running, foregroundOurs443, .off(port: 8443)),
        ("a web entry with no HTTPS flag on its port is not ours", running, noHTTPSFlag, .off(port: 8443)),
        ("this Mac's name in another case and with a trailing dot is ours", running, upperCaseDotHost, .on(port: 443)),
        ("ours on 443 but this Mac's name differs: not ours", .running(name: "renamed-mac.example-tailnet.ts.net"), ours443, .off(port: 8443)),
        ("serve settings unreadable", running, nil, .unreadable),
        ("Tailscale stopped", .stopped, "{}", .unavailable),
        ("Tailscale absent", .absent, nil, .unavailable),
        ("not read yet", .unknown, nil, .unknown),
    ]

    @Test("the HTTPS state is decided only from what Tailscale reports", arguments: stateCases)
    func httpsState(_ testCase: (name: String, status: TailscaleStatus, json: String?, want: TailscaleHTTPSState)) {
        let config = testCase.json.flatMap { TailscaleServeConfigParser.parse(Data($0.utf8)) }
        #expect(TailscaleHTTPSState.evaluate(status: testCase.status, config: config, relayPort: 1337) == testCase.want)
    }

    @Test("the address carries the port only when it is not 443")
    func addressPort() {
        #expect(TailscaleHTTPSState.address(name: "relay-mac.example-tailnet.ts.net", port: 443) == "https://relay-mac.example-tailnet.ts.net")
        #expect(TailscaleHTTPSState.address(name: "relay-mac.example-tailnet.ts.net", port: 8443) == "https://relay-mac.example-tailnet.ts.net:8443")
    }

    static let statusCases: [(name: String, json: String, want: TailscaleStatus)] = [
        ("running", #"{"BackendState":"Running","Self":{"DNSName":"relay-mac.example-tailnet.ts.net."}}"#, .running(name: "relay-mac.example-tailnet.ts.net")),
        ("stopped", #"{"BackendState":"Stopped","Self":{"DNSName":"relay-mac.example-tailnet.ts.net."}}"#, .stopped),
        ("signed out", #"{"BackendState":"NeedsLogin"}"#, .stopped),
        ("running with no name", #"{"BackendState":"Running","Self":{}}"#, .stopped),
        ("a name that is not a plain DNS name", #"{"BackendState":"Running","Self":{"DNSName":"a/b.example.ts.net."}}"#, .stopped),
        ("not JSON", "no", .stopped),
    ]

    @Test("status parsing answers running only for a running Tailscale with a plain name", arguments: statusCases)
    func statusParsing(_ testCase: (name: String, json: String, want: TailscaleStatus)) {
        #expect(TailscaleStatusParser.parse(Data(testCase.json.utf8)) == testCase.want)
    }

    static let outcomeCases: [(mode: String, turningOn: Bool, want: TailscaleServeOutcome)] = [
        ("ok", true, .succeeded),
        ("nohttps", true, .httpsNotEnabled),
        ("stopped", true, .stopped),
        ("other", true, .other),
        ("hang", true, .timedOut),
    ]

    @Test("turning on classifies each ending, runs exactly one command, and never shows what the command printed", arguments: outcomeCases)
    func enableOutcomes(_ testCase: (mode: String, turningOn: Bool, want: TailscaleServeOutcome)) async throws {
        let fake = try FakeTailscale(mode: testCase.mode)
        defer { fake.remove() }
        let controller = RealTailscaleController(
            executableURL: fake.executable,
            runner: RealBoundedProcessRunner(extraEnvironment: RealTailscaleController.environment),
            changeTimeout: testCase.mode == "hang" ? .milliseconds(500) : .seconds(10)
        )
        let outcome = await controller.enableHTTPS(proxyingToPort: 1337, httpsPort: 443)
        #expect(outcome == testCase.want)
        #expect(fake.calls == ["serve --bg --https=443 http://127.0.0.1:1337"])
        let message = outcome.message(turningOn: true) ?? ""
        #expect(!message.contains("100.64.0.1") && !message.contains("secret-name"))
        #expect((outcome == .succeeded) == (outcome.message(turningOn: true) == nil))
    }

    static let changeCases: [(name: String, turningOn: Bool, modes: String, serveJSON: String, want: TailscaleChangeResult, wantChangeCommands: Int, wantWaits: Int)] = [
        ("on: fails once then succeeds, nothing shown", true, "other\nok", "{}", .done, 2, 1),
        ("on: fails every time, shown after the last attempt", true, "other", "{}", .failed(.other), 3, 2),
        ("on: exit 0 without our entry, then found", true, "okquiet\nok", "{}", .done, 2, 1),
        ("on: exit 0 without our entry every time", true, "okquiet", "{}", .failed(.other), 3, 2),
        ("on: certificates off is shown at once", true, "nohttps", "{}", .failed(.httpsNotEnabled), 1, 0),
        ("on: Tailscale stopped is shown at once", true, "stopped", "{}", .failed(.stopped), 1, 0),
        ("on: a timeout is shown at once, never retried", true, "hang", "{}", .failed(.timedOut), 1, 0),
        ("off: a timeout is shown at once, never retried", false, "hang", ours443, .failed(.timedOut), 1, 0),
        ("on: the port is no longer free, no command", true, "ok", other443, .refused, 0, 0),
        ("on: already ours, no command", true, "ok", ours443, .unchanged, 0, 0),
        ("off: fails once then succeeds", false, "other\nok", ours443, .done, 2, 1),
        ("off: fails every time", false, "other", ours443, .failed(.other), 3, 2),
        ("off: exit 0 but the entry stays, then gone", false, "okquiet\nok", ours443, .done, 2, 1),
        ("off: not ours any more, no command", false, "ok", other443, .refused, 0, 0),
        ("off: certificates off is shown at once", false, "nohttps", ours443, .failed(.httpsNotEnabled), 1, 0),
    ]

    @Test("a change is retried quietly on a transient failure, starting from a fresh read each time, and shown at once when only the person can fix it", arguments: changeCases)
    func changeRetries(_ testCase: (name: String, turningOn: Bool, modes: String, serveJSON: String, want: TailscaleChangeResult, wantChangeCommands: Int, wantWaits: Int)) async throws {
        let fake = try FakeTailscale(mode: testCase.modes, serveJSON: testCase.serveJSON)
        defer { fake.remove() }
        let controller = RealTailscaleController(executableURL: fake.executable, runner: RealBoundedProcessRunner(extraEnvironment: RealTailscaleController.environment), changeTimeout: .seconds(2))
        let read: () async -> TailscaleHTTPSState = {
            TailscaleHTTPSState.evaluate(status: await controller.status(), config: await controller.serveConfig(), relayPort: 1337)
        }
        let waits = WaitLog()
        let got: TailscaleChangeResult
        if testCase.turningOn {
            got = await TailscaleChange.turnOn(shownPort: 443, relayPort: 1337, controller: controller, read: read, wait: { await waits.record($0) })
        } else {
            got = await TailscaleChange.turnOff(shownPort: 443, controller: controller, read: read, wait: { await waits.record($0) })
        }
        #expect(got == testCase.want)
        let changes = fake.calls.filter { $0.hasPrefix("serve --") }
        #expect(changes.count == testCase.wantChangeCommands)
        #expect(await waits.values == Array(TailscaleChange.retryWaits.prefix(testCase.wantWaits)))
        if testCase.wantChangeCommands > 1 {
            let reads = fake.calls.filter { $0 == "serve status --json" }.count
            #expect(reads >= 2 * testCase.wantChangeCommands)
        }
    }

    @Test("turning off runs the one matching command")
    func disable() async throws {
        let fake = try FakeTailscale(mode: "ok")
        defer { fake.remove() }
        let outcome = await RealTailscaleController(executableURL: fake.executable).disableHTTPS(httpsPort: 8443)
        #expect(outcome == .succeeded)
        #expect(fake.calls == ["serve --https=8443 --set-path=/ off"])
    }

    @Test("serve status is read through the same runner: one read-only call, parsed")
    func serveStatusRead() async throws {
        let fake = try FakeTailscale(mode: "ok", serveJSON: Self.ours443)
        defer { fake.remove() }
        let config = await RealTailscaleController(executableURL: fake.executable).serveConfig()
        #expect(config?.isOurs(host: Self.host, httpsPort: 443, relayPort: 1337) == true)
        #expect(fake.calls == ["serve status --json"])
        #expect(await RealTailscaleController(executableURL: nil).serveConfig() == nil)
    }

    @Test("every Tailscale run carries TAILSCALE_BE_CLI=1; the default runner (the engine's and check-account's) does not")
    func environmentReachesTheChild() async throws {
        let fake = try FakeTailscale(mode: "ok")
        defer { fake.remove() }
        let controller = RealTailscaleController(executableURL: fake.executable)
        _ = await controller.status()
        _ = await controller.serveConfig()
        _ = await controller.enableHTTPS(proxyingToPort: 1337, httpsPort: 443)
        _ = await controller.disableHTTPS(httpsPort: 443)
        let lines = fake.recordedEnvironment.split(separator: "\n").map(String.init)
        #expect(lines.count == 4)
        #expect(lines.allSatisfy { $0 == "TAILSCALE_BE_CLI=1" })

        let plain = try FakeTailscale(mode: "ok")
        defer { plain.remove() }
        _ = await RealBoundedProcessRunner().run(executableURL: plain.executable, arguments: ["status"], standardInputData: Data(), timeout: .seconds(5))
        #expect(plain.recordedEnvironment == "TAILSCALE_BE_CLI=\n")
    }

    @Test("status reads status --json and makes no other call; a missing executable is absent")
    func status() async throws {
        let fake = try FakeTailscale(mode: "ok")
        defer { fake.remove() }
        let running = await RealTailscaleController(executableURL: fake.executable).status()
        #expect(running == .running(name: "relay-mac.example-tailnet.ts.net"))
        #expect(fake.calls == ["status --json"])
        #expect(await RealTailscaleController(executableURL: nil).status() == .absent)
        #expect(await RealTailscaleController(executableURL: URL(fileURLWithPath: "/no/such/tailscale-cgmrelay-test")).status() == .absent)
    }

    static let locatorCases: [(name: String, debug: Bool, fake: String?, service: String?, executable: Set<String>, want: String?)] = [
        ("release uses the app bundle's tool first", false, nil, nil, Set(TailscaleLocator.standardLocations), TailscaleLocator.standardLocations[0]),
        ("release falls through to the next location", false, nil, nil, [TailscaleLocator.standardLocations[1]], TailscaleLocator.standardLocations[1]),
        ("release with none found", false, nil, nil, [], nil),
        ("release ignores a fake path", false, "/fake", "com.example.walk", ["/fake"], nil),
        ("debug with a fake and a throwaway service", true, "/fake", "com.example.walk", ["/fake"], "/fake"),
        ("debug with a fake and no throwaway service", true, "/fake", nil, ["/fake"], nil),
        ("debug naming the real service", true, "/fake", KeychainCredentialStore.defaultService, ["/fake"], nil),
        ("debug never falls back to the real tool", true, nil, "com.example.walk", Set(TailscaleLocator.standardLocations), nil),
        ("debug with a fake that is not executable", true, "/fake", "com.example.walk", [], nil),
    ]

    @Test("the locator honours a fake only in a debug build that also names a throwaway service", arguments: locatorCases)
    func locator(_ testCase: (name: String, debug: Bool, fake: String?, service: String?, executable: Set<String>, want: String?)) {
        let got = TailscaleLocator.resolve(
            isDebugBuild: testCase.debug,
            fakePath: testCase.fake,
            explicitKeychainServiceOverride: testCase.service,
            isExecutable: { testCase.executable.contains($0) }
        )
        #expect(got?.path == testCase.want)
    }

    static let loginItemLocatorCases: [(name: String, debug: Bool, fake: String?, service: String?, want: String?)] = [
        ("debug with a fake and a throwaway service", true, "/fake/login-item", "com.example.walk", "/fake/login-item"),
        ("debug with a fake and no throwaway service", true, "/fake/login-item", nil, nil),
        ("debug naming the real service", true, "/fake/login-item", KeychainCredentialStore.defaultService, nil),
        ("debug with an empty path", true, "", "com.example.walk", nil),
        ("debug with no fake path", true, nil, "com.example.walk", nil),
        ("release ignores a fake path", false, "/fake/login-item", "com.example.walk", nil),
    ]

    @Test("the login item fake is honoured only in a debug build that also names a throwaway service", arguments: loginItemLocatorCases)
    func loginItemLocator(_ testCase: (name: String, debug: Bool, fake: String?, service: String?, want: String?)) {
        let got = LoginItemFakeLocator.resolve(
            isDebugBuild: testCase.debug,
            fakePath: testCase.fake,
            explicitKeychainServiceOverride: testCase.service
        )
        #expect(got?.path == testCase.want)
    }

    static let loginItemCases: [(name: String, start: String?, register: LoginItemStatus?, unregister: LoginItemStatus?)] = [
        ("no file reads disabled, and register turns it on", nil, .enabled, .disabled),
        ("unreadable content reads disabled", "gibberish", .enabled, .disabled),
        ("enabled stays enabled and turns off", "enabled", .enabled, .disabled),
        ("waiting for approval stays waiting, and turns off", "requiresApproval", .requiresApproval, .disabled),
        ("no helper in this build fails both ways", "notFound", nil, nil),
    ]

    @Test("the file-backed login item follows its state file and never touches the system's", arguments: loginItemCases)
    func fileBackedLoginItem(_ testCase: (name: String, start: String?, register: LoginItemStatus?, unregister: LoginItemStatus?)) throws {
        func manager() throws -> (FileBackedLoginItemManager, URL) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fake-login-item-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("login-item")
            if let start = testCase.start {
                try start.write(to: file, atomically: true, encoding: .utf8)
            }
            return (FileBackedLoginItemManager(stateFile: file), directory)
        }

        let (registering, registerDirectory) = try manager()
        defer { try? FileManager.default.removeItem(at: registerDirectory) }
        if let want = testCase.register {
            try registering.register()
            #expect(registering.status == want)
        } else {
            #expect(throws: LoginItemUnavailableError.notFound) { try registering.register() }
            #expect(registering.status == .notFound)
        }

        let (unregistering, unregisterDirectory) = try manager()
        defer { try? FileManager.default.removeItem(at: unregisterDirectory) }
        if let want = testCase.unregister {
            try unregistering.unregister()
            #expect(unregistering.status == want)
        } else {
            #expect(throws: LoginItemUnavailableError.notFound) { try unregistering.unregister() }
        }
    }

    private struct FakeSystemLoginItem: SystemLoginItem {
        let status: SystemLoginItemStatus
        let registerFailure: (any Error)?
        func register() throws { if let registerFailure { throw registerFailure } }
        func unregister() throws {}
    }

    static let systemLoginItemCases: [(name: String, system: SystemLoginItemStatus, want: LoginItemStatus)] = [
        ("enabled reads on", .enabled, .enabled),
        ("waiting for approval reads as approval", .requiresApproval, .requiresApproval),
        ("never registered reads off, so a fresh install can turn it on", .notFound, .disabled),
        ("registered and removed reads off", .notRegistered, .disabled),
    ]

    @Test("the system login item maps every system status, and a fresh install's notFound is off, never unavailable", arguments: systemLoginItemCases)
    func systemLoginItem(_ testCase: (name: String, system: SystemLoginItemStatus, want: LoginItemStatus)) {
        let manager = SystemLoginItemManager(item: FakeSystemLoginItem(status: testCase.system, registerFailure: nil))
        #expect(manager.status == testCase.want)
    }

    @Test("a refused registration reaches the caller with the system's own reason")
    func systemLoginItemRefusal() {
        struct Refused: Error, LocalizedError { var errorDescription: String? { "Operation not permitted" } }
        let manager = SystemLoginItemManager(item: FakeSystemLoginItem(status: .notFound, registerFailure: Refused()))
        #expect(throws: Refused.self) { try manager.register() }
        #expect(LoginItemFailure.reason(for: Refused()) == "Operation not permitted.")
        #expect(LoginItemFailure.reason(for: LoginItemUnavailableError.notFound) == "This build can't open at login.")
    }
}

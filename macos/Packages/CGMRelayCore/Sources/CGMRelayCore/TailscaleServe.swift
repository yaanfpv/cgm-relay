import Foundation

/// TailscaleStatus is what this Mac's Tailscale can currently do for the
/// relay. `unknown` is only the state before the first check has finished.
public enum TailscaleStatus: Sendable, Equatable {
    case unknown
    /// absent: no Tailscale command line tool was found on this Mac.
    case absent
    /// stopped: Tailscale is installed but not connected, or this Mac is
    /// not signed in to it, or it did not answer.
    case stopped
    /// running: connected, with this Mac's own tailnet DNS name (no
    /// trailing dot).
    case running(name: String)
}

/// TailscaleStatusParser reads `tailscale status --json`.
public enum TailscaleStatusParser {
    /// parse answers `running` only for a `BackendState` of "Running" with
    /// a plausible `Self.DNSName`, and `stopped` for everything else, an
    /// unreadable answer included. The name is shown and put into a QR
    /// code, so anything that is not a plain DNS name is refused.
    public static func parse(_ data: Data) -> TailscaleStatus {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            root["BackendState"] as? String == "Running",
            let this = root["Self"] as? [String: Any],
            let rawName = this["DNSName"] as? String
        else {
            return .stopped
        }
        let name = rawName.hasSuffix(".") ? String(rawName.dropLast()) : rawName
        return isPlainDNSName(name) ? .running(name: name) : .stopped
    }

    private static func isPlainDNSName(_ name: String) -> Bool {
        guard name.contains("."), name.count <= 253 else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")
        return name.allSatisfy(allowed.contains) && !name.hasPrefix(".") && !name.contains("..")
    }
}

/// TailscaleServeCommand is the one command each Tailscale action runs.
/// The app shows `displayText` to the person before they click, and runs
/// exactly `arguments`, so what is shown and what runs are one value.
public struct TailscaleServeCommand: Sendable, Equatable {
    public let arguments: [String]

    /// enableHTTPS serves HTTPS on the tailnet at `httpsPort` by proxying
    /// to the relay's own port on this Mac, and keeps serving after the
    /// command exits. The app runs it only after reading that port as free.
    public static func enableHTTPS(proxyingToPort port: Int, httpsPort: Int) -> TailscaleServeCommand {
        TailscaleServeCommand(arguments: ["serve", "--bg", "--https=\(httpsPort)", TailscaleServeConfig.proxyTarget(forRelayPort: port)])
    }

    /// disableHTTPS removes the handler at "/" on `httpsPort`, the mount
    /// point enableHTTPS created (`--set-path=/` names that one path).
    public static func disableHTTPS(httpsPort: Int) -> TailscaleServeCommand {
        TailscaleServeCommand(arguments: ["serve", "--https=\(httpsPort)", "--set-path=/", "off"])
    }

    /// displayText is the command as a person would type it.
    public var displayText: String {
        (["tailscale"] + arguments).joined(separator: " ")
    }
}

/// TailscaleServeConfig is what `tailscale serve status --json` says is
/// already being served, reduced to what the app must not disturb: which
/// tailnet ports are taken, and what this Mac's own background handlers do.
/// Field names are Tailscale's own ServeConfig type (ipn/serve.go): `TCP`
/// (port to TCPPortHandler, whose `HTTPS` flag says the port terminates
/// TLS), `Web` (host:port to WebServerConfig, whose `Handlers` map a path to
/// an HTTPHandler with `Proxy`), and `Foreground` (session to a nested
/// ServeConfig). Only the top-level entries are the background configuration
/// this app creates; a foreground session's ports are taken, never ours.
public struct TailscaleServeConfig: Sendable, Equatable {
    /// occupiedPorts is every port with a TCP or web entry, for any host and
    /// in any foreground session.
    public var occupiedPorts: Set<Int>
    /// httpsPorts is every port whose top-level TCP handler terminates HTTPS.
    public var httpsPorts: Set<Int>
    /// rootProxies is, per top-level web entry (see webKey), the `Proxy` of
    /// the handler at "/" (an empty string when the handler there is not a
    /// proxy).
    public var rootProxies: [String: String]

    public init(occupiedPorts: Set<Int> = [], httpsPorts: Set<Int> = [], rootProxies: [String: String] = [:]) {
        self.occupiedPorts = occupiedPorts
        self.httpsPorts = httpsPorts
        self.rootProxies = rootProxies
    }

    /// proxyTarget is the address CGM Relay's own handler proxies to, as
    /// Tailscale stores it.
    public static func proxyTarget(forRelayPort port: Int) -> String {
        "http://127.0.0.1:\(port)"
    }

    /// webKey is a web entry's name in Tailscale's own "host:port" form, with
    /// the host lowercased and any trailing dot dropped so DNS spellings of
    /// one name compare equal.
    public static func webKey(host: String, port: Int) -> String {
        var name = host.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        return "\(name):\(port)"
    }

    /// isOurs is whether the app's own handler is serving on `httpsPort`:
    /// this Mac's own name (`host`) on that port has a top-level handler at
    /// "/" proxying to the relay's port, and the port terminates HTTPS.
    public func isOurs(host: String, httpsPort: Int, relayPort: Int) -> Bool {
        httpsPorts.contains(httpsPort)
            && rootProxies[Self.webKey(host: host, port: httpsPort)] == Self.proxyTarget(forRelayPort: relayPort)
    }
}

/// TailscaleServeConfigParser reads `tailscale serve status --json`.
public enum TailscaleServeConfigParser {
    /// parse answers nil for anything that is not a JSON object (or the
    /// `null` Tailscale prints for no configuration at all, which is an
    /// empty config), so an unreadable answer is never mistaken for "nothing
    /// is served".
    public static func parse(_ data: Data) -> TailscaleServeConfig? {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        if json is NSNull { return TailscaleServeConfig() }
        guard let root = json as? [String: Any] else { return nil }
        var config = TailscaleServeConfig()
        collect(root, isBackground: true, into: &config)
        return config
    }

    private static func collect(_ node: [String: Any], isBackground: Bool, into config: inout TailscaleServeConfig) {
        for (key, value) in node["TCP"] as? [String: Any] ?? [:] {
            guard let port = Int(key) else { continue }
            config.occupiedPorts.insert(port)
            if isBackground, (value as? [String: Any])?["HTTPS"] as? Bool == true {
                config.httpsPorts.insert(port)
            }
        }
        for (hostPort, value) in node["Web"] as? [String: Any] ?? [:] {
            guard let colon = hostPort.lastIndex(of: ":"), let port = Int(hostPort[hostPort.index(after: colon)...]) else { continue }
            config.occupiedPorts.insert(port)
            guard isBackground else { continue }
            let handlers = (value as? [String: Any])?["Handlers"] as? [String: Any] ?? [:]
            if let root = handlers["/"] as? [String: Any] {
                let key = TailscaleServeConfig.webKey(host: String(hostPort[..<colon]), port: port)
                config.rootProxies[key] = root["Proxy"] as? String ?? ""
            }
        }
        for nested in (node["Foreground"] as? [String: Any] ?? [:]).values {
            if let nestedNode = nested as? [String: Any] { collect(nestedNode, isBackground: false, into: &config) }
        }
    }
}

/// TailscaleHTTPSState is where HTTPS serving for the relay stands, decided
/// only from what Tailscale itself reports.
public enum TailscaleHTTPSState: Sendable, Equatable {
    /// unknown: not read yet.
    case unknown
    /// unavailable: Tailscale is absent or not running.
    case unavailable
    /// unreadable: Tailscale runs but its serve settings could not be read.
    case unreadable
    /// off: the app's handler is not serving; HTTPS can be turned on at
    /// `port`, 443 or the nearest port above it with no entry of any kind.
    case off(port: Int)
    /// noFreePort: every port from 443 up is taken by something else.
    case noFreePort
    /// on: this Mac's own name serves the relay at "/" over HTTPS on `port`.
    case on(port: Int)

    /// preferredPort is where CGM Relay serves HTTPS when it can: 443, so the
    /// address needs no port. When something else holds it, the nearest free
    /// port above it is used. Tailscale's serve command accepts any HTTPS port
    /// up to 65535 (srvTypeAndPortFromFlags in cmd/tailscale/cli/serve_v2.go);
    /// only Funnel, which CGM Relay never uses, is limited to 443, 8443 and
    /// 10000.
    public static let preferredPort = 443
    static let highestPort = 65535

    /// nearestFreePort is preferredPort, or the first port above it that
    /// nothing in occupied holds.
    static func nearestFreePort(occupied: Set<Int>) -> Int? {
        (preferredPort...highestPort).first { !occupied.contains($0) }
    }

    /// isOn is whether the app's handler is serving.
    public var isOn: Bool {
        if case .on = self { return true }
        return false
    }

    /// portLockNote is why the port must not change, nil when it may. Only
    /// the port is ever fixed, never the choice of a way, and only while the
    /// app's handler is serving, whatever way is chosen, since changing the
    /// port then would strand it. While Tailscale cannot be asked, the lock
    /// follows what the app last confirmed about its own handler (lastObserved):
    /// serving keeps the port fixed, a confirmed removal leaves it free even
    /// after Tailscale stops. Only with nothing ever observed does it stay
    /// careful, and only for a person who chose Tailscale HTTPS, who may have
    /// set it up before this version kept the observation.
    public func portLockNote(chosen: Bool, lastObserved: HandlerObservation?) -> String? {
        switch self {
        case .on:
            return "Turn off Tailscale HTTPS to change the port."
        case .off, .noFreePort:
            return nil
        case .unknown, .unavailable, .unreadable:
            switch lastObserved {
            case .serving:
                return "Tailscale HTTPS was on when CGM Relay last checked. Connect Tailscale to change the port."
            case .notServing:
                return nil
            case nil:
                return chosen ? "CGM Relay can't tell whether Tailscale HTTPS is still set up. Connect Tailscale to change the port." : nil
            }
        }
    }

    public func locksPort(chosen: Bool, lastObserved: HandlerObservation?) -> Bool {
        portLockNote(chosen: chosen, lastObserved: lastObserved) != nil
    }

    public static func evaluate(status: TailscaleStatus, config: TailscaleServeConfig?, relayPort: Int) -> TailscaleHTTPSState {
        switch status {
        case .unknown:
            return .unknown
        case .absent, .stopped:
            return .unavailable
        case .running(let name):
            guard let config else { return .unreadable }
            if let ours = config.httpsPorts.sorted().first(where: { config.isOurs(host: name, httpsPort: $0, relayPort: relayPort) }) {
                return .on(port: ours)
            }
            if let free = nearestFreePort(occupied: config.occupiedPorts) {
                return .off(port: free)
            }
            return .noFreePort
        }
    }

    /// address is the https address a follower app uses: the tailnet name,
    /// with the port only when it is not 443.
    public static func address(name: String, port: Int) -> String {
        port == 443 ? "https://\(name)" : "https://\(name):\(port)"
    }
}

/// HandlerObservation is what the app last confirmed about its own handler in
/// Tailscale. It is kept beside the saved settings, so a launch with
/// Tailscale stopped still knows. Only a successful read of Tailscale's serve
/// settings while it runs confirms anything; a read that cannot be made
/// leaves the last observation as it was.
public enum HandlerObservation: String, Codable, Sendable, Equatable {
    case serving
    case notServing

    /// observing is what a read confirms, nil when it confirms nothing.
    public static func observing(_ state: TailscaleHTTPSState) -> HandlerObservation? {
        switch state {
        case .on: return .serving
        case .off, .noFreePort: return .notServing
        case .unknown, .unavailable, .unreadable: return nil
        }
    }
}

/// TailscaleChangeResult is how one click on turn on or turn off ended.
public enum TailscaleChangeResult: Sendable, Equatable {
    /// done: our change is in place (the check after the command found it).
    case done
    /// unchanged: the read before the first command already showed the
    /// wanted state, so nothing was run.
    case unchanged
    /// refused: the read before a command no longer showed what the screen
    /// offered (the port is not free, or the entry is not ours), so that
    /// command was not run.
    case refused
    /// failed: every attempt ended without our change in place, or the
    /// failure is one only the person can fix.
    case failed(TailscaleServeOutcome)
}

/// TailscaleChange runs a turn on or turn off with quiet retries. Every
/// attempt starts again from a fresh read of Tailscale, runs the one shown
/// command only if that read still shows what the screen offered, and then
/// asks one thing: did our own change stick. A transient failure (an
/// unexplained error, or our change not found afterwards) is retried after a
/// short wait; a failure only the person can fix, a timeout included, is
/// returned at once.
public enum TailscaleChange {
    /// retryWaits is the wait before each retry, so the attempts number one
    /// more than the waits.
    public static let retryWaits: [Duration] = [.seconds(1), .seconds(2)]

    /// isForPersonToFix is whether retrying cannot help. A timeout counts:
    /// `tailscale serve` waits for HTTPS certificates to be turned on, so
    /// a timeout is ordinarily that case, and retrying would only make the
    /// person wait longer for the same sentence.
    static func isForPersonToFix(_ outcome: TailscaleServeOutcome) -> Bool {
        outcome == .httpsNotEnabled || outcome == .stopped || outcome == .timedOut
    }

    public static func turnOn(
        shownPort: Int,
        relayPort: Int,
        controller: any TailscaleControlling,
        read: () async -> TailscaleHTTPSState,
        wait: (Duration) async -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) async -> TailscaleChangeResult {
        var last = TailscaleServeOutcome.other
        for attempt in 0...retryWaits.count {
            let before = await read()
            if before.isOn { return attempt == 0 ? .unchanged : .done }
            guard case .off(let port) = before, port == shownPort else { return .refused }
            let outcome = await controller.enableHTTPS(proxyingToPort: relayPort, httpsPort: port)
            if await read().isOn { return .done }
            if isForPersonToFix(outcome) { return .failed(outcome) }
            last = outcome == .succeeded ? .other : outcome
            if attempt < retryWaits.count { await wait(retryWaits[attempt]) }
        }
        return .failed(last)
    }

    public static func turnOff(
        shownPort: Int,
        controller: any TailscaleControlling,
        read: () async -> TailscaleHTTPSState,
        wait: (Duration) async -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) async -> TailscaleChangeResult {
        var last = TailscaleServeOutcome.other
        for attempt in 0...retryWaits.count {
            let before = await read()
            guard case .on(let port) = before, port == shownPort else {
                if attempt == 0 { return .refused }
                return before.isOn ? .refused : .done
            }
            let outcome = await controller.disableHTTPS(httpsPort: port)
            if !(await read().isOn) { return .done }
            if isForPersonToFix(outcome) { return .failed(outcome) }
            last = outcome == .succeeded ? .other : outcome
            if attempt < retryWaits.count { await wait(retryWaits[attempt]) }
        }
        return .failed(last)
    }
}

/// TailscaleServeOutcome is how a Tailscale change ended, from its exit
/// code and what it printed. Nothing it printed is ever shown: each outcome
/// has a sentence of ours.
public enum TailscaleServeOutcome: Sendable, Equatable {
    case succeeded
    /// httpsNotEnabled: HTTPS certificates are not turned on for the tailnet.
    case httpsNotEnabled
    case stopped
    /// timedOut: Tailscale did not finish, ordinarily because it is
    /// waiting for HTTPS certificates to be turned on.
    case timedOut
    /// settingsChanged: the re-read just before the command no longer shows
    /// what the screen offered (the port is not free, or the entry is no
    /// longer the app's), so nothing was run.
    case settingsChanged
    case other

    /// helpURL is Tailscale's own page on turning on HTTPS certificates,
    /// offered beside the outcomes that need it.
    public var helpURL: URL? {
        switch self {
        case .httpsNotEnabled, .timedOut:
            return URL(string: "https://tailscale.com/kb/1153/enabling-https")
        case .succeeded, .stopped, .settingsChanged, .other:
            return nil
        }
    }

    /// message is the plain sentence for a failed outcome, or nil for
    /// success.
    public func message(turningOn: Bool) -> String? {
        switch self {
        case .succeeded:
            return nil
        case .httpsNotEnabled:
            return "HTTPS certificates aren't turned on for your tailnet yet. Turn them on, then try again."
        case .stopped:
            return "Tailscale isn't running right now. Open Tailscale and connect, then try again."
        case .timedOut:
            return "Tailscale didn't finish in time. If it needs HTTPS certificates turned on for your tailnet, do that first, then try again."
        case .settingsChanged:
            return turningOn
                ? "That port isn't free any more, so nothing was turned on. Check the command shown and try again."
                : "CGM Relay's Tailscale HTTPS is no longer set up, so nothing was changed."
        case .other:
            return turningOn
                ? "Couldn't turn on Tailscale HTTPS. Try again."
                : "Couldn't turn off Tailscale HTTPS. Try again."
        }
    }

    /// from classifies a finished Tailscale command. The printed text is
    /// read here and nowhere else, only for the words that name a cause.
    static func from(_ run: BoundedProcessOutput) -> TailscaleServeOutcome {
        switch run.result {
        case .timedOut:
            return .timedOut
        case .failedToLaunch:
            return .other
        case .exited(0):
            return .succeeded
        case .exited:
            let text = String(decoding: run.output, as: UTF8.self).lowercased()
            if text.contains("https") && (text.contains("enable") || text.contains("certificate")) {
                return .httpsNotEnabled
            }
            if text.contains("stopped") || text.contains("logged out") || text.contains("not running") || text.contains("needslogin") {
                return .stopped
            }
            return .other
        }
    }
}

/// TailscaleControlling is everything the app does with Tailscale.
/// Production code uses RealTailscaleController; a test or a walk points
/// that at a fake executable instead.
public protocol TailscaleControlling: Sendable {
    func status() async -> TailscaleStatus
    /// serveConfig is `serve status --json`: read-only, nil when unreadable.
    func serveConfig() async -> TailscaleServeConfig?
    func enableHTTPS(proxyingToPort port: Int, httpsPort: Int) async -> TailscaleServeOutcome
    func disableHTTPS(httpsPort: Int) async -> TailscaleServeOutcome
}

/// RealTailscaleController runs one Tailscale executable. It runs the two
/// serve commands above and the read-only `status --json` and
/// `serve status --json`, and nothing else. A nil executable means
/// Tailscale is absent.
public struct RealTailscaleController: TailscaleControlling {
    /// statusTimeout and changeTimeout bound each run. A change can wait on
    /// Tailscale itself, so it gets longer.
    static let defaultStatusTimeout: Duration = .seconds(10)
    static let defaultChangeTimeout: Duration = .seconds(30)

    private let executableURL: URL?
    private let runner: any BoundedProcessRunning
    private let statusTimeout: Duration
    private let changeTimeout: Duration

    /// environment is added to every run's child environment.
    /// TAILSCALE_BE_CLI makes the Tailscale.app executable behave as the
    /// command line tool: without a terminal it starts as the GUI app
    /// instead. Tailscale documents it at https://tailscale.com/kb/1080/cli
    /// (the check lives in the closed-source macOS launcher, not the open
    /// Go tree).
    static let environment = ["TAILSCALE_BE_CLI": "1"]

    public init(executableURL: URL?) {
        self.init(executableURL: executableURL, runner: RealBoundedProcessRunner(extraEnvironment: Self.environment))
    }

    init(
        executableURL: URL?,
        runner: any BoundedProcessRunning,
        statusTimeout: Duration = defaultStatusTimeout,
        changeTimeout: Duration = defaultChangeTimeout
    ) {
        self.executableURL = executableURL
        self.runner = runner
        self.statusTimeout = statusTimeout
        self.changeTimeout = changeTimeout
    }

    public func status() async -> TailscaleStatus {
        guard let executableURL else { return .absent }
        let run = await runner.runCapturingOutput(
            executableURL: executableURL,
            arguments: ["status", "--json"],
            standardInputData: Data(),
            timeout: statusTimeout
        )
        switch run.result {
        case .failedToLaunch:
            return .absent
        case .timedOut:
            return .stopped
        case .exited(0):
            return TailscaleStatusParser.parse(run.output)
        case .exited:
            return .stopped
        }
    }

    public func serveConfig() async -> TailscaleServeConfig? {
        guard let executableURL else { return nil }
        let run = await runner.runCapturingOutput(
            executableURL: executableURL,
            arguments: ["serve", "status", "--json"],
            standardInputData: Data(),
            timeout: statusTimeout
        )
        guard case .exited(0) = run.result else { return nil }
        return TailscaleServeConfigParser.parse(run.output)
    }

    public func enableHTTPS(proxyingToPort port: Int, httpsPort: Int) async -> TailscaleServeOutcome {
        await run(.enableHTTPS(proxyingToPort: port, httpsPort: httpsPort))
    }

    public func disableHTTPS(httpsPort: Int) async -> TailscaleServeOutcome {
        await run(.disableHTTPS(httpsPort: httpsPort))
    }

    private func run(_ command: TailscaleServeCommand) async -> TailscaleServeOutcome {
        guard let executableURL else { return .other }
        let run = await runner.runCapturingOutput(
            executableURL: executableURL,
            arguments: command.arguments,
            standardInputData: Data(),
            timeout: changeTimeout
        )
        return .from(run)
    }
}

/// TailscaleLocator decides which Tailscale executable a launch uses.
public enum TailscaleLocator {
    /// standardLocations are where Tailscale's command line tool lives on a
    /// Mac: inside the app bundle, which both the App Store and the
    /// standalone app ship, then the launcher the standalone app can
    /// install, then Homebrew's.
    public static let standardLocations = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
    ]

    /// resolve returns the executable to run, or nil when there is none.
    /// A release build only ever uses a standard location. A debug build
    /// never touches the real Tailscale: it uses only a fake named by
    /// `fakePath`, and only when the launch also names a throwaway
    /// Keychain service, exactly as the synthetic account seed does.
    public static func resolve(
        isDebugBuild: Bool,
        fakePath: String?,
        explicitKeychainServiceOverride: String?,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        if isDebugBuild {
            guard
                let fakePath, !fakePath.isEmpty,
                SyntheticAccountSeeder.isThrowawayService(explicitKeychainServiceOverride),
                isExecutable(fakePath)
            else {
                return nil
            }
            return URL(fileURLWithPath: fakePath)
        }
        return standardLocations.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }
}

extension ConnectPaneAddressState {
    /// decideTailscaleHTTPS is the address for a person who chose Tailscale
    /// HTTPS: this Mac's tailnet name over https, offered only while the
    /// engine runs, Tailscale is connected and Tailscale itself reports the
    /// app's handler serving over HTTPS under that name. Anything else is a
    /// plain reason. boundHost is the host the running engine is bound to,
    /// nil while nothing runs.
    public static func decideTailscaleHTTPS(boundHost: String?, tailscale: TailscaleStatus, https: TailscaleHTTPSState) -> ConnectPaneAddressState {
        guard boundHost != nil else {
            return .unavailable(reason: "The engine isn't running right now.")
        }
        switch https {
        case .unknown:
            return .unavailable(reason: "Checking Tailscale…")
        case .unavailable:
            return .unavailable(reason: "Waiting for Tailscale to connect.")
        case .unreadable:
            return .unavailable(reason: "Couldn't read Tailscale's settings right now.")
        case .off, .noFreePort:
            return .unavailable(reason: "Tailscale HTTPS is off, so followers can't reach this Mac. Turn it on, or choose another way.")
        case .on(let port):
            guard case .running(let name) = tailscale else {
                return .unavailable(reason: "Waiting for Tailscale to connect.")
            }
            return .ready(address: TailscaleHTTPSState.address(name: name, port: port))
        }
    }
}

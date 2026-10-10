import Foundation
import os

/// AccountCheckExitCode names every exit status `cgm-relay check-account`
/// can return. Each value must always agree with its counterpart constant
/// in cmd/cgm-relay/main.go.
public enum AccountCheckExitCode {
    public static let signedIn: Int32 = 0
    public static let invalidCredentials: Int32 = 10
    public static let termsNotAccepted: Int32 = 11
    public static let noConnections: Int32 = 12
    public static let rateLimited: Int32 = 13
    public static let unreachable: Int32 = 14
}

/// AccountCheckOutcome is what the Account pane shows after running
/// check-account: either success, or one plain sentence naming why not.
public enum AccountCheckOutcome: Sendable, Equatable {
    case signedIn
    case invalidCredentials
    case termsNotAccepted
    case noConnections
    case rateLimited
    case unreachable
    /// launchFailed is this app failing to start the check at all.
    case launchFailed
    /// timedOut is the check running past RealAccountChecker.runTimeout and
    /// being ended.
    case timedOut
    /// malformedEmail is an email that is not local@domain.tld after
    /// trimming; nothing is started or sent for it.
    case malformedEmail
    /// other covers every exit code check-account did not otherwise
    /// define.
    case other
    /// saveFailed is LibreLinkUp confirming the account, followed by this
    /// Mac's own Keychain write of the email and password failing: the
    /// account itself is fine, but nothing was saved, so the pane must
    /// say so rather than either claiming "Signed in" or repeating one of
    /// the LibreLinkUp-side messages above, none of which fit.
    case saveFailed

    /// from maps a check-account exit code to the outcome the Account
    /// pane shows.
    public static func from(exitCode: Int32) -> AccountCheckOutcome {
        switch exitCode {
        case AccountCheckExitCode.signedIn: return .signedIn
        case AccountCheckExitCode.invalidCredentials: return .invalidCredentials
        case AccountCheckExitCode.termsNotAccepted: return .termsNotAccepted
        case AccountCheckExitCode.noConnections: return .noConnections
        case AccountCheckExitCode.rateLimited: return .rateLimited
        case AccountCheckExitCode.unreachable: return .unreachable
        default: return .other
        }
    }

    /// message is the plain sentence the Account pane shows for this
    /// outcome, or nil for .signedIn, which the pane renders as "Signed in
    /// as <email>" using the email the person just entered instead of a
    /// fixed sentence here.
    public var message: String? {
        switch self {
        case .signedIn:
            return nil
        case .invalidCredentials:
            return "LibreLinkUp didn't recognize that email or password."
        case .termsNotAccepted:
            return "LibreLinkUp needs its updated terms accepted. Open the LibreLinkUp app, sign in, and accept the prompt, then try again."
        case .noConnections:
            return "Signed in, but nobody has shared readings with this account yet. Ask the person you want to follow to invite this email from their LibreLink app."
        case .rateLimited:
            return "LibreLinkUp is asking us to slow down. Wait a few minutes and try again."
        case .unreachable:
            return "Couldn't reach LibreLinkUp. Check your internet connection and try again."
        case .launchFailed:
            return "CGM Relay couldn't start its sign-in check. Try again."
        case .timedOut:
            return "LibreLinkUp took too long to answer. Try again."
        case .malformedEmail:
            return AccountEmail.prompt
        case .other:
            return "Something went wrong checking that account. Try again."
        case .saveFailed:
            return "Signed in, but we couldn't save your account. Try again."
        }
    }
}

/// AccountEmail is the one rule for what counts as an email worth sending
/// to LibreLinkUp: local@domain.tld once trimmed. It only catches a typo
/// before anything is sent; LibreLinkUp alone decides whether the account
/// exists.
public enum AccountEmail {
    /// prompt is what the Account pane says under a malformed email.
    public static let prompt = "Enter the email you use for LibreLinkUp."

    /// trimmedIfValid is the email with surrounding whitespace removed, or
    /// nil when it is not a local part, one @, and a domain of at least two
    /// non-empty dot-separated labels, with no whitespace inside.
    public static func trimmedIfValid(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return nil }
        return trimmed
    }
}

/// AccountCheckLogging receives the one line RealAccountChecker writes for
/// a check that failed for a reason the person is told only in general
/// terms. Production writes to the unified log; tests record the lines.
public protocol AccountCheckLogging: Sendable {
    func record(_ line: String)
}

/// UnifiedAccountCheckLog writes to the unified log under the app's own
/// subsystem. Every line it is given is already sanitized.
public struct UnifiedAccountCheckLog: AccountCheckLogging {
    private let logger = Logger(subsystem: "com.yaanfpv.cgmrelay", category: "account")

    public init() {}

    public func record(_ line: String) {
        logger.error("\(line, privacy: .public)")
    }
}

/// AccountCheckReason makes the engine's own stderr text safe to log.
enum AccountCheckReason {
    static let maxLength = 160
    private static let removed = "[removed]"

    /// sanitize keeps the first line of what the engine printed, with the
    /// email and password it was given taken out wherever they appear,
    /// every word that looks like an address or a token or key replaced,
    /// anything from the first brace or angle bracket on dropped (a
    /// provider body), control characters removed, and the result capped.
    static func sanitize(_ raw: String, email: String, password: String) -> String {
        var text = raw
        for secret in [password, email] where !secret.isEmpty {
            text = text.replacingOccurrences(of: secret, with: removed)
        }
        if let cut = text.firstIndex(where: { $0 == "{" || $0 == "<" }) {
            text = String(text[..<cut]) + "[body omitted]"
        }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { word -> String in
            let isTokenLike = word.count >= 24 && word.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+/=_-.".contains($0)) }
            return word.contains("@") || isTokenLike ? removed : String(word)
        }
        let cleaned = words.joined(separator: " ").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(cleaned).prefix(maxLength))
    }
}

/// AccountCheckRunning runs `cgm-relay check-account` and reports the
/// outcome. Production code uses RealAccountChecker; tests use a fake
/// that returns a scripted outcome with no process ever started.
public protocol AccountCheckRunning: Sendable {
    func checkAccount(email: String, password: String, librelinkupBaseURL: String?) async -> AccountCheckOutcome
}

/// RealAccountChecker runs the bundled engine's check-account command
/// exactly as EngineSupervisor runs serve: the email and password go on
/// stdin, never as an argument or an environment variable.
public struct RealAccountChecker: AccountCheckRunning {
    /// runTimeout bounds this app's own wait for the child, comfortably
    /// longer than the engine's own internal bounded timeout on its
    /// LibreLinkUp request, so a child that is merely slow is never cut
    /// off before it reports LibreLinkUp's own answer.
    public static let runTimeout: Duration = .seconds(45)

    private let engineURL: URL
    private let runner: any BoundedProcessRunning
    private let timeout: Duration
    private let log: any AccountCheckLogging

    public init(
        engineURL: URL,
        runner: any BoundedProcessRunning = RealBoundedProcessRunner(),
        timeout: Duration = RealAccountChecker.runTimeout,
        log: any AccountCheckLogging = UnifiedAccountCheckLog()
    ) {
        self.engineURL = engineURL
        self.runner = runner
        self.timeout = timeout
        self.log = log
    }

    public func checkAccount(email: String, password: String, librelinkupBaseURL: String?) async -> AccountCheckOutcome {
        var payload: [String: String] = [
            "librelinkup_email": email,
            "librelinkup_password": password,
        ]
        if let librelinkupBaseURL {
            payload["librelinkup_base_url"] = librelinkupBaseURL
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            log.record("check-account launch-failed: could not encode the request")
            return .launchFailed
        }

        let run = await runner.runCapturingOutput(
            executableURL: engineURL,
            arguments: ["check-account"],
            standardInputData: data,
            timeout: timeout
        )
        switch run.result {
        case .exited(let code):
            let outcome = AccountCheckOutcome.from(exitCode: code)
            if outcome == .other {
                let reason = AccountCheckReason.sanitize(String(decoding: run.output, as: UTF8.self), email: email, password: password)
                log.record("check-account unknown-exit status=\(code) reason=\(reason)")
            }
            return outcome
        case .timedOut:
            log.record("check-account timed-out after \(timeout.components.seconds)s; the check was ended")
            return .timedOut
        case .failedToLaunch:
            log.record("check-account launch-failed: the engine could not be started")
            return .launchFailed
        }
    }
}

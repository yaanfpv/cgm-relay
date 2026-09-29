import Foundation

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
    /// other covers every exit code check-account did not otherwise
    /// define, this process failing to launch it at all, and the run
    /// taking longer than RealAccountChecker.runTimeout.
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
        case .other:
            return "Something went wrong checking that account. Try again."
        case .saveFailed:
            return "Signed in, but we couldn't save your account. Try again."
        }
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

    public init(engineURL: URL, runner: any BoundedProcessRunning = RealBoundedProcessRunner()) {
        self.engineURL = engineURL
        self.runner = runner
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
            return .other
        }

        let result = await runner.run(
            executableURL: engineURL,
            arguments: ["check-account"],
            standardInputData: data,
            timeout: Self.runTimeout
        )
        switch result {
        case .exited(let code):
            return .from(exitCode: code)
        case .timedOut, .failedToLaunch:
            return .other
        }
    }
}

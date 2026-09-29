import CGMRelayCore
import Foundation

/// FakeAccountCheckRunning returns a scripted outcome and records the
/// credentials it was called with, so AccountSignIn is tested with no
/// check-account process ever started.
final class FakeAccountCheckRunning: AccountCheckRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let outcome: AccountCheckOutcome
    private var _calls: [(email: String, password: String, librelinkupBaseURL: String?)] = []

    init(outcome: AccountCheckOutcome) {
        self.outcome = outcome
    }

    var calls: [(email: String, password: String, librelinkupBaseURL: String?)] {
        lock.withLock { _calls }
    }

    func checkAccount(email: String, password: String, librelinkupBaseURL: String?) async -> AccountCheckOutcome {
        lock.withLock { _calls.append((email: email, password: password, librelinkupBaseURL: librelinkupBaseURL)) }
        return outcome
    }
}

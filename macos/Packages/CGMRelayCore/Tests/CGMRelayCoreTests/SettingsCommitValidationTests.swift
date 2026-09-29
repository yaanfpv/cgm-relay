import Testing
@testable import CGMRelayCore

@Suite("Settings commit validation")
struct SettingsCommitValidationTests {
    @Test("a port inside range commits", arguments: [1024, 1337, 65535])
    func validPortCommits(_ port: Int) {
        #expect(PortCommitValidation.validate(String(port)) == .valid(port))
    }

    @Test("a non-numeric or out-of-range port is refused with a message", arguments: ["", "abc", "1023", "65536", "-5", "13 37"])
    func invalidPortIsRefused(_ text: String) {
        guard case .invalid = PortCommitValidation.validate(text) else {
            Issue.record("expected .invalid for \(text.debugDescription)")
            return
        }
    }

    @Test("a retention value inside range commits", arguments: [1, 15, 90])
    func validRetentionCommits(_ days: Int) {
        #expect(RetentionCommitValidation.validate(String(days)) == .valid(days))
    }

    @Test("a non-numeric or out-of-range retention entry is refused with a message", arguments: ["", "abc", "0", "91"])
    func invalidRetentionIsRefused(_ text: String) {
        guard case .invalid = RetentionCommitValidation.validate(text) else {
            Issue.record("expected .invalid for \(text.debugDescription)")
            return
        }
    }

    @Test("lowering retention needs confirmation")
    func loweringNeedsConfirmation() {
        #expect(RetentionCommitDecision.decide(current: 15, new: 5) == .needsConfirmation)
    }

    @Test("raising or keeping retention the same commits immediately")
    func raisingOrEqualCommitsImmediately() {
        #expect(RetentionCommitDecision.decide(current: 15, new: 30) == .commitsImmediately)
        #expect(RetentionCommitDecision.decide(current: 15, new: 15) == .commitsImmediately)
    }
}

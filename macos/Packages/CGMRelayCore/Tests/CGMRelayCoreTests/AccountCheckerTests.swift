import Testing
@testable import CGMRelayCore

@Suite("AccountCheckOutcome")
struct AccountCheckOutcomeTests {
    @Test(
        "every check-account exit code maps to its own outcome",
        arguments: [
            (AccountCheckExitCode.signedIn, AccountCheckOutcome.signedIn),
            (AccountCheckExitCode.invalidCredentials, .invalidCredentials),
            (AccountCheckExitCode.termsNotAccepted, .termsNotAccepted),
            (AccountCheckExitCode.noConnections, .noConnections),
            (AccountCheckExitCode.rateLimited, .rateLimited),
            (AccountCheckExitCode.unreachable, .unreachable),
        ] as [(Int32, AccountCheckOutcome)]
    )
    func mapsKnownExitCodes(_ testCase: (Int32, AccountCheckOutcome)) {
        #expect(AccountCheckOutcome.from(exitCode: testCase.0) == testCase.1)
    }

    @Test("an exit code check-account never defines maps to other")
    func unknownExitCodeMapsToOther() {
        #expect(AccountCheckOutcome.from(exitCode: 1) == .other)
        #expect(AccountCheckOutcome.from(exitCode: -15) == .other)
        #expect(AccountCheckOutcome.from(exitCode: 42) == .other)
    }

    @Test("signedIn carries no message; every other outcome carries a non-empty one")
    func everyOutcomeHasTheRightMessagePresence() {
        #expect(AccountCheckOutcome.signedIn.message == nil)
        for outcome: AccountCheckOutcome in [.invalidCredentials, .termsNotAccepted, .noConnections, .rateLimited, .unreachable, .other, .saveFailed] {
            #expect(!(outcome.message ?? "").isEmpty)
        }
    }

    @Test("every non-signedIn outcome's message is distinct from every other")
    func messagesAreDistinct() {
        let outcomes: [AccountCheckOutcome] = [.invalidCredentials, .termsNotAccepted, .noConnections, .rateLimited, .unreachable, .other, .saveFailed]
        let messages = Set(outcomes.compactMap(\.message))
        #expect(messages.count == outcomes.count)
    }
}

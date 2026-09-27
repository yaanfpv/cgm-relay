import CGMRelayCore
import Foundation

/// FakeVirtualClock lets a test drive EngineSupervisor's and StatusPoller's
/// backoff/interval waits without a real wait: sleep(for:) polls its own
/// `elapsed` against a deadline computed at the moment it was called, and
/// advance(by:) is the test's own control over that elapsed value. Polling
/// (rather than a continuation the test must remember to resume) is
/// deliberate: an abandoned sleep -- for instance after stop() supersedes
/// it -- then just keeps polling harmlessly in the background instead of
/// risking a leaked-continuation runtime trap when a test ends without
/// ever advancing far enough to resolve it.
actor FakeVirtualClock: VirtualClock {
    private(set) var elapsed: Duration = .zero
    private(set) var sleepRequests: [Duration] = []

    func now() async -> Duration { elapsed }

    func sleep(for duration: Duration) async throws {
        sleepRequests.append(duration)
        let deadline = elapsed + duration
        while elapsed < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func advance(by duration: Duration) {
        elapsed += duration
    }
}

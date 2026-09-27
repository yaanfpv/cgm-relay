import Foundation

/// waitUntil polls `condition` until it is true or `timeout` elapses. It
/// exists because EngineSupervisor's real onExit callback hops onto a new
/// unstructured Task before touching actor state, so a test cannot know
/// exactly when that hop has actually run; polling a real, short interval
/// is simpler and clearer than instrumenting the supervisor itself just
/// for tests.
func waitUntil(
    timeout: Duration = .seconds(2),
    pollInterval: Duration = .milliseconds(2),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: pollInterval)
    }
    return await condition()
}

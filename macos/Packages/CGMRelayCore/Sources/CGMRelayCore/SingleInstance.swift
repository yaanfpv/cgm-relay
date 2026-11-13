import Foundation

/// SingleInstance decides what a newly launched copy of the app does when
/// other copies with the same bundle identifier may already be running.
public enum SingleInstance {
    public enum Decision: Equatable, Sendable {
        /// proceed: no other copy is running, so this one carries on.
        case proceed
        /// yield: another copy is running; this one hands focus to the
        /// copy with this process id and quits before touching anything.
        case yield(to: Int32)
    }

    /// decide returns .yield for the lowest process id in runningPIDs
    /// other than ownPID, or .proceed when there is none.
    public static func decide(ownPID: Int32, runningPIDs: [Int32]) -> Decision {
        guard let other = runningPIDs.filter({ $0 != ownPID }).min() else { return .proceed }
        return .yield(to: other)
    }
}

import Foundation

/// SingleInstance decides what a newly launched copy of the app does when
/// other copies with the same bundle identifier may already be running.
public enum SingleInstance {
    public enum Decision: Equatable, Sendable {
        /// proceed: no other copy is running, so this one carries on.
        case proceed
        /// yield: a copy with a lower process id is running; this one hands
        /// focus to it and quits before touching anything.
        case yield(to: Int32)
    }

    /// decide lets the copy with the lowest process id among all copies,
    /// this one included, proceed: it returns .proceed when ownPID is lower
    /// than every other pid in runningPIDs (or there is none), else
    /// .yield to the lowest other pid. Copies launched together each see
    /// the same set, so exactly one of them proceeds.
    public static func decide(ownPID: Int32, runningPIDs: [Int32]) -> Decision {
        guard let lowest = runningPIDs.filter({ $0 != ownPID }).min(), lowest < ownPID else { return .proceed }
        return .yield(to: lowest)
    }
}

import Foundation

/// SingleInstance decides what a newly launched copy of the app does when
/// other copies with the same bundle identifier may already be running.
public enum SingleInstance {
    public enum Decision: Equatable, Sendable {
        /// proceed: no copy with a lower process id is in the snapshot of
        /// running copies this one was given, so this one carries on.
        case proceed
        /// yield: a copy with a lower process id is running; this one hands
        /// focus to it and quits before touching anything.
        case yield(to: Int32)
    }

    /// decide lets the copy with the lowest process id among all copies,
    /// this one included, proceed: it returns .proceed when ownPID is lower
    /// than every other pid in runningPIDs (or there is none), else
    /// .yield to the lowest other pid. Given the same set of pids, copies
    /// agree on which one proceeds. The running-application list each copy
    /// reads is a snapshot, so copies started close together can see
    /// different sets and both proceed; the engine's store lock and port
    /// then leave only one of them relaying.
    public static func decide(ownPID: Int32, runningPIDs: [Int32]) -> Decision {
        guard let lowest = runningPIDs.filter({ $0 != ownPID }).min(), lowest < ownPID else { return .proceed }
        return .yield(to: lowest)
    }
}

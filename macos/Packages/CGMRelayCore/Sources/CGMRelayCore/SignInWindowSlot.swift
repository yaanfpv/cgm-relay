import Foundation

/// SignInWindowSlot tracks the app's one sign-in, approval or Funnel window
/// and hands out the completion handler the system calls when that window
/// ends. The system calls the handler on a queue of its own, so the handler
/// is Sendable and does not inherit the main actor; it hops to the main actor
/// to clear the slot, and only when no newer window has taken the slot since
/// the handler was made.
@MainActor
public final class SignInWindowSlot<Session: AnyObject> {
    public private(set) var session: Session?
    public private(set) var presentedURL: URL?
    private var generation = 0

    public init() {}

    /// makeCompletion returns the handler for the window about to be built. It
    /// remembers the current generation, so a window that was cancelled or
    /// replaced cannot clear its successor.
    public func makeCompletion() -> @Sendable (URL?, (any Error)?) -> Void {
        let token = generation
        return { [weak self] _, _ in
            Task { @MainActor in self?.ended(token) }
        }
    }

    /// started records the window that is now open.
    public func started(_ session: Session, url: URL) {
        self.session = session
        presentedURL = url
    }

    /// clear forgets the open window, makes every earlier completion handler
    /// a no-op and returns the window so the caller can cancel it.
    public func clear() -> Session? {
        generation += 1
        let old = session
        session = nil
        presentedURL = nil
        return old
    }

    private func ended(_ token: Int) {
        guard token == generation else { return }
        session = nil
        presentedURL = nil
    }
}

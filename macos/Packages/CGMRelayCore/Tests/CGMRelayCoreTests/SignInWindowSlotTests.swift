import Testing
import Foundation
@testable import CGMRelayCore

// SignInWindowSlot is where the app's one sign-in, approval or Funnel window
// is tracked, and the home of the completion handler the system calls when
// that window ends. The handler is called by the system on a queue of its own,
// never the main thread. No existing test file covers it, so it gets its own.

/// FakeWindowSession stands in for the system's web authentication session,
/// which the slot only holds on to.
private final class FakeWindowSession {}

private struct WindowClosedByPerson: Error {}

/// The three kinds of page the built-in route opens in the window.
private let pages: [(kind: String, status: BuiltInStatus)] = [
    ("sign-in", BuiltInStatus(state: "needs-login", loginURL: "https://login.tailscale.com/a/abc123")),
    ("approval", BuiltInStatus(state: "needs-approval", approveURL: "https://login.tailscale.com/admin/machines/100.64.0.7")),
    ("Funnel", BuiltInStatus(state: "needs-funnel", funnelURL: "https://login.tailscale.com/f/abc123")),
]

private func pageURL(_ status: BuiltInStatus) -> URL {
    switch BuiltInRouteState.from(status) {
    case .signIn(let url), .approve(let url), .enableFunnel(let url): return url
    default: preconditionFailure("not a page-opening state: \(status)")
    }
}

/// callOffMain calls the handler on a dispatch queue that is not the main
/// one, as the system does from its XPC reply queue, and returns once it has
/// returned. The test resumes on the main actor after the handler's own
/// main-actor update was queued, so the update has run by then.
@MainActor
private func callOffMain(
    _ handler: @escaping @Sendable (URL?, (any Error)?) -> Void,
    url: URL?,
    error: (any Error)?
) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue(label: "test.system-reply-queue").async {
            handler(url, error)
            continuation.resume()
        }
    }
}

@Suite("SignInWindowSlot")
@MainActor
struct SignInWindowSlotTests {
    @Test("a window that ends from the system's own queue clears the slot, whether the person closed it or it completed", arguments: pages.map(\.kind))
    func endFromOffMainClearsSlot(kind: String) async throws {
        let url = pageURL(try #require(pages.first { $0.kind == kind }).status)
        for (label, result) in [
            ("closed by the person", (nil as URL?, WindowClosedByPerson() as (any Error)?)),
            ("completed", (URL(string: "cgm-relay-built-in-never://done"), nil as (any Error)?)),
        ] {
            let slot = SignInWindowSlot<FakeWindowSession>()
            let completion = slot.makeCompletion()
            let session = FakeWindowSession()
            slot.started(session, url: url)
            #expect(slot.session === session && slot.presentedURL == url, "\(kind) window is tracked while open")

            await callOffMain(completion, url: result.0, error: result.1)

            #expect(slot.session == nil, "\(kind) window \(label): session cleared")
            #expect(slot.presentedURL == nil, "\(kind) window \(label): nothing presented")
        }
    }

    @Test("a window the app cancels is handed back to cancel, and the system's later completion call from its own queue changes nothing")
    func appCancelThenSystemCompletion() async {
        let slot = SignInWindowSlot<FakeWindowSession>()
        let completion = slot.makeCompletion()
        let session = FakeWindowSession()
        slot.started(session, url: pageURL(pages[0].status))

        let handedBack = slot.clear()
        #expect(handedBack === session, "clear returns the open session so the app can cancel it")
        #expect(slot.session == nil && slot.presentedURL == nil)

        await callOffMain(completion, url: nil, error: WindowClosedByPerson())

        #expect(slot.session == nil && slot.presentedURL == nil)
    }

    @Test("the late completion of a window the app replaced never clears the window that replaced it")
    func staleCompletionKeepsNewerWindow() async {
        let slot = SignInWindowSlot<FakeWindowSession>()
        let firstCompletion = slot.makeCompletion()
        slot.started(FakeWindowSession(), url: pageURL(pages[0].status))

        // The route moved from sign-in to approval: the first window is
        // cancelled and the approval page takes its place.
        _ = slot.clear()
        let secondCompletion = slot.makeCompletion()
        let second = FakeWindowSession()
        let secondURL = pageURL(pages[1].status)
        slot.started(second, url: secondURL)

        await callOffMain(firstCompletion, url: nil, error: WindowClosedByPerson())

        #expect(slot.session === second, "the newer window is still tracked")
        #expect(slot.presentedURL == secondURL)

        await callOffMain(secondCompletion, url: nil, error: WindowClosedByPerson())

        #expect(slot.session == nil && slot.presentedURL == nil, "the newer window's own end clears it")
    }

    @Test("completions arriving from several system queues at once leave the slot cleared")
    func concurrentCompletions() async {
        let slot = SignInWindowSlot<FakeWindowSession>()
        let completion = slot.makeCompletion()
        slot.started(FakeWindowSession(), url: pageURL(pages[2].status))

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { await callOffMain(completion, url: nil, error: WindowClosedByPerson()) }
            }
        }

        #expect(slot.session == nil && slot.presentedURL == nil)
    }
}

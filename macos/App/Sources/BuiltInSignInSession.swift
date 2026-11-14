import AppKit
import AuthenticationServices
import CGMRelayCore

/// BuiltInSignInSession opens the built-in route's Tailscale pages (sign in,
/// approve, turn on the public address) in the system's web authentication
/// sheet, since Google refuses to sign in inside an embedded web view. The
/// sheet's callback address is one the app never receives: the sheet ends
/// only when the person closes it or when the app cancels it the moment the
/// engine reports that step done, so Tailscale's own onboarding never shows.
/// Only a URL BuiltInRouteState.openable admits is ever opened.
@MainActor
final class BuiltInSignInSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private static let callbackScheme = "cgm-relay-built-in-never"
    private let slot = SignInWindowSlot<ASWebAuthenticationSession>()

    /// pageURL is the page a state asks the person to complete, nil for a
    /// state with none.
    static func pageURL(of route: BuiltInRouteState) -> URL? {
        switch route {
        case .signIn(let url), .approve(let url), .enableFunnel(let url): return url
        case .starting, .settingUp, .ready, .failed: return nil
        }
    }

    /// present opens route's page, replacing any sheet already open.
    func present(_ route: BuiltInRouteState) {
        guard
            let page = Self.pageURL(of: route),
            let url = BuiltInRouteState.openable(page.absoluteString)
        else { return }
        cancel()
        let next = ASWebAuthenticationSession(
            url: url,
            callback: .customScheme(Self.callbackScheme),
            completionHandler: slot.makeCompletion()
        )
        next.presentationContextProvider = self
        next.prefersEphemeralWebBrowserSession = false
        guard next.start() else { return }
        slot.started(next, url: url)
    }

    /// reconcile closes the sheet once the engine's state no longer asks for
    /// the page it shows.
    func reconcile(with route: BuiltInRouteState) {
        guard let presentedURL = slot.presentedURL else { return }
        if Self.pageURL(of: route) != presentedURL { cancel() }
    }

    func cancel() {
        slot.clear()?.cancel()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}

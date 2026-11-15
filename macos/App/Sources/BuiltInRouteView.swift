import CGMRelayCore
import SwiftUI

/// BuiltInRouteView is the built-in Tailscale route in setup and in
/// Advanced: what it means to be reachable this way, then one status row for
/// where the route is. Each state keeps the row and its slot the same size.
/// It belongs inside a Form.
struct BuiltInRouteView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section {
            row
            if let text = model.builtInTailscaleError {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = model.builtInKeyExpiry {
                SetupStatusRow(
                    name: "built-in-key",
                    title: notice.text(timeZone: .current),
                    caption: model.builtInSignInMessage ?? "Sign in again before then to keep your address.",
                    captionIsError: model.builtInSignInMessage != nil,
                    wrapsCaption: true,
                    slot: .action(BuiltInKeyExpiry.signInAgainTitle, accessibleName: "Sign in to Tailscale again") { model.signInBuiltInAgain() }
                )
            }
        } footer: {
            Text(BuiltInRouteCopy.disclosure)
        }
        .task(id: model.builtInRoute.address) {
            await model.pollBuiltInRouteUntilReady()
        }
    }

    @ViewBuilder
    private var row: some View {
        switch model.builtInRoute {
        case .starting:
            SetupStatusRow(name: "built-in", title: "Starting Tailscale…", caption: "Getting this Mac ready.", slot: .checking)
        case .signIn:
            SetupStatusRow(
                name: "built-in",
                title: "Sign in to Tailscale",
                caption: "A free account works. The page closes itself when you are done.",
                slot: .action("Sign In", accessibleName: "Sign in to Tailscale", style: .primary) { model.openBuiltInStep() }
            )
        case .approve:
            SetupStatusRow(
                name: "built-in",
                title: "Approve this Mac in Tailscale",
                caption: "Your Tailscale account asks you to approve new devices.",
                slot: .action("Approve", accessibleName: "Approve this Mac in Tailscale", style: .primary) { model.openBuiltInStep() }
            )
        case .enableFunnel:
            // After the page closes the engine needs a moment to see the
            // change, so the row says so until the recheck window has passed.
            TimelineView(.periodic(from: .now, by: 5)) { context in
                if BuiltInFunnelRecheck.isChecking(route: model.builtInRoute, sheetClosedAt: model.builtInFunnelSheetClosedAt, now: context.date) {
                    SetupStatusRow(name: "built-in", title: BuiltInFunnelRecheck.checkingTitle, caption: "This can take a moment.", slot: .checking)
                } else {
                    SetupStatusRow(
                        name: "built-in",
                        title: "Turn on your public address",
                        caption: "One click in Tailscale.",
                        slot: .action("Turn On", accessibleName: "Turn on your public address", style: .primary) { model.openBuiltInStep() }
                    )
                }
            }
        case .settingUp:
            SetupStatusRow(
                name: "built-in",
                title: "Setting up your address…",
                caption: "Checking that it answers.",
                slot: .checking
            )
        case .publishing:
            // The elapsed time moves while the state does not, so the row
            // is redrawn every half minute.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                SetupStatusRow(
                    name: "built-in",
                    title: "Your address",
                    caption: model.builtInRoute.settingsStatusText(timeZone: .current, now: context.date),
                    wrapsCaption: true,
                    slot: .checking
                )
            }
        case .notReachable:
            SetupStatusRow(
                name: "built-in",
                title: "Your address",
                caption: model.builtInRoute.settingsStatusText(timeZone: .current),
                wrapsCaption: true,
                slot: .action("Try Again", accessibleName: "Try your address again") { model.tryBuiltInAddressAgain() }
            )
        case .ready(let host, _):
            SetupStatusRow(name: "built-in", title: "Your address", caption: host, captionIsMonospaced: true, slot: .done(model.builtInRoute.settingsStatusText(timeZone: .current)))
        case .notAnswering:
            SetupStatusRow(
                name: "built-in",
                title: "Your address",
                caption: model.builtInRoute.settingsStatusText(timeZone: .current),
                captionIsError: true,
                wrapsCaption: true,
                slot: .action("Try Again", accessibleName: "Try your address again") { model.tryBuiltInAddressAgain() }
            )
        case .waitingForInternet:
            SetupStatusRow(name: "built-in", title: "Your address", caption: model.builtInRoute.settingsStatusText(timeZone: .current), slot: .checking)
        case .stopped:
            SetupStatusRow(name: "built-in", title: "Your address", caption: model.builtInRoute.notReadyReason, wrapsCaption: true, slot: .unavailable(model.builtInRoute.settingsStatusText(timeZone: .current)))
        case .failed(let message):
            SetupStatusRow(
                name: "built-in",
                title: "Tailscale",
                caption: message,
                captionIsError: true,
                wrapsCaption: true,
                slot: .action("Try Again", accessibleName: "Try Again with Tailscale") { model.retryBuiltInRoute() }
            )
        }
    }
}

/// BuiltInRouteCopy is what the person is told before signing in: the
/// address is public and opened only by the token.
enum BuiltInRouteCopy {
    static let disclosure = "This gives your Mac a public https address that only your token opens. Its name appears in public certificate logs. A Tailscale account is free, and your phone needs nothing installed."
}

/// TailscaleChoiceView asks "Use your Tailscale?" where Tailscale's Mac app
/// is installed: use it (the Tailscale HTTPS and My tailnet ways) or the one
/// built into CGM Relay. It is shown only when the app is installed; without
/// it the built-in route is the only one. It belongs inside a Form.
struct TailscaleChoiceView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section {
            choiceRow(
                title: "Use My Tailscale",
                description: "Reach this Mac over your own Tailscale, on a private address.",
                selected: !model.settings.useBuiltInTailscale
            ) { model.chooseOwnTailscale() }
            choiceRow(
                title: "Use Built-In Tailscale",
                description: "Give this Mac its own public address. Your phone needs no Tailscale.",
                selected: model.settings.useBuiltInTailscale
            ) { model.chooseBuiltInTailscale() }
        } header: {
            Text("Use your Tailscale?")
        }
    }

    private func choiceRow(title: String, description: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .imageScale(.large)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .accessibleRadioName(title, isSelected: selected, action: action)
    }
}

import CGMRelayCore
import SwiftUI

/// ReachChoicesView is the one definition of "who can reach the relay",
/// shown in Advanced and in setup when Tailscale HTTPS is not an option:
/// three choices, each with what it means, and the notes that go with them.
struct ReachChoicesView: View {
    @ObservedObject var model: AppModel
    /// showsTitle is false where a section header already says what these
    /// choices are.
    var showsTitle = true

    /// isLocked is true while Tailscale HTTPS is set up: the relay then
    /// serves this Mac only and Tailscale does the reaching, so the choice
    /// is shown as this Mac only and cannot change.
    private var isLocked: Bool { model.httpsLocked }

    var body: some View {
        if showsTitle {
            Text("Who can reach it")
        }
        VStack(alignment: .leading, spacing: 2) {
            reachRow(.thisMacOnly, title: "This Mac only", description: "Only apps on this Mac can connect.", disabled: isLocked)
            reachRow(.myTailnet, title: "My tailnet", description: "Any device on your tailnet can connect.", disabled: isLocked || !model.tailnetAvailable)
            reachRow(.myLocalNetwork, title: "My local network", description: "Any device on your Wi-Fi or wired network can connect.", disabled: isLocked)
        }

        if isLocked {
            Text(model.httpsState.isOn
                ? "Tailscale HTTPS is on, so only Tailscale can reach the relay. Turn it off to change this."
                : "Tailscale HTTPS is set up. Connect Tailscale to change this.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            if !model.tailnetAvailable {
                Text("My tailnet is unavailable: this Mac has no Tailscale address right now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.settings.reach == .myLocalNetwork {
                if !model.localNetworkAvailable {
                    Text("My local network is unavailable: this Mac has no network address right now.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("The connection is not encrypted on your local network.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// reachRow is one of the three reach options, hand-built rather than
    /// a `Picker` styled `.radioGroup`: on this platform, a `.radioGroup`
    /// option whose content is more than a single plain `Text` (this one
    /// needs both a title and a description) is announced by the
    /// Picker's own shared label ("Who can reach it") instead of its own.
    /// Each row is its own `Button` so it keeps a real tap target and a
    /// working `.accessibleRadioName` (AccessibleButtonName.swift),
    /// styled as a plain-system radio row: an outline or filled circle
    /// leading a title and its description. The tap and the accessible
    /// action share one `action` closure, and `.disabled` wraps both of
    /// them (applied last, outside `.accessibleRadioName`) so the
    /// accessibility representation sees the same disabled state the
    /// visible row does.
    private func reachRow(_ reach: NetworkReach, title: String, description: String, disabled: Bool) -> some View {
        let isSelected = model.settings.effectiveReach == reach
        let action: () -> Void = { selectReach(reach) }
        return Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(disabled ? AnyShapeStyle(.tertiary) : (isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary)))
                    .imageScale(.large)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(disabled ? .secondary : .primary)
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
        .accessibleRadioName(title, isSelected: isSelected, action: action)
        .disabled(disabled)
    }

    /// selectReach is every reachRow's tap and accessible action, applying
    /// the tailnet-availability guard in the one place both call into.
    private func selectReach(_ reach: NetworkReach) {
        guard reach != .myTailnet || model.tailnetAvailable else { return }
        model.updateReach(reach)
    }
}

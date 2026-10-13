import CGMRelayCore
import SwiftUI

/// ReachChoicesView is the one definition of "who can reach the relay",
/// shown in Advanced and in setup: Tailscale HTTPS and the other ways, each
/// with what it means, and the notes that go with them. Every way can be
/// picked at any time; a way that cannot work right now says why on its own
/// row. The section that holds it carries its title.
struct ReachChoicesView: View {
    @ObservedObject var model: AppModel
    /// offersThisMacOnly is false in setup, where every choice must be a way
    /// for a phone to connect; Advanced offers all four.
    var offersThisMacOnly = true
    /// showsAvailabilityNotes is false where the surrounding screen already
    /// says, once, why the person cannot go on.
    var showsAvailabilityNotes = true
    /// setUpPhone, where given, is offered beside the local network's
    /// certificate note as the way to set up a phone. Setup leaves it out,
    /// since its next step is that very step.
    var setUpPhone: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            reachRow(.tailscaleHTTPS, title: "Tailscale HTTPS", description: "A private address that works at home and away.")
            if offersThisMacOnly {
                reachRow(.thisMacOnly, title: "This Mac only", description: "Only apps on this Mac can connect.")
            }
            reachRow(.myTailnet, title: "My tailnet", description: "Any device on your tailnet can connect.")
            reachRow(.myLocalNetwork, title: "My local network", description: "Any device on your Wi-Fi or wired network can connect.")
        }

        if showsAvailabilityNotes, model.settings.chosenWay == .tailscaleHTTPS, case .blocked(let reason) = model.phoneReachability {
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if model.settings.chosenWay == .myLocalNetwork {
            if showsAvailabilityNotes, !model.localNetworkAvailable {
                Text("My local network is unavailable: this Mac has no network address right now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let setUpPhone {
                HStack {
                    certificateNote
                    Spacer(minLength: 12)
                    AccessibleButton("Set Up a Phone…", accessibleName: "Set Up HTTPS on a Phone", action: setUpPhone)
                        .fixedSize()
                }
            } else {
                certificateNote
            }
        }
    }

    private var certificateNote: some View {
        Text("Each phone installs CGM Relay's certificate once, then reads over HTTPS.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// reachRow is one of the reach options, hand-built rather than
    /// a `Picker` styled `.radioGroup`: on this platform, a `.radioGroup`
    /// option whose content is more than a single plain `Text` (this one
    /// needs both a title and a description) is announced by the
    /// Picker's own label instead of the option's.
    /// Each row is its own `Button` so it keeps a real tap target and a
    /// working `.accessibleRadioName` (AccessibleButtonName.swift),
    /// styled as a plain-system radio row: an outline or filled circle
    /// leading a title and its description. A way that cannot work right now
    /// shows its reason beneath and cannot be picked; the chosen way is never
    /// dimmed. The tap and the accessible action share one `action` closure,
    /// and `.disabled` wraps both of them (applied last, outside
    /// `.accessibleRadioName`) so the accessibility representation sees the
    /// same disabled state the visible row does.
    private func reachRow(_ way: ReachWay, title: String, description: String) -> some View {
        let isSelected = model.settings.chosenWay == way
        var unavailableReason: String?
        if case .unavailable(let reason) = way.pickability(https: model.httpsState, tailnetAvailable: model.tailnetAvailable) {
            unavailableReason = reason
        }
        let disabled = unavailableReason != nil && !isSelected
        let action: () -> Void = { model.chooseWay(way) }
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
                    if let unavailableReason {
                        Text(unavailableReason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
}

import CGMRelayCore
import SwiftUI

/// AdvancedPaneView holds the port and reach settings most people never
/// need to touch: the default (This Mac only, port 1337) never exposes
/// the engine beyond this one Mac.
struct AdvancedPaneView: View {
    @ObservedObject var model: AppModel
    @State private var portText = ""
    @State private var portErrorMessage: String?
    @FocusState private var portFieldFocused: Bool

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Port")
                    Spacer()
                    // An empty title, not "Port": inside a Form, TextField's
                    // title renders as a second visible label beside this
                    // row's own Text, and the width below is wide enough for
                    // the field's own widest valid value (65535).
                    TextField("", text: $portText)
                        .accessibilityLabel("Port")
                        .frame(width: 66)
                        .multilineTextAlignment(.trailing)
                        .focused($portFieldFocused)
                        .onSubmit { commitPort() }
                }
                if let portErrorMessage {
                    Text(portErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("From \(AppSettings.portRange.lowerBound) to \(AppSettings.portRange.upperBound). Press Return to save.")
            }

            Section {
                Text("Who can reach it")
                VStack(alignment: .leading, spacing: 2) {
                    reachRow(.thisMacOnly, title: "This Mac only", description: "Only apps on this Mac can connect.", disabled: false)
                    reachRow(.myTailnet, title: "My tailnet", description: "Any device on your tailnet can connect.", disabled: !model.tailnetAvailable)
                    reachRow(.myLocalNetwork, title: "My local network", description: "Any device on your Wi-Fi or wired network can connect.", disabled: false)
                }

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
            } header: {
                Text("Access")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, alignment: .top)
        .onAppear {
            model.refreshNetworkAddresses()
            portText = String(model.settings.port)
        }
        .onChange(of: portFieldFocused) { _, isFocused in
            if !isFocused {
                commitPort()
            }
        }
    }

    /// commitPort runs once, on Return or focus loss, never on every
    /// keystroke: a value already equal to the saved one is left alone
    /// (no restart), and an invalid one is refused with an inline message
    /// rather than saved or silently clamped into range.
    private func commitPort() {
        switch PortCommitValidation.validate(portText) {
        case .invalid(let message):
            portErrorMessage = message
        case .valid(let value):
            portErrorMessage = nil
            portText = String(value)
            guard value != model.settings.port else { return }
            model.updatePort(value)
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
        let isSelected = model.settings.reach == reach
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

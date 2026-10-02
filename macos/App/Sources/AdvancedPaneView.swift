import CGMRelayCore
import SwiftUI

/// AdvancedPaneView holds the port, Tailscale HTTPS and reach settings most
/// people never need to touch: the default (This Mac only, port 1337) never
/// exposes the engine beyond this one Mac.
struct AdvancedPaneView: View {
    @ObservedObject var model: AppModel
    @State private var portText = ""
    @State private var portErrorMessage: String?
    @FocusState private var portFieldFocused: Bool

    private var isTailscaleRunning: Bool {
        if case .running = model.tailscaleStatus { return true }
        return false
    }

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
                        .disabled(model.httpsLocked)
                }
                if let portErrorMessage {
                    Text(portErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } footer: {
                if model.httpsLocked {
                    Text("Turn off Tailscale HTTPS to change the port.")
                } else {
                    Text("From \(AppSettings.portRange.lowerBound) to \(AppSettings.portRange.upperBound). Press Return to save.")
                }
            }

            if model.settings.tailscaleHTTPSEnabled || isTailscaleRunning {
                Section {
                    TailscaleHTTPSControl(model: model, part: .statusRow)
                } footer: {
                    TailscaleHTTPSControl(model: model, part: .notes)
                }
            }

            Section {
                ReachChoicesView(model: model)
            } header: {
                Text("Who can reach it")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, alignment: .top)
        .onAppear {
            model.refreshNetworkAddresses()
            portText = String(model.settings.port)
            Task { await model.refreshTailscale() }
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
}

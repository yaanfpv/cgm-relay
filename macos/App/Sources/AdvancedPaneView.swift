import CGMRelayCore
import SwiftUI

/// AdvancedPaneView holds the port, Tailscale HTTPS and reach settings most
/// people never need to touch: the default (This Mac only, on
/// RelayDefaults.followerPort) never exposes the engine beyond this one Mac.
struct AdvancedPaneView: View {
    @ObservedObject var model: AppModel
    @State private var portText = ""
    @State private var portErrorMessage: String?
    /// portChanged is whether the port was just saved as a new one, so the
    /// pane says follower apps need the new address.
    @State private var portChanged = false
    /// openConnectPane brings the Connect pane forward, where the new
    /// address is.
    var openConnectPane: () -> Void = {}
    @FocusState private var portFieldFocused: Bool
    /// isPresentingCertificateStep is whether this pane opened the HTTPS step.
    @State private var isPresentingCertificateStep = false

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
                if portChanged {
                    HStack {
                        Text("Follower apps using the old address stop reading until they get the new one.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        AccessibleButton("Show New Address…", action: openConnectPane)
                    }
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
                ReachChoicesView(model: model, setUpPhone: {
                    isPresentingCertificateStep = true
                    model.beginCertificateStep()
                })
            } header: {
                Text("Who can reach it")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, alignment: .top)
        .certificateStepSheet(isPresenting: $isPresentingCertificateStep, model: model)
        .onAppear {
            model.refreshNetworkAddresses()
            portText = String(model.settings.port)
            Task { await model.refreshTailscale() }
        }
        .onChange(of: model.settings.port) { _, newPort in
            // Setup may move the port to a free one while this pane is open.
            if !portFieldFocused { portText = String(newPort) }
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
    /// rather than saved or silently clamped into range. A port another app
    /// already holds, or the one the relay uses for its own status listener,
    /// is refused the same way, and never changed to another.
    private func commitPort() {
        switch PortCommitValidation.validate(portText) {
        case .invalid(let message):
            portErrorMessage = message
            portChanged = false
        case .valid(let value):
            portErrorMessage = nil
            portText = String(value)
            guard value != model.settings.port else { return }
            if let inUse = model.typedPortInUseMessage(value) {
                portErrorMessage = inUse
                portChanged = false
                return
            }
            model.updatePort(value)
            portChanged = model.settings.port == value
        }
    }
}

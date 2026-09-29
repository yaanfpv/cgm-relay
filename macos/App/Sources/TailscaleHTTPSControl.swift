import CGMRelayCore
import SwiftUI

/// TailscaleHTTPSControl is the one place the app changes anything outside
/// itself. It shows the exact command a click runs, beneath the button and
/// before the click, and runs only that command. Whether HTTPS is on, and
/// which port it would use, come from what Tailscale itself reports, read
/// again just before anything runs. Shown in setup and in Advanced from this
/// one definition.
struct TailscaleHTTPSControl: View {
    @ObservedObject var model: AppModel
    @State private var isConfirmingTurnOff = false

    var body: some View {
        stateView
            .onAppear { model.clearTailscaleFailure() }
    }

    @ViewBuilder
    private var stateView: some View {
        switch model.httpsState {
        case .unknown:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking Tailscale…")
            }
        case .unavailable:
            note("Tailscale isn't running right now. Connect it to change Tailscale HTTPS.")
        case .unreadable:
            VStack(alignment: .leading, spacing: 8) {
                note("Couldn't read Tailscale's settings right now.")
                AccessibleButton("Check Again") { Task { await model.refreshTailscale() } }
            }
        case .noFreePort:
            note("Tailscale already serves on every port CGM Relay can use (\(portList)), so it can't turn on HTTPS. Use one of the other ways below.")
        case .off(let port):
            turnedOff(port: port)
        case .on(let port):
            turnedOn(port: port)
        }
    }

    private var portList: String {
        let ports = TailscaleHTTPSState.candidatePorts.map(String.init)
        return ports.dropLast().joined(separator: ", ") + " and " + (ports.last ?? "")
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.secondary)
    }

    private func turnedOff(port: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.settings.tailscaleHTTPSEnabled {
                Text("Tailscale HTTPS is off right now.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                AccessibleButton("Use Tailscale HTTPS", style: .primary) {
                    Task { await model.enableTailscaleHTTPS(shownPort: port) }
                }
                .disabled(model.isChangingTailscale)
                if model.isChangingTailscale {
                    ProgressView().controlSize(.small)
                }
            }
            commandLine(.enableHTTPS(proxyingToPort: model.settings.port, httpsPort: port))
            failureLine
        }
    }

    private func turnedOn(port: Int) -> some View {
        let offCommand = TailscaleServeCommand.disableHTTPS(httpsPort: port)
        return VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Tailscale HTTPS") {
                Text(port == 443 ? "On" : "On, port " + String(port)).foregroundStyle(.secondary)
            }
            HStack {
                AccessibleButton("Turn Off…") { isConfirmingTurnOff = true }
                    .disabled(model.isChangingTailscale)
                    .confirmationDialog(
                        "Turn Off Tailscale HTTPS?",
                        isPresented: $isConfirmingTurnOff,
                        titleVisibility: .visible
                    ) {
                        Button("Turn Off", role: .destructive) {
                            Task { await model.disableTailscaleHTTPS(shownPort: port) }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Follower apps using the https address stop reading until you give them a new address. This runs: \(offCommand.displayText)")
                    }
                if model.isChangingTailscale {
                    ProgressView().controlSize(.small)
                }
            }
            failureLine
        }
    }

    private func commandLine(_ command: TailscaleServeCommand) -> some View {
        (Text("Runs ") + Text(command.displayText).font(.system(.caption, design: .monospaced)))
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var failureLine: some View {
        if let failure = model.tailscaleFailure {
            VStack(alignment: .leading, spacing: 4) {
                Text(failure.message)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                if let helpURL = failure.helpURL {
                    Link("How to turn on HTTPS certificates", destination: helpURL)
                }
            }
            .font(.callout)
        }
    }
}

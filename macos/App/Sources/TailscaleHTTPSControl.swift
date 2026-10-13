import CGMRelayCore
import SwiftUI

/// TailscaleHTTPSControl is the one place the app changes anything outside
/// itself. It shows the exact command a click runs, beneath the button and
/// before the click, and runs only that command. Whether HTTPS is on, and
/// which port it would use, come from what Tailscale itself reports, read
/// again just before anything runs. Shown in setup and in Advanced from this
/// one definition, as a status row with its notes beneath.
struct TailscaleHTTPSControl: View {
    @ObservedObject var model: AppModel
    /// Part is which piece of the control a caller draws: the titled row
    /// (the state and its one action in the row's slot) inside a card, and
    /// the notes (the command a click runs, a failure) beneath it.
    enum Part {
        case statusRow, notes
    }

    let part: Part
    @State private var isConfirmingTurnOff = false

    var body: some View {
        Group {
            switch part {
            case .statusRow: statusRowView
            case .notes: notesView
            }
        }
        .onAppear { model.clearTailscaleFailure() }
    }

    private static let title = "Tailscale HTTPS"
    private static let offCaption = "A private address that works at home and away."

    @ViewBuilder
    private var statusRowView: some View {
        switch model.httpsState {
        case .unknown:
            row("Checking Tailscale's settings.", .checking)
        case .unavailable:
            row("Connect Tailscale to change this.", .unavailable("Not available"))
        case .unreadable:
            row("Couldn't read Tailscale's settings.", .action("Check Again") { Task { await model.refreshTailscale() } })
        case .noFreePort:
            row("Every port from 443 up is taken.", .unavailable("Not available"))
        case .off(let port):
            row(
                model.settings.tailscaleHTTPSEnabled ? "Turned off in Tailscale. Turn it on again." : Self.offCaption,
                model.isChangingTailscale
                    ? .checking
                    : .action("Use Tailscale HTTPS", style: .primary) { Task { await model.enableTailscaleHTTPS(shownPort: port) } }
            )
        case .on where model.existingHandlerOffered:
            row(
                "Already set up on this Mac. Use it, or pick another way.",
                .action("Use It", accessibleName: "Use Existing Tailscale HTTPS") { model.useExistingTailscaleHTTPS() }
            )
        case .on(let port):
            row(
                port == 443 ? "Followers reach this Mac over https." : "Followers reach this Mac over https, port " + String(port) + ".",
                model.isChangingTailscale
                    ? .checking
                    : .doneWithAction("On", actionLabel: "Turn Off…", accessibleName: "Turn Off Tailscale HTTPS") { isConfirmingTurnOff = true }
            )
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
                Text("Follower apps using the https address stop reading until you give them a new address. This runs: \(TailscaleServeCommand.disableHTTPS(httpsPort: port).displayText)")
            }
        }
    }

    @ViewBuilder
    private var notesView: some View {
        switch model.httpsState {
        case .unknown, .unavailable, .unreadable:
            EmptyView()
        case .noFreePort:
            note("Tailscale already serves something on every port from 443 up, so it can't turn on HTTPS. Use one of the other ways below.")
        case .off(let port):
            // A failure takes the command's place, so the step stays inside
            // its window height.
            if model.tailscaleFailure == nil {
                commandLine(.enableHTTPS(proxyingToPort: model.settings.port, httpsPort: port))
            } else {
                failureLine
            }
        case .on:
            failureLine
        }
    }

    private func row(_ caption: String, _ slot: SetupStatusRow.Slot) -> some View {
        SetupStatusRow(name: "tailscale-https", title: Self.title, caption: caption, slot: slot)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.secondary)
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

import AppKit
import CGMRelayCore
import SwiftUI

/// SetupView is first-launch setup: three steps that take a person from
/// nothing to a follower app reading their glucose. It is its own window
/// rather than a mode of Settings, so it can be sized to each step and
/// Settings keeps opening to its panes. Every step reuses the control the
/// Settings window already has for that job.
struct SetupView: View {
    enum Step: Int {
        case signIn = 1, reach, connect

        var title: String {
            switch self {
            case .signIn: "Sign In"
            case .reach: "Reach Your Phone"
            case .connect: "Connect Your App"
            }
        }

        var subtitle: String {
            switch self {
            case .signIn: "Your readings come from your LibreLinkUp account."
            case .reach: "Choose how your phone gets to this Mac."
            case .connect: "Give your follower app this address and token."
            }
        }
    }

    @ObservedObject var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var requestedStep: Step

    init(model: AppModel) {
        self.model = model
        _requestedStep = State(initialValue: model.credentialsConfigured ? .reach : .signIn)
    }

    /// step is never past sign-in without an account, whatever was asked.
    private var step: Step {
        model.credentialsConfigured ? requestedStep : .signIn
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .fixedSize(horizontal: false, vertical: true)
            footer
        }
        .frame(width: SettingsView.paneWidth)
        .background(WindowFronting())
        .onAppear { refreshNetworkState() }
        .onChange(of: step) { _, newStep in
            if newStep == .reach { refreshNetworkState() }
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("Step \(step.rawValue) of 3")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(step.title)
                .font(.title2.bold())
            Text(step.subtitle)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .signIn:
            AccountPaneView(model: model)
        case .reach:
            SetupReachStep(model: model)
        case .connect:
            ConnectPaneView(
                model: model,
                blockedSecondary: "Go back and choose how your phone reaches this Mac.",
                blockedAction: nil,
                showsTokenRotation: false,
                isCompact: true
            ) { token in
                FollowerAppSteps(model: model, token: token)
            }
        }
    }

    private var footer: some View {
        HStack {
            if step != .signIn {
                AccessibleButton("Back") { goBack() }
            }
            Spacer()
            switch step {
            case .signIn:
                AccessibleButton("Continue", style: model.credentialsConfigured ? .primary : .secondary) { requestedStep = .reach }
                    .disabled(!model.credentialsConfigured)
            case .reach:
                AccessibleButton("Continue", style: offersTailscaleHTTPS ? .secondary : .primary) { requestedStep = .connect }
            case .connect:
                AccessibleButton("Done", style: .primary) { finish() }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 20)
    }

    /// offersTailscaleHTTPS is true while step 2's own primary action, the
    /// Tailscale HTTPS button, is on screen: Continue then steps back so
    /// the screen has one primary action.
    private var offersTailscaleHTTPS: Bool {
        if case .off = model.httpsState { return true }
        return false
    }

    private func goBack() {
        requestedStep = step == .connect ? .reach : .signIn
    }

    private func finish() {
        model.completeSetup()
        dismissWindow(id: SetupWindow.id)
    }

    private func refreshNetworkState() {
        model.refreshNetworkAddresses()
        Task { await model.refreshTailscale() }
    }
}

/// SetupReachStep is step 2. With Tailscale connected it offers Tailscale's
/// own https address, and always the reach choices Advanced has beneath it,
/// so every outcome here has a way forward inside setup; otherwise it says
/// why Tailscale is not offered and shows the reach choices.
private struct SetupReachStep: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            switch model.tailscaleStatus {
            case .running(let name):
                tailscaleSection(name: name)
                if !model.httpsState.isOn {
                    otherWaysSection
                }
            case .unknown:
                Section {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking Tailscale…")
                    }
                }
            case .absent:
                notAvailableSection(
                    "Tailscale isn't installed on this Mac, so choose how your phone reaches it below."
                )
            case .stopped:
                notAvailableSection(
                    "Tailscale isn't running, or this Mac isn't signed in to it. Connect it and check again, or choose how your phone reaches this Mac below."
                )
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func tailscaleSection(name: String) -> some View {
        Section {
            LabeledContent("This Mac on Tailscale") {
                Text(name)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            TailscaleHTTPSControl(model: model)
        } footer: {
            if case .off = model.httpsState {
                Text("A private https address on your tailnet that works at home and away.")
            }
        }
    }

    private var otherWaysSection: some View {
        Section {
            ReachChoicesView(model: model, showsTitle: false)
        } header: {
            Text("Other ways")
        }
    }

    @ViewBuilder
    private func notAvailableSection(_ sentence: String) -> some View {
        Section {
            Text(sentence)
                .fixedSize(horizontal: false, vertical: true)
            if case .stopped = model.tailscaleStatus {
                HStack {
                    Spacer()
                    AccessibleButton("Check Again") {
                        Task { await model.refreshTailscale() }
                    }
                }
            }
        }
        Section {
            ReachChoicesView(model: model)
        } header: {
            Text("Access")
        }
    }
}

/// FollowerAppSteps is what a person types into xDrip4iOS and xDrip+ to
/// follow this relay, using the names those apps show.
private struct FollowerAppSteps: View {
    @ObservedObject var model: AppModel
    let token: String

    var body: some View {
        if case .ready(let address) = model.connectPaneAddressState {
            let entry = FollowerAppEntry.hostAndPort(of: address)
            Section {
                HStack(alignment: .top, spacing: 20) {
                    appColumn(title: "xDrip4iOS") {
                        step("In Data Source, set Master or Follower to Follower, and Data Source to Nightscout.")
                        step("In Nightscout, turn on Enable Nightscout.")
                        step("Enter \(entry.host) in URL\(entry.port.map { " and \($0) in Port" } ?? ""), and the token in Token.")
                    }
                    Divider()
                    appColumn(title: "xDrip+") {
                        step("In Data Source Settings, set Hardware Data Source to Nightscout Follower.")
                        step("In Nightscout Follow URL, enter the address with the token in front of it.")
                        AccessibleButton("Copy URL for xDrip+", style: .secondary) {
                            copy(FollowerAppEntry.urlWithToken(address: address, token: token))
                        }
                    }
                }
            }
        }
    }

    private func appColumn(title: String, @ViewBuilder steps: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            steps()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func step(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}

import AppKit
import CGMRelayCore
import SwiftUI

/// SetupView is first-launch setup: four steps that take a person from
/// nothing to a follower app reading their glucose, running after every
/// restart. It is its own window rather than a mode of Settings, so it can
/// be sized to each step and Settings keeps opening to its panes. Every step
/// reuses the control the Settings window already has for that job.
struct SetupView: View {
    enum Step: Int {
        case signIn = 1, reach, connect, ready

        static let count = 4

        /// title is the step's heading; the last step says so plainly when
        /// no phone can reach this Mac yet, rather than claiming setup is done.
        func title(phoneReachable: Bool) -> String {
            switch self {
            case .signIn: "Sign In"
            case .reach: "Reach Your Phone"
            case .connect: "Connect Your App"
            case .ready: phoneReachable ? "You're All Set" : "Your Phone Isn't Connected Yet"
            }
        }

        func subtitle(phoneReachable: Bool) -> String {
            switch self {
            case .signIn: "This is where CGM Relay gets your readings."
            case .reach: "Choose how your phone gets to this Mac."
            case .connect: "Give your follower app this address and token."
            case .ready:
                phoneReachable
                    ? "One last choice, and here is what happens from now on."
                    : "Setup will reopen until a phone can reach this Mac."
            }
        }
    }

    @ObservedObject var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var requestedStep: Step
    @StateObject private var signInForm = SignInForm()

    /// openAdvanced opens Settings on the Advanced pane, offered when setup
    /// found no free port.
    private let openAdvanced: () -> Void

    init(model: AppModel, openAdvanced: @escaping () -> Void = {}) {
        self.model = model
        self.openAdvanced = openAdvanced
        _requestedStep = State(initialValue: Self.startingStep(credentialsConfigured: model.credentialsConfigured))
    }

    /// startingStep is where the window opens: sign-in without an account,
    /// otherwise the step that decides how a phone reaches this Mac.
    static func startingStep(credentialsConfigured: Bool) -> Step {
        credentialsConfigured ? .reach : .signIn
    }

    /// step is never past sign-in without an account, whatever was asked.
    private var step: Step {
        model.credentialsConfigured ? requestedStep : .signIn
    }

    var body: some View {
        Group {
            if model.needsSafetyNotice {
                noticeScreen
            } else {
                VStack(spacing: 0) {
                    header
                    portNotice
                    content
                        .fixedSize(horizontal: false, vertical: true)
                    footer
                }
            }
        }
        .frame(width: SettingsView.paneWidth)
        .background(WindowFronting())
        .cgmWindowBackground()
        .onAppear {
            // The window scene keeps this view's state across a close and
            // reopen, so each opening starts over rather than resuming.
            requestedStep = Self.startingStep(credentialsConfigured: model.credentialsConfigured)
            refreshNetworkState()
        }
        .onChange(of: step) { _, newStep in
            if newStep == .reach { refreshNetworkState() }
        }
    }

    /// noticeScreen is what comes before the first step, and the only thing
    /// shown when its wording changes after setup is done: the safety notice
    /// and the one action that accepts it.
    private var noticeScreen: some View {
        VStack(spacing: 16) {
            Text("Before You Start")
                .font(.title2.bold())
            SafetyNoticeText(font: .body)
                .multilineTextAlignment(.center)
            AccessibleButton("I Understand", style: .primary, action: acceptSafetyNotice)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func acceptSafetyNotice() {
        model.acceptSafetyNotice()
        if !model.needsSetup {
            dismissWindow(id: SetupWindow.id)
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("Step \(step.rawValue) of \(Step.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(step.title(phoneReachable: isPhoneReachable))
                .font(.title2.bold())
            Text(step.subtitle(phoneReachable: isPhoneReachable))
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
    }

    /// portNotice says so, and offers Advanced, when none of the ports setup
    /// tries was free.
    @ViewBuilder
    private var portNotice: some View {
        if let notice = model.setupPortNotice {
            VStack(spacing: 8) {
                Text(notice)
                    .multilineTextAlignment(.center)
                AccessibleButton("Open Advanced…", action: openAdvanced)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .signIn:
            AccountPaneView(model: model, presentation: .setup, externalForm: signInForm)
        case .reach:
            SetupReachStep(model: model)
        case .connect:
            ConnectPaneView(
                model: model,
                blockedSecondary: "Go back and choose how your phone reaches this Mac.",
                blockedAction: nil,
                showsTokenRotation: false,
                isCompact: true
            ) { _ in
                EmptyView()
            }
        case .ready:
            SetupReadyStep(model: model)
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
                signInFooterButton
            case .reach:
                if !isPhoneReachable {
                    AccessibleButton("Set Up Later", style: .plain) { requestedStep = .ready }
                }
                AccessibleButton("Continue", style: offersTailscaleHTTPS ? .secondary : .primary) { requestedStep = .connect }
                    .disabled(!isPhoneReachable)
            case .connect:
                AccessibleButton("Continue", style: .primary) { requestedStep = .ready }
            case .ready:
                AccessibleButton(isPhoneReachable ? "Done" : "Close", style: .primary) { finish() }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 20)
    }

    /// signInFooterButton is step 1's one button: Sign In until the account
    /// is signed in, then Continue.
    @ViewBuilder
    private var signInFooterButton: some View {
        if model.credentialsConfigured {
            AccessibleButton("Continue", style: .primary) { requestedStep = .reach }
        } else {
            HStack(spacing: 8) {
                if signInForm.isChecking {
                    ProgressView().controlSize(.small)
                }
                AccessibleButton(signInForm.isChecking ? "Checking…" : "Sign In", style: .primary) {
                    Task { await signInForm.submit(model: model) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!signInForm.canSubmit)
            }
        }
    }

    /// offersTailscaleHTTPS is true while step 2's own primary action, the
    /// Tailscale HTTPS button, is on screen: Continue then steps back so
    /// the screen has one primary action.
    private var offersTailscaleHTTPS: Bool {
        if case .off = model.httpsState { return true }
        return false
    }

    private var isPhoneReachable: Bool { model.phoneReachability.isReachable }

    /// goBack from the last step skips the connect step when there was no
    /// way for a phone to reach this Mac to connect through.
    private func goBack() {
        switch step {
        case .ready: requestedStep = isPhoneReachable ? .connect : .reach
        case .connect: requestedStep = .reach
        case .reach, .signIn: requestedStep = .signIn
        }
    }

    /// finish is Done, or Close when no phone can reach this Mac yet: the
    /// window closes and the menu panel opens once so the person sees where
    /// CGM Relay lives, but setup is marked finished only when a phone can
    /// reach this Mac, so it reopens until then.
    private func finish() {
        model.completeSetup()
        dismissWindow(id: SetupWindow.id)
        model.requestMenuPanel()
    }

    private func refreshNetworkState() {
        model.refreshNetworkAddresses()
        Task { await model.refreshTailscale() }
    }
}

/// SetupReachStep is step 2. Tailscale's state and its HTTPS setting read as
/// status rows; with Tailscale connected it offers Tailscale's own https
/// address, and always the ways a phone can reach this Mac that Advanced has
/// beneath it (without This Mac only, which no phone can use). Continue waits
/// for one that works, and one line under the choices says what is missing.
private struct SetupReachStep: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                tailscaleRow
                if case .running = model.tailscaleStatus {
                    TailscaleHTTPSControl(model: model, part: .statusRow)
                }
            } footer: {
                switch model.tailscaleStatus {
                case .running:
                    TailscaleHTTPSControl(model: model, part: .notes)
                case .unknown, .absent, .stopped:
                    EmptyView()
                }
            }
            switch model.tailscaleStatus {
            case .running:
                if !model.httpsState.isOn {
                    Section {
                        ReachChoicesView(model: model, offersThisMacOnly: false, showsAvailabilityNotes: false)
                    } header: {
                        Text("Other ways")
                    } footer: {
                        blockedReason
                    }
                }
            case .unknown:
                EmptyView()
            case .absent, .stopped:
                Section {
                    ReachChoicesView(model: model, offersThisMacOnly: false, showsAvailabilityNotes: false)
                } header: {
                    Text("Choose how your phone reaches this Mac")
                } footer: {
                    blockedReason
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var blockedReason: some View {
        if case .blocked(let reason) = model.phoneReachability {
            Text(reason)
        }
    }

    @ViewBuilder
    private var tailscaleRow: some View {
        switch model.tailscaleStatus {
        case .unknown:
            row("Looking for Tailscale on this Mac.", .checking)
        case .running(let name):
            SetupStatusRow(name: "tailscale", title: "Tailscale", caption: name, captionIsMonospaced: true, slot: .done("Connected"))
        case .absent:
            row("Not installed on this Mac.", .unavailable("Not available"))
        case .stopped:
            row("Not running, or this Mac isn't signed in.", .action("Check Again") { Task { await model.refreshTailscale() } })
        }
    }

    private func row(_ caption: String, _ slot: SetupStatusRow.Slot) -> some View {
        SetupStatusRow(name: "tailscale", title: "Tailscale", caption: caption, slot: slot)
    }
}

/// SetupReadyStep is step 4: the one setting left, Open at Login, then what
/// happens from here.
private struct SetupReadyStep: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                loginItemRow
            }
            Section {
                SetupInfoRow(
                    symbol: "lock.fill",
                    title: "Stored on this Mac",
                    caption: "Readings are encrypted here and go only to apps you give the token."
                )
                SetupInfoRow(
                    symbol: "menubar.rectangle",
                    title: "Lives in the menu bar",
                    caption: "CGM Relay now runs from the menu bar at the top of your screen."
                )
            } footer: {
                Text("You can change these in Settings.")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, alignment: .top)
        .onAppear { model.refreshLoginItemStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshLoginItemStatus()
        }
    }

    private var loginItemRow: some View {
        let title = "Open at Login"
        let name = "login"
        let turnOn = { model.setOpenAtLogin(true) }
        switch model.loginItemStatus {
        case .disabled:
            return SetupStatusRow(
                name: name,
                title: title,
                caption: model.loginItemErrorMessage ?? "Start CGM Relay when you log in, so no minute is lost.",
                captionIsError: model.loginItemErrorMessage != nil,
                slot: .action("Turn On", accessibleName: "Turn On Open at Login", run: turnOn)
            )
        case .enabled:
            return SetupStatusRow(name: name, title: title, caption: "CGM Relay starts when you log in.", slot: .done("On"))
        case .requiresApproval:
            return SetupStatusRow(
                name: name,
                title: title,
                caption: "Needs your approval in System Settings.",
                slot: .action("Open Settings…", accessibleName: "Open Login Items in System Settings") { model.openLoginItemsSettings() }
            )
        case .notFound:
            return SetupStatusRow(
                name: name,
                title: title,
                caption: model.loginItemUnavailableReason ?? "This build can't open at login.",
                captionIsError: model.loginItemUnavailableReason != nil,
                slot: .unavailable("Not available")
            )
        }
    }
}

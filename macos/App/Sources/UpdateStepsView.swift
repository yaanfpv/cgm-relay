import CGMRelayCore
import SwiftUI

/// UpdateStepsView is the "What's new in this update" window: only the steps
/// an update adds for someone who already finished setup, in order, counted
/// across those steps alone. It reuses the controls setup already has for each
/// job. Each step is saved as answered the moment it is, so a relaunch brings
/// back only the steps still open, and Later closes the window without
/// answering anything.
struct UpdateStepsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var steps: [UpdateStep]
    @State private var index = 0

    init(model: AppModel) {
        self.model = model
        _steps = State(initialValue: model.updateWindowSteps)
    }

    private var step: UpdateStep? {
        steps.indices.contains(index) ? steps[index] : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if let step {
                header(for: step)
                content(for: step)
                    .fixedSize(horizontal: false, vertical: true)
                footer(for: step)
            }
        }
        .frame(width: SettingsView.paneWidth)
        .background(WindowFronting())
        .cgmWindowBackground()
        .onAppear {
            // The window scene keeps this view's state across a close and
            // reopen, so each opening starts over from the steps still open.
            model.refreshTailscaleAppInstalled()
            steps = model.updateWindowSteps
            index = 0
            if steps.isEmpty { dismissWindow(id: UpdateStepsWindow.id) }
        }
    }

    // MARK: - Header

    private func header(for step: UpdateStep) -> some View {
        VStack(spacing: 4) {
            Text("Step \(index + 1) of \(steps.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(title(for: step))
                .font(.title2.bold())
            Text(subtitle(for: step))
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
    }

    private func title(for step: UpdateStep) -> String {
        switch step {
        case .movedToBuiltIn: "Your Route Has Moved"
        case .tailscaleChoice: "Your Tailscale"
        case .stayAwake: "Keep This Mac Awake"
        }
    }

    private func subtitle(for step: UpdateStep) -> String {
        switch step {
        case .movedToBuiltIn: "CGM Relay now gives this Mac its own address."
        case .tailscaleChoice: "Keep using it, or let CGM Relay give this Mac its own address."
        case .stayAwake: "CGM Relay keeps reading only while this Mac is awake."
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(for step: UpdateStep) -> some View {
        switch step {
        case .movedToBuiltIn:
            UpdateMovedStep(model: model)
        case .tailscaleChoice:
            Form {
                TailscaleChoiceView(model: model)
                if model.settings.useBuiltInTailscale {
                    BuiltInRouteView(model: model)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, alignment: .top)
        case .stayAwake:
            SetupStayAwakeStep(model: model)
        }
    }

    // MARK: - Footer

    private func footer(for step: UpdateStep) -> some View {
        HStack {
            AccessibleButton("Later", style: .plain) { dismissWindow(id: UpdateStepsWindow.id) }
            Spacer()
            switch step {
            case .movedToBuiltIn, .tailscaleChoice:
                AccessibleButton(continueTitle, style: .primary) { answer(step) }
                    .disabled(model.settings.useBuiltInTailscale && !model.phoneReachability.isReachable)
            case .stayAwake:
                if model.stayAwakeChoice == nil {
                    AccessibleButton("Not Now", style: .secondary) {
                        Task {
                            await model.turnOffStayAwake()
                            answer(step)
                        }
                    }
                    .disabled(model.isChangingStayAwake)
                } else {
                    AccessibleButton(continueTitle, style: .primary) { answer(step) }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 20)
    }

    private var continueTitle: String {
        index + 1 < steps.count ? "Continue" : "Done"
    }

    /// answer saves the step as answered, then moves on, or finishes the
    /// update after the last step.
    private func answer(_ step: UpdateStep) {
        model.answerUpdateStep(step)
        if index + 1 < steps.count {
            index += 1
        } else {
            model.finishUpdate()
            dismissWindow(id: UpdateStepsWindow.id)
        }
    }
}

/// UpdateMovedStep is the one plain screen that tells someone whose local
/// network route is gone why, followed by the built-in route's own flow.
private struct UpdateMovedStep: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Text("The local network route is gone in this version, because it stopped working whenever you were away from home. CGM Relay now gives this Mac its own private address through a built-in Tailscale, so your phone can reach it from anywhere.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            BuiltInRouteView(model: model)
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, alignment: .top)
        .onAppear { model.chooseBuiltInTailscale() }
    }
}

import CGMRelayCore
import SwiftUI

/// GeneralPaneView holds the settings almost every install touches once:
/// whether CGM Relay opens at login, which unit the menu shows readings
/// in, whether the reading sits beside the menu bar icon, and how long
/// readings are kept.
struct GeneralPaneView: View {
    @ObservedObject var model: AppModel
    @State private var retentionText = ""
    @State private var retentionErrorMessage: String?
    @State private var pendingRetentionValue: Int?
    @State private var isConfirmingLowerRetention = false
    @State private var retentionSettler = RetentionChangeSettler()
    @FocusState private var retentionFocus: RetentionFocus?

    private enum RetentionFocus: Hashable {
        case field, stepper
    }

    var body: some View {
        Form {
            Section {
                Toggle("Open at Login", isOn: openAtLoginBinding)
                    .disabled(model.loginItemStatus == .notFound)
                if model.loginItemStatus == .notFound {
                    Text(model.loginItemUnavailableReason ?? "This build can't open at login.")
                        .font(.caption)
                        .foregroundStyle(model.loginItemUnavailableReason == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                }
                if model.loginItemStatus == .requiresApproval {
                    HStack {
                        Text("Needs approval in System Settings")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        AccessibleButton("Open System Settings…", action: model.openLoginItemsSettings)
                    }
                }
                if let loginItemErrorMessage = model.loginItemErrorMessage {
                    Text(loginItemErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Login")
            }

            Section {
                Picker("Units", selection: unitsBinding) {
                    Text("mg/dL").tag(GlucoseUnit.mgDl)
                    Text("mmol/L").tag(GlucoseUnit.mmolL)
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle("Show the reading in the menu bar", isOn: showReadingBinding)
            } header: {
                Text("Menu Bar")
            } footer: {
                Text("Shows the latest reading and its trend beside the icon while readings are current. Off, the icon alone tells you when something is wrong.")
            }

            Section {
                HStack {
                    Text("Keep readings for")
                    Spacer()
                    // An empty title, not "Days": inside a Form, TextField's
                    // title renders as a second visible label beside this
                    // row's own Text, and the width below is wide enough for
                    // the field's own widest valid value (90).
                    TextField("", text: $retentionText)
                        .accessibilityLabel("Days")
                        .frame(width: 40)
                        .multilineTextAlignment(.trailing)
                        .focused($retentionFocus, equals: .field)
                        .onSubmit { commitRetention() }
                    Stepper("Days", value: retentionStepperBinding, in: AppSettings.retentionDaysRange)
                        .labelsHidden()
                        .accessibilityLabel("Days")
                        .accessibilityValue("\(retentionStepperBinding.wrappedValue)")
                        .focused($retentionFocus, equals: .stepper)
                    Text("days")
                }
                if let retentionErrorMessage {
                    Text(retentionErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("History")
            } footer: {
                Text("From \(AppSettings.retentionDaysRange.lowerBound) to \(AppSettings.retentionDaysRange.upperBound) days. Lowering this deletes older readings; the app asks first.")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, alignment: .top)
        .onAppear {
            model.refreshLoginItemStatus()
            retentionText = String(model.settings.retentionDays)
            retentionErrorMessage = model.retentionNotice
            model.retentionNotice = nil
            retentionSettler.onSettled = { applyRetention($0) }
        }
        .onDisappear {
            // Whatever is typed or clicked but uncommitted is decided here,
            // since switching tabs removes the pane before focus moves.
            retentionSettler.cancel()
            switch RetentionLeaveDecision.decide(current: model.settings.retentionDays, text: retentionText) {
            case .nothing:
                break
            case .save(let value):
                model.updateRetentionDays(value)
            case .held(let message):
                model.retentionNotice = message
            }
        }
        .onChange(of: retentionText) { _, _ in
            if retentionFocus == .field { retentionErrorMessage = nil }
        }
        .onChange(of: retentionFocus) { old, new in
            if old == .field, new != .field {
                commitRetention()
            }
            if old == .stepper, new != .stepper {
                retentionSettler.flush()
            }
        }
        .confirmationDialog(
            "Delete Older Readings?",
            isPresented: $isConfirmingLowerRetention,
            titleVisibility: .visible
        ) {
            Button("Delete Readings", role: .destructive) {
                confirmLowerRetention()
            }
            Button("Cancel", role: .cancel) {
                cancelLowerRetention()
            }
        } message: {
            Text("Readings older than \(pendingRetentionValue ?? model.settings.retentionDays) days will be deleted. This can't be undone.")
        }
    }

    private var openAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.loginItemStatus == .enabled || model.loginItemStatus == .requiresApproval },
            set: { model.setOpenAtLogin($0) }
        )
    }

    private var showReadingBinding: Binding<Bool> {
        Binding(get: { model.settings.showReadingInMenuBar }, set: { model.updateShowReadingInMenuBar($0) })
    }

    private var unitsBinding: Binding<GlucoseUnit> {
        Binding(get: { model.settings.units }, set: { model.updateUnits($0) })
    }

    /// retentionStepperBinding shows the typed value while it is valid and
    /// the saved one otherwise; a click only proposes a value, which the
    /// settler hands on once the clicks stop.
    private var retentionStepperBinding: Binding<Int> {
        Binding(
            get: {
                if case .valid(let value) = RetentionCommitValidation.validate(retentionText) { return value }
                return model.settings.retentionDays
            },
            set: { value in
                retentionErrorMessage = nil
                retentionText = String(value)
                retentionSettler.propose(value)
            }
        )
    }

    /// commitRetention runs once, on Return or focus loss, never on every
    /// keystroke, and takes over from any stepper clicks still waiting: an
    /// invalid value is refused with an inline message rather than saved or
    /// silently clamped.
    private func commitRetention() {
        retentionSettler.cancel()
        switch RetentionCommitValidation.validate(retentionText) {
        case .invalid(let message):
            retentionErrorMessage = message
        case .valid(let value):
            retentionErrorMessage = nil
            applyRetention(value)
        }
    }

    /// applyRetention saves a valid value: one already equal to the saved
    /// value is left alone (no restart, no confirmation), a lower value asks
    /// first since it deletes readings at the engine's next prune, and a
    /// raised value commits at once.
    private func applyRetention(_ value: Int) {
        guard value != model.settings.retentionDays else {
            retentionText = String(value)
            return
        }
        switch RetentionCommitDecision.decide(current: model.settings.retentionDays, new: value) {
        case .needsConfirmation:
            pendingRetentionValue = value
            isConfirmingLowerRetention = true
        case .commitsImmediately:
            model.updateRetentionDays(value)
            retentionText = String(value)
        }
    }

    /// confirmLowerRetention and cancelLowerRetention are the retention
    /// confirmation's own two actions: confirming applies the pending
    /// value, cancelling restores the saved one, and both then clear the
    /// pending value.
    private func confirmLowerRetention() {
        if let pendingRetentionValue {
            model.updateRetentionDays(pendingRetentionValue)
            retentionText = String(pendingRetentionValue)
        }
        pendingRetentionValue = nil
    }

    private func cancelLowerRetention() {
        retentionText = String(model.settings.retentionDays)
        pendingRetentionValue = nil
    }
}

import AppKit
import CGMRelayCore
import SwiftUI

/// GeneralPaneView holds the settings almost every install touches once:
/// whether CGM Relay opens at login, which unit the menu shows readings
/// in, and how long readings are kept.
struct GeneralPaneView: View {
    @ObservedObject var model: AppModel
    @State private var retentionText = ""
    @State private var retentionErrorMessage: String?
    @State private var pendingRetentionValue: Int?
    @State private var isConfirmingLowerRetention = false
    @FocusState private var retentionFieldFocused: Bool

    var body: some View {
        Form {
            Section {
                Toggle("Open at Login", isOn: openAtLoginBinding)
                if model.loginItemStatus == .requiresApproval {
                    HStack {
                        Text("Needs approval in System Settings")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        AccessibleButton("Open System Settings…", style: .plain, action: openLoginItemsSettings)
                            .font(.caption)
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
                        .focused($retentionFieldFocused)
                        .onSubmit { commitRetention() }
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
        }
        .onChange(of: retentionFieldFocused) { _, isFocused in
            if !isFocused {
                commitRetention()
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

    private var unitsBinding: Binding<GlucoseUnit> {
        Binding(get: { model.settings.units }, set: { model.updateUnits($0) })
    }

    /// commitRetention runs once, on Return or focus loss, never on every
    /// keystroke: a value already equal to the saved one is left alone
    /// (no restart, no confirmation), a lower value asks first since it
    /// deletes readings at the engine's next prune, a raised value
    /// commits at once, and an invalid value is refused with an inline
    /// message rather than saved or silently clamped.
    private func commitRetention() {
        switch RetentionCommitValidation.validate(retentionText) {
        case .invalid(let message):
            retentionErrorMessage = message
        case .valid(let value):
            retentionErrorMessage = nil
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
    }

    private func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
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

import AppKit
import CGMRelayCore
import SwiftUI

/// AlertsPaneView turns on macOS notifications for two things worth
/// knowing about even when nobody is looking at the menu: no new reading
/// for a while, and sign-in failing. Both start off; turning either on is
/// what asks macOS for notification permission.
struct AlertsPaneView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Alert when there's no new reading", isOn: noReadingEnabledBinding)
                if model.settings.noReadingAlertEnabled {
                    Stepper(
                        "After \(model.settings.noReadingAlertMinutes) minutes",
                        value: noReadingMinutesBinding,
                        in: AppSettings.noReadingAlertMinutesRange
                    )
                }
            } header: {
                Text("No new readings")
            }

            Section {
                Toggle("Sign-in failing", isOn: signInFailingBinding)
            } header: {
                Text("Sign-in")
            } footer: {
                Text("Turning either of these on will ask permission to send notifications.")
            }

            if model.notificationPermissionDenied {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Notifications are turned off for CGM Relay in System Settings.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Spacer()
                            AccessibleButton("Open System Settings…", action: model.openNotificationSettings)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, alignment: .top)
        .onAppear { model.refreshNotificationPermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshNotificationPermission()
        }
    }

    private var noReadingEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.settings.noReadingAlertEnabled },
            set: { newValue in
                Task { await model.setNoReadingAlert(enabled: newValue, minutes: model.settings.noReadingAlertMinutes) }
            }
        )
    }

    private var noReadingMinutesBinding: Binding<Int> {
        Binding(
            get: { model.settings.noReadingAlertMinutes },
            set: { newValue in
                Task { await model.setNoReadingAlert(enabled: model.settings.noReadingAlertEnabled, minutes: newValue) }
            }
        )
    }

    private var signInFailingBinding: Binding<Bool> {
        Binding(
            get: { model.settings.signInFailingAlertEnabled },
            set: { newValue in
                Task { await model.setSignInFailingAlert(enabled: newValue) }
            }
        )
    }
}

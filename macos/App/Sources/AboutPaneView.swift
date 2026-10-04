import AppKit
import CGMRelayCore
import SwiftUI

/// AboutPaneView is the app's own page: its version and what changed in
/// it, a check for updates, a Copy Diagnostics button for a bug report or a
/// support message, and the two ways to reach the maintainer.
struct AboutPaneView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updates: UpdatesModel
    @State private var copied = false

    private var appVersion: String { AppVersion.short }

    private var buildNumber: String { AppVersion.build }

    private var macOSVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                        .accessibilityHidden(true)
                    Text("CGM Relay")
                        .font(.title2.bold())
                    Text("Version \(appVersion) (\(buildNumber))")
                        .foregroundStyle(.secondary)
                    Text("Fetches your LibreLinkUp readings every minute and serves them to Nightscout follower apps.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 8) {
                        AccessibleButton("What's New") { NSWorkspace.shared.open(UpdateLinks.changelog) }
                        AccessibleButton(updates.menuTitle, action: updates.perform)
                            .disabled(!updates.canPerformAction)
                    }
                    if let note = updates.unavailableNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    AccessibleButton(copied ? "Copied" : "Copy Diagnostics", style: .primary, action: copyDiagnostics)

                    HStack(spacing: 8) {
                        AccessibleButton("Report a Bug") { FeedbackLinks.open(.bug) }
                        AccessibleButton("Suggest a Feature") { FeedbackLinks.open(.feature) }
                    }

                    Text("Diagnostics include CGM Relay's running state, your settings, and follower activity, never an account, a password, an address, or a reading. Report a Bug and Suggest a Feature open a new GitHub issue with only this app's version and build, your macOS version and your chip. Checking for updates contacts GitHub, which sees this app's version and your internet address.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section {
                SafetyNoticeText(font: .callout)
            } header: {
                Text("Safety Notice")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func copyDiagnostics() {
        let text = model.diagnosticsText(appVersion: appVersion, buildNumber: buildNumber, macOSVersion: macOSVersion)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

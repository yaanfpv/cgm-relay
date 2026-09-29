import AppKit
import CGMRelayCore
import SwiftUI

/// AboutPaneView shows the app's own version and a Copy Diagnostics
/// button, for a person to paste into a bug report or a support message.
struct AboutPaneView: View {
    @ObservedObject var model: AppModel
    @State private var copied = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    }

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

                    AccessibleButton(copied ? "Copied" : "Copy Diagnostics", style: .primary, action: copyDiagnostics)

                    Text("Includes CGM Relay's running state, your settings, and follower activity. Never an account, a password, an address, or a reading.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
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

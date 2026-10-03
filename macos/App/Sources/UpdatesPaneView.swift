import AppKit
import CGMRelayCore
import SwiftUI

/// UpdatesPaneView is where updates are chosen and checked: whether the app
/// looks for them and installs them by itself, what version this is and
/// what changed in it, and a check on demand.
struct UpdatesPaneView: View {
    @ObservedObject var updates: UpdatesModel

    var body: some View {
        Form {
            Section {
                Toggle("Check for updates automatically", isOn: checksBinding)
                Toggle("Download and install updates automatically", isOn: downloadsBinding)
                    .disabled(!updates.automaticallyChecks)
            } header: {
                Text("Automatic Updates")
            } footer: {
                Text("A downloaded update installs the next time CGM Relay quits, or when you choose Restart to Update. It never opens a window or restarts by itself.")
            }
            .disabled(!updates.isRunning)

            Section {
                HStack {
                    Text("CGM Relay \(AppVersion.short) (\(AppVersion.build))")
                    Spacer()
                    AccessibleButton("What's New") { NSWorkspace.shared.open(UpdateLinks.changelog) }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(updates.pending.statusLine ?? "Check for a newer version")
                        Text(lastCheckedText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    AccessibleButton(checkTitle, action: updates.perform)
                        .disabled(!updates.canPerformAction)
                }
                if let note = updates.unavailableNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Version")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var checkTitle: String {
        updates.pending == .none ? "Check Now" : updates.pending.menuTitle
    }

    private var lastCheckedText: String {
        guard let date = updates.lastCheckDate else { return "Not checked yet." }
        return "Last checked \(date.formatted(date: .abbreviated, time: .shortened))."
    }

    private var checksBinding: Binding<Bool> {
        Binding(get: { updates.automaticallyChecks }, set: { updates.setAutomaticallyChecks($0) })
    }

    /// The download choice reads off while checks are off, so it is never
    /// shown on where it cannot act.
    private var downloadsBinding: Binding<Bool> {
        Binding(
            get: { updates.automaticallyChecks && updates.automaticallyDownloads },
            set: { updates.setAutomaticallyDownloads($0) }
        )
    }
}

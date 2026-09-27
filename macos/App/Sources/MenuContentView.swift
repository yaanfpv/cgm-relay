import AppKit
import CGMRelayCore
import SwiftUI

/// MenuContentView is the panel that opens under the menu bar icon. It
/// mounts fresh every time the panel opens (the `.window` menu bar style
/// SwiftUI uses for this app mounts and unmounts its content on each
/// open/close, unlike `.menu` style, which SwiftUI never calls onAppear
/// for at all), which is what onAppear below relies on to satisfy "poll
/// once when the menu opens".
struct MenuContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingStartFresh = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                StatusDotView(dot: model.menuState.dot)
                    .padding(.top, 4)
                Text(model.menuState.statusLine)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(model.menuState.readingLine)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            if !model.menuState.lastPolledLine.isEmpty {
                Text(model.menuState.lastPolledLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if model.canStart {
                Button("Start") { model.start() }
            }
            if model.canStop {
                Button("Stop") { model.stop() }
            }
            if model.canTryAgain {
                Button("Try Again") { model.tryAgain() }
            }
            if model.canStartFresh {
                Button("Start Fresh…") { isConfirmingStartFresh = true }
                    .confirmationDialog(
                        "Start Fresh?",
                        isPresented: $isConfirmingStartFresh,
                        titleVisibility: .visible
                    ) {
                        Button("Start Fresh") { model.startFresh() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("The saved readings will be moved aside, kept on this Mac, and a new empty history will start.")
                    }
            }
            Button("Settings…") {
                // macOS will not bring forward a window of an app with no
                // Dock icon, so the app becomes a regular one while Settings
                // is open; the Settings window turns it back on close.
                NSApp.setActivationPolicy(.regular)
                NSApp.activate()
                openWindow(id: "settings")
                dismiss()
            }

            Divider()

            Button("Quit") { model.quit() }
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
        .onAppear { model.onMenuOpened() }
    }
}

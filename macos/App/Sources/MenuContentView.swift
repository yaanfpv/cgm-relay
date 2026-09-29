import AppKit
import CGMRelayCore
import Foundation
import SwiftUI

/// MenuContentView is the panel that opens under the menu bar icon. It
/// mounts fresh every time the panel opens (the `.window` menu bar style
/// SwiftUI uses for this app mounts and unmounts its content on each
/// open/close, unlike `.menu` style, which SwiftUI never calls onAppear
/// for at all), which is what onAppear below relies on to satisfy "poll
/// once when the menu opens".
struct MenuContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingStartFresh = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            heroReading

            HStack(alignment: .top, spacing: 6) {
                StatusDotView(dot: model.menuState.dot)
                    .padding(.top, 4)
                    .accessibilityHidden(true)
                statusAndAgeLine
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let statusDetail = model.menuState.statusDetail {
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.menuState.lastPolledLine.isEmpty {
                Text(model.menuState.lastPolledLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            actionsRow
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .onAppear { model.onMenuOpened() }
    }

    /// heroReading is the panel's one hero: the current reading, large,
    /// with its unit small beside it, read from MenuDisplayState's own
    /// readingValue/readingUnit fields. Those are nil together exactly
    /// when readingLine falls back to a plain sentence ("No reading
    /// yet", a permanent failure's own explanation), which is what that
    /// case renders here instead.
    @ViewBuilder
    private var heroReading: some View {
        if let value = model.menuState.readingValue, let unit = model.menuState.readingUnit {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 40, weight: .light, design: .rounded))
                    .monospacedDigit()
                Text(unit)
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(model.menuState.readingLine)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// statusAndAgeLine is the one secondary line under the hero: the
    /// short status and, when there is one, the reading's own age
    /// together ("Current · just now"), reading MenuDisplayState's own
    /// shortStatus and statusAge fields directly -- no matching against
    /// statusLine's text here, since statusAge already carries whichever
    /// wording ("just now" beside "Current"/"Stale", "last reading 2 min
    /// ago" beside every other status that still has one) keeps it from
    /// reading as the status's own age instead of the reading's. Falls
    /// back to the status alone when statusAge is nil. Both pieces render
    /// as secondary text (subheadline, at most medium weight) so the hero
    /// reading stays the one large thing on the panel.
    private var statusAndAgeLine: Text {
        let status = Text(model.menuState.shortStatus).font(.subheadline).fontWeight(.medium)
        guard let statusAge = model.menuState.statusAge else { return status }
        return status + Text(" · \(statusAge)").font(.subheadline).foregroundStyle(.secondary)
    }

    /// actionsRow is every action in one balanced row: the engine action
    /// plus Settings… leading, Quit trailing. Grouped in one
    /// GlassEffectContainer on macOS 26+ so the adjacent glass buttons
    /// sample and refract together as one surface, not each on its own;
    /// a plain HStack on the macOS 15 floor, where the buttons carry no
    /// glass to group.
    @ViewBuilder
    private var actionsRow: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer {
                HStack(spacing: 8) {
                    actionButtons
                    Spacer()
                    quitButton
                }
            }
        } else {
            HStack(spacing: 8) {
                actionButtons
                Spacer()
                quitButton
            }
        }
    }

    private var quitButton: some View {
        AccessibleButton("Quit", action: model.quit)
    }

    // Every button below is built through AccessibleButton, since a SwiftUI
    // button exposes no accessible name of its own on current macOS; a
    // confirmationDialog's buttons need none, as the system names them.
    @ViewBuilder
    private var actionButtons: some View {
        if model.canStart {
            AccessibleButton("Start", style: .primary, action: model.start)
        }
        if model.canStop {
            AccessibleButton("Stop", action: model.stop)
        }
        if model.canTryAgain {
            AccessibleButton("Try Again", style: .primary, action: model.tryAgain)
        }
        if model.canStartFresh {
            AccessibleButton("Start Fresh…") { isConfirmingStartFresh = true }
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
        AccessibleButton("Settings…", action: openSettingsWindow)
    }

    /// openSettingsWindow is the Settings… button's action.
    private func openSettingsWindow() {
        // macOS will not bring forward a window of an app with no Dock
        // icon, so the app becomes a regular one while Settings is open;
        // the Settings window turns it back on close.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        openSettings()
        dismiss()
    }
}

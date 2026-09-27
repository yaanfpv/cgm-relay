import SwiftUI

/// SettingsPlaceholderView stands in for the real settings screen, which
/// will let a person enter their LibreLinkUp account and see their
/// Nightscout URL and token. For now it only gives the window a title to
/// open with.
struct SettingsPlaceholderView: View {
    var body: some View {
        VStack {
            Text("Settings are coming soon.")
                .foregroundStyle(.secondary)
        }
        .frame(width: 360, height: 220)
    }
}

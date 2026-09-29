import CGMRelayCore
import SwiftUI

/// SettingsView is the Settings window's whole content: a toolbar of
/// tabs, in the standard macOS Settings look, over the six panes CGM
/// Relay's own account, connection, and configuration live in.
struct SettingsView: View {
    /// SettingsTab names every pane so the Connect pane's "Open
    /// Advanced…" button can switch tabs by setting selection, rather
    /// than each pane needing to know anything about TabView itself.
    enum SettingsTab: Hashable {
        case account, connect, general, advanced, alerts, about
    }

    /// paneWidth is the one width every pane shares, chosen once, so the
    /// tab bar and every pane's content sit centred identically on every
    /// pane instead of each reporting its own natural width back to the
    /// window.
    static let paneWidth: CGFloat = 600

    @ObservedObject var model: AppModel
    @State private var selection: SettingsTab = .account
    @State private var paneHeights: [SettingsTab: CGFloat] = [:]

    var body: some View {
        TabView(selection: $selection) {
            AccountPaneView(model: model)
                .measuringHeight(for: .account, into: $paneHeights)
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
                .tag(SettingsTab.account)
            ConnectPaneView(model: model, openAdvancedPane: { selection = .advanced })
                .measuringHeight(for: .connect, into: $paneHeights)
                .tabItem { Label("Connect", systemImage: "qrcode") }
                .tag(SettingsTab.connect)
            GeneralPaneView(model: model)
                .measuringHeight(for: .general, into: $paneHeights)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            AdvancedPaneView(model: model)
                .measuringHeight(for: .advanced, into: $paneHeights)
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
                .tag(SettingsTab.advanced)
            AlertsPaneView(model: model)
                .measuringHeight(for: .alerts, into: $paneHeights)
                .tabItem { Label("Alerts", systemImage: "bell") }
                .tag(SettingsTab.alerts)
            AboutPaneView(model: model)
                .measuringHeight(for: .about, into: $paneHeights)
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        // One exact width, never a minimum: a minimum would let each
        // pane's own natural width leak through to the window, leaving
        // the tab bar off-centre on a pane narrower than the widest one.
        // The height instead follows whichever pane is in front, read
        // back from paneHeights below -- short panes stay short, and a
        // tall one like Connect renders whole with nothing clipped at
        // the bottom. No outer padding: each pane's own grouped Form
        // already reserves the standard distance from the tab bar and
        // from the window's own edge.
        .frame(width: Self.paneWidth, height: paneHeights[selection])
    }
}

private extension View {
    /// measuringHeight reports this pane's own natural content height
    /// under `tab` straight into SettingsView's paneHeights state.
    /// `.fixedSize(vertical:)` asks the pane for its own ideal height
    /// instead of whatever height its parent offers, and
    /// `.onGeometryChange` reads that resolved height back on every
    /// layout pass and writes it here directly: a `PreferenceKey` cannot
    /// propagate a value up through the TabView boundary between a pane
    /// and this state, so this reads the geometry directly instead.
    func measuringHeight(for tab: SettingsView.SettingsTab, into heights: Binding<[SettingsView.SettingsTab: CGFloat]>) -> some View {
        fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { newValue in
                heights.wrappedValue[tab] = newValue
            }
    }
}

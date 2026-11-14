import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// TailscaleAppDetector says whether Tailscale's Mac app is installed,
/// which decides whether setup asks if the person wants to use it.
public enum TailscaleAppDetector {
    /// bundleIdentifiers are the two builds of the app: the one downloaded
    /// from Tailscale and the one from the App Store.
    public static let bundleIdentifiers = ["io.tailscale.ipn.macsys", "io.tailscale.ipn.macos"]

    /// isInstalled asks Launch Services for each build; lookup is the
    /// system's answer for one bundle identifier, replaceable so a check
    /// needs no real install.
    public static func isInstalled(lookup: (String) -> URL? = systemLookup) -> Bool {
        bundleIdentifiers.contains { lookup($0) != nil }
    }

    public static func systemLookup(_ bundleIdentifier: String) -> URL? {
        #if canImport(AppKit)
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        #else
        nil
        #endif
    }
}

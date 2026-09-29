import SwiftUI

/// ButtonStyling is CGM Relay's one design for every button in the menu
/// panel and the Settings window: the system glass button styles on
/// macOS 26 and later, the plain bordered ones on the macOS 15 floor --
/// chosen by an availability check, never a second look. Both styles pick
/// up the app's own AccentColor asset automatically, so this carries no
/// tint of its own.
extension View {
    /// cgmPrimaryActionStyle marks a pane or panel's one primary action
    /// (Sign In, Start, Try Again, Copy Diagnostics): glass-prominent on
    /// macOS 26+, bordered-prominent otherwise.
    @ViewBuilder
    func cgmPrimaryActionStyle() -> some View {
        if #available(macOS 26, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    /// cgmSecondaryActionStyle is every other button (Stop, Copy, Show,
    /// Sign Out's own trigger, Settings…): glass on macOS 26+, bordered
    /// otherwise. A confirmation dialog's own destructive action keeps the
    /// system's red regardless of this style.
    @ViewBuilder
    func cgmSecondaryActionStyle() -> some View {
        if #available(macOS 26, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

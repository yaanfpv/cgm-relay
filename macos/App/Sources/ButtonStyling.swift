import SwiftUI

/// ButtonStyling is CGM Relay's one design for every button in the menu
/// panel and the Settings window: the system glass button styles on
/// macOS 26 and later, the plain bordered ones on the macOS 15 floor --
/// chosen by an availability check, never a second look. Both styles pick
/// up the app's own AccentColor asset (a deep teal in the light appearance,
/// so the text the system draws in or on it reads). The primary style
/// names ActionFill as its tint, since a prominent button otherwise falls
/// back to the system blue: a deep teal carrying a white AccentLabel in the
/// light appearance, a bright mint carrying a dark one in the dark.
extension View {
    /// cgmPrimaryActionStyle marks a pane or panel's one primary action
    /// (Sign In, Start, Try Again, Copy Diagnostics): glass-prominent on
    /// macOS 26+, bordered-prominent otherwise.
    @ViewBuilder
    func cgmPrimaryActionStyle() -> some View {
        if #available(macOS 26, *) {
            self.buttonStyle(.glassProminent).tint(Color("ActionFill"))
        } else {
            self.buttonStyle(.borderedProminent).tint(Color("ActionFill"))
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

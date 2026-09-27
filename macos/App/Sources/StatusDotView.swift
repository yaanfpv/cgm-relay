import AppKit
import CGMRelayCore
import SwiftUI

/// StatusDotView renders a StatusDot as a small filled circle, the one
/// piece of MenuDisplayState every part of the UI shows: the menu bar
/// icon itself, and the status row inside the open menu.
struct StatusDotView: View {
    let dot: StatusDot

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var color: Color {
        switch dot {
        case .green: .green
        case .amber: .orange
        case .red: .red
        case .grey: .gray
        }
    }
}

/// MenuBarLabel is what appears in the menu bar itself: a small drop
/// glyph tinted by the current status, so the colour is readable at menu
/// bar size without needing a second dot alongside it. It draws a plain
/// (non-template) image rather than a system Image(systemName:): the menu
/// bar renders a template image in its own adaptive monochrome regardless
/// of any tint applied to it, which would erase the one thing this view
/// exists to show.
struct MenuBarLabel: View {
    let dot: StatusDot

    var body: some View {
        Image(nsImage: Self.image(tintedFor: dot))
    }

    private static func image(tintedFor dot: StatusDot) -> NSImage {
        let tint: NSColor
        switch dot {
        case .green: tint = .systemGreen
        case .amber: tint = .systemOrange
        case .red: tint = .systemRed
        case .grey: tint = .secondaryLabelColor
        }

        let base = NSImage(systemSymbolName: "drop.fill", accessibilityDescription: "CGM Relay status")
            ?? NSImage()
        let configured = base.withSymbolConfiguration(.init(paletteColors: [tint])) ?? base
        configured.isTemplate = false
        return configured
    }
}

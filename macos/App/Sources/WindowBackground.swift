import AppKit
import SwiftUI

/// WindowBackground paints the window it is attached to, titlebar included,
/// with the system's window background colour as a plain opaque fill. The
/// system's own window background takes a tint from the wallpaper behind the
/// window ("Allow wallpaper tinting in windows"), so two windows of one app
/// read warmer or cooler depending on where each sits. Setup and Settings
/// share this one fill, so they match each other wherever they are.
struct WindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        BackgroundView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// fill is the window background colour resolved for the window's own
    /// appearance on every draw, rewrapped as plain RGB, which the system
    /// does not tint.
    static let fill = NSColor(name: nil) { appearance in
        var resolved = NSColor.windowBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? resolved
        }
        return resolved
    }

    private final class BackgroundView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.backgroundColor = WindowBackground.fill
            window.isOpaque = true
        }
    }
}

extension View {
    /// cgmWindowBackground is the one background for every CGM Relay window:
    /// the shared fill behind the content, with grouped forms letting it show
    /// through instead of drawing their own tinted one.
    func cgmWindowBackground() -> some View {
        scrollContentBackground(.hidden)
            .containerBackground(Color(nsColor: WindowBackground.fill), for: .window)
            .background(WindowBackground())
    }
}

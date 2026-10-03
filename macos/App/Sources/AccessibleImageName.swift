import AppKit
import SwiftUI

/// AccessibleImageName is AccessibleActionName's non-interactive
/// counterpart (see that type's own comment in AccessibleButtonName.swift):
/// a SwiftUI `Image` with `.accessibilityLabel` exposes no accessible name
/// on current macOS, the same platform gap that leaves a plain `Button`
/// nameless, so this hosts a native `NSImageView` purely to carry the
/// name -- the visible image is untouched.
private struct AccessibleImageName: NSViewRepresentable {
    let label: String

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityLabel(label)
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        nsView.setAccessibilityLabel(label)
    }
}

extension View {
    /// accessibleImageName gives a purely informational image inside an
    /// ordinary window (a QR code, a diagram) a real accessible name,
    /// through the same native-view substitution AccessibleActionName uses
    /// for a control's name.
    func accessibleImageName(_ label: String) -> some View {
        accessibilityRepresentation {
            AccessibleImageName(label: label)
        }
    }
}

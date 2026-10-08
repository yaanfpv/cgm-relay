import AppKit
import SwiftUI

/// AccessibleActionName is an invisible, accessibility-only stand-in for
/// a control, attached through `.accessibleName` below via
/// `.accessibilityRepresentation`. It never appears on screen.
///
/// A plain SwiftUI `Button` exposes no accessible name on current macOS
/// -- no AXTitle, no AXDescription, only the generic "button" -- while
/// an `NSButton` is labelled correctly, so this hosts a native one
/// purely to carry the name and the action; the visible control keeps
/// whatever SwiftUI style renders it.
private struct AccessibleActionName: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    /// isOn, when non-nil, marks this representation as one option of a
    /// radio choice rather than a momentary action: the native button is
    /// given the radio button type, so its role and its on/off value
    /// (selected or not) both reach VoiceOver the same way the Units
    /// segmented control's own options do, in place of the generic
    /// "radio button" every option in a `Picker` styled `.radioGroup`
    /// announces on this platform when its content is more than a single
    /// plain `Text` (see AdvancedPaneView's reachRow).
    let isOn: Bool?
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.fire))
        if isOn != nil {
            button.setButtonType(.radio)
        }
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        nsView.title = title
        nsView.state = (isOn ?? false) ? .on : .off
        nsView.isEnabled = isEnabled
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) {
            self.action = action
        }
        @objc func fire() {
            action()
        }
    }
}

extension View {
    /// accessibleName gives a control a real accessible name on a
    /// platform where its own kind does not expose one (see
    /// AccessibleActionName's own comment), by substituting a native
    /// NSButton as this view's accessibility representation. The visible
    /// control, and everything else about it, is untouched -- only what
    /// assistive technology sees changes.
    func accessibleName(_ title: String, action: @escaping () -> Void) -> some View {
        accessibilityRepresentation {
            AccessibleActionName(title: title, isOn: nil, action: action)
        }
    }

    /// accessibleRadioName is accessibleName for one option of a radio
    /// choice: isSelected becomes the native button's own on/off value.
    func accessibleRadioName(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        accessibilityRepresentation {
            AccessibleActionName(title: title, isOn: isSelected, action: action)
        }
    }
}

/// CGMButtonStyle picks which of ButtonStyling's two looks AccessibleButton
/// draws with, or `.plain` for a control that carries its own separate
/// styling (a caption-sized link beside explanatory text).
enum CGMButtonStyle {
    case primary, secondary, plain
}

/// AccessibleButton draws a styled `Button` and gives it its accessible
/// name from the same title and the same action closure passed here once,
/// rather than a separate `.accessibleName` call repeating both: the two
/// can never disagree because there is only one place either is written.
/// `accessibleName` only needs its own value where VoiceOver should say
/// more than the visible label does (a bare "Copy" beside two rows needs
/// "Copy Address"/"Copy Token" to tell them apart).
struct AccessibleButton: View {
    let title: String
    var accessibleName: String?
    var role: ButtonRole?
    var style: CGMButtonStyle = .secondary
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlActiveState) private var controlActiveState

    init(_ title: String, accessibleName: String? = nil, role: ButtonRole? = nil, style: CGMButtonStyle = .secondary, action: @escaping () -> Void) {
        self.title = title
        self.accessibleName = accessibleName
        self.role = role
        self.style = style
        self.action = action
    }

    var body: some View {
        styledButton
            .accessibleName(accessibleName ?? title, action: action)
    }

    @ViewBuilder
    private var styledButton: some View {
        switch style {
        case .primary:
            // In a key window the label is the AccentLabel ink, chosen to read
            // on the ActionFill tint in each appearance. In a background window
            // the system swaps the tint for its own grey fill, and its own
            // dimmed label on that fill is too faint to read, so the label
            // becomes InactiveActionLabel: still visibly at rest, but legible.
            // Disabled, the system draws both fill and label.
            Button(role: role, action: action) {
                if !isEnabled {
                    Text(title)
                } else if controlActiveState == .inactive {
                    Text(title).foregroundStyle(Color("InactiveActionLabel"))
                } else {
                    Text(title).foregroundStyle(Color("AccentLabel"))
                }
            }
            .cgmPrimaryActionStyle()
        case .secondary:
            Button(title, role: role, action: action).cgmSecondaryActionStyle()
        case .plain:
            Button(title, role: role, action: action)
        }
    }
}

import AppKit
import SwiftUI

/// SetupWindow names the first-launch setup window and is the one way the
/// app opens it, so a launch and the menu's "Finish setup…" behave alike.
enum SetupWindow {
    static let id = "setup"
}

enum WindowActivation {
    /// bringAppForward is what opening any window of this menu-bar-only app
    /// starts with: macOS will not bring forward a window of an app with no
    /// Dock icon, so the app becomes a regular one while the window is
    /// open, and each window turns it back on close.
    @MainActor
    static func bringAppForward() {
        NSApp.setActivationPolicy(.regular)
        #if DEBUG
        if keepWindowsBehind { return }
        #endif
        NSApp.activate()
    }

    #if DEBUG
    /// keepWindowsBehind is a development walk's switch for driving the app
    /// without ever interrupting anyone at the Mac: the app neither activates
    /// nor orders its windows above the app in use.
    static var keepWindowsBehind: Bool {
        UserDefaults.standard.bool(forKey: "CGMRelayKeepWindowsBehind")
    }
    #endif
}

extension WindowActivation {
    /// returnToMenuBarOnlyIfNoWindowsRemain is what the app does whenever a
    /// window closes: the Dock icon goes only once neither Settings
    /// nor setup is left on screen (or minimized), so closing one never
    /// strands the other. Checked one turn later, when the closing window
    /// has left the screen.
    @MainActor
    static func returnToMenuBarOnlyIfNoWindowsRemain() {
        DispatchQueue.main.async {
            if appWindows.isEmpty {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    /// closeAppWindows closes Settings and setup, which returns the app to
    /// the menu bar.
    @MainActor
    static func closeAppWindows() {
        for window in appWindows {
            window.close()
        }
        returnToMenuBarOnlyIfNoWindowsRemain()
    }

    /// appWindows are the windows a person can see or has minimized: the
    /// menu panel, the status item and the app's hidden window are not.
    @MainActor
    private static var appWindows: [NSWindow] {
        NSApp.windows.filter { window in
            (window.isVisible || window.isMiniaturized)
                && window.styleMask.contains(.titled)
                && !(window is NSPanel)
        }
    }
}

/// SetupPresenter opens setup once when the model asks for it after a
/// launch that found setup incomplete. It rides on SceneBridgeView, the one
/// view that exists from launch.
struct SetupPresenter: ViewModifier {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.task(id: model.setupPresentationRequest) {
            guard model.setupPresentationRequest > 0 else { return }
            WindowActivation.bringAppForward()
            openWindow(id: SetupWindow.id)
        }
    }
}

/// WindowFronting puts the window it is attached to above every other app's
/// windows the moment it appears. A launch that finds setup incomplete has
/// no click behind it, so macOS may decline to make this app the active one;
/// ordering the window front regardless keeps setup in front of whatever
/// app is active.
struct WindowFronting: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        FrontingView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class FrontingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            #if DEBUG
            if WindowActivation.keepWindowsBehind { return }
            #endif
            // Deferred one turn: SwiftUI orders a newly opened window
            // itself right after this, and that ordering would otherwise
            // land it behind the active app's windows again.
            DispatchQueue.main.async {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
    }
}

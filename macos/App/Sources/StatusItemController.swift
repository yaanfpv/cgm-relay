import AppKit
import CGMRelayCore
import Combine
import SwiftUI

/// StatusItemController owns CGM Relay's menu bar item: the mark, the
/// reading beside it, the panel a primary click opens and the menu a
/// secondary click opens.
///
/// The item is an AppKit status item rather than a SwiftUI `MenuBarExtra`
/// because a status bar button's action is what a pointer click,
/// accessibility's press, VoiceOver's activate and Control-F8 then Space
/// all invoke, so the panel opens for every one of them; the SwiftUI
/// scene's item exposed a press that opened nothing.
@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let updates: UpdatesModel
    private let sceneActions: SceneActions
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var rendered: MenuBarItemState?
    private let pressOpensContextMenu: Bool
    private var observations: Set<AnyCancellable> = []

    /// pressOpensContextMenu makes a plain press open the right-click menu,
    /// so a development walk with no pointer can reach it. It is only ever
    /// true in a DEBUG build (see CGMRelayApp).
    init(model: AppModel, updates: UpdatesModel, sceneActions: SceneActions, pressOpensContextMenu: Bool = false) {
        self.model = model
        self.updates = updates
        self.pressOpensContextMenu = pressOpensContextMenu
        self.sceneActions = sceneActions
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.autosaveName = "CGMRelayStatusItem"
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemPressed(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
        }

        let panelActions = MenuPanelActions(
            openSettings: { [weak self] in self?.openSettings() },
            openSetup: { [weak self] in self?.openSetup() },
            performUpdate: { [weak self] in self?.performUpdate() }
        )
        let hosting = NSHostingController(rootView: MenuContentView(model: model, updates: updates, actions: panelActions))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient

        // The item redraws only when what it displays changes, so an
        // unrelated model change costs a comparison and nothing more.
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshItem() }
            .store(in: &observations)
        updates.$pending
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshItem() }
            .store(in: &observations)
        model.$menuPanelRequest
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.showPanel() }
            .store(in: &observations)
        refreshItem()
    }

    // MARK: - The item

    private func refreshItem() {
        let next = model.menuBarItemState(update: updates.pending)
        guard next != rendered, let button = statusItem.button else { return }
        rendered = next

        button.image = MenuBarMark.image(for: next.tint, showsUpdateMark: next.showsUpdateMark)
        button.setAccessibilityLabel(next.accessibilityLabel)
        button.toolTip = next.accessibilityLabel
        if let title = next.title {
            button.imagePosition = .imageLeading
            statusItem.length = stableLength(for: title, in: button)
        } else {
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString()
            statusItem.length = NSStatusItem.variableLength
        }
    }

    /// stableLength sets the button's title to `title` and returns a length
    /// that fits the widest arrow after the same digits, so the item keeps
    /// its width when only the trend changes. The digits are monospaced;
    /// the arrows are not.
    private func stableLength(for title: String, in button: NSStatusBarButton) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        func setTitle(_ text: String) {
            button.attributedTitle = NSAttributedString(string: text, attributes: [.font: font])
        }
        let digits = title.split(separator: " ").first.map(String.init) ?? title
        guard title != digits else {
            setTitle(title)
            return NSStatusItem.variableLength
        }
        var widest: CGFloat = 0
        for arrow in TrendArrow.all {
            setTitle("\(digits) \(arrow)")
            widest = max(widest, button.fittingSize.width)
        }
        setTitle(title)
        return widest
    }

    // MARK: - Opening

    @objc private func statusItemPressed(_ sender: NSStatusBarButton) {
        if pressOpensContextMenu || Self.isSecondaryClick(NSApp.currentEvent) {
            showContextMenu()
        } else if popover.isShown {
            popover.performClose(sender)
        } else {
            showPanel()
        }
    }

    /// isSecondaryClick is true for a right click and for a control-click,
    /// the Mac's other way of asking for a context menu. Anything else,
    /// including a press with no mouse event behind it, is a primary
    /// click.
    private static func isSecondaryClick(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        switch event.type {
        case .rightMouseUp:
            return true
        case .leftMouseUp:
            return event.modifierFlags.contains(.control)
        default:
            return false
        }
    }

    private func showPanel() {
        guard let button = statusItem.button, !popover.isShown else { return }
        model.onMenuOpened()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showContextMenu() {
        guard let button = statusItem.button else { return }
        popover.performClose(nil)
        let menu = NSMenu()
        menu.autoenablesItems = false
        // A menu popped up in a view inherits that view's appearance, and
        // the status button follows the menu bar, which can be dark over a
        // dark wallpaper while the system is light. System menu bar menus
        // follow the system appearance, so this one does too.
        menu.appearance = NSApp.effectiveAppearance
        let updateItem = menu.addItem(withTitle: updates.menuTitle, action: #selector(performUpdate), keyEquivalent: "")
        updateItem.target = self
        updateItem.isEnabled = updates.canPerformAction
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Report a Bug…", action: #selector(reportBug), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit CGM Relay", action: #selector(quit), keyEquivalent: "q").target = self
        // The system draws its own icon on a few common items (Settings…)
        // and none on the rest; every item here stays plain.
        if #available(macOS 27, *) {
            for item in menu.items { item.preferredImageVisibility = .hidden }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func openSettings() {
        popover.performClose(nil)
        WindowActivation.bringAppForward()
        sceneActions.openSettings?()
    }

    @objc private func performUpdate() {
        popover.performClose(nil)
        updates.perform()
    }

    private func openSetup() {
        popover.performClose(nil)
        WindowActivation.bringAppForward()
        sceneActions.openWindow?(id: SetupWindow.id)
    }

    @objc private func reportBug() {
        FeedbackLinks.open(.bug)
    }

    @objc private func quit() {
        model.quit()
    }
}

/// MenuPanelActions are the panel's ways out into the rest of the app,
/// handed to it so the panel view knows nothing of the scenes or the
/// status item behind them.
struct MenuPanelActions {
    let openSettings: () -> Void
    let openSetup: () -> Void
    let performUpdate: () -> Void
}

/// MenuBarMark draws the menu bar mark for a tint: a round drop (MenuBarDrop)
/// as a vector, so it is sharp at every scale, with a small dot beside its
/// point while an update is waiting.
enum MenuBarMark {
    private static let height: CGFloat = 16
    private static let updateDotDiameter: CGFloat = 5

    /// image is a template image while all is well, so the menu bar draws
    /// it in its own appearance (light, dark, tinted, over a full-screen
    /// app's hidden bar). A coloured mark is drawn at display time, so a
    /// dynamic system colour resolves in whichever appearance the bar is
    /// in when it is shown.
    static func image(for tint: MenuBarItemState.Tint, showsUpdateMark: Bool = false) -> NSImage {
        let color: NSColor
        switch tint {
        case .plain: color = .black
        case .amber: color = .systemOrange
        case .red: color = .systemRed
        case .grey: color = .systemGray
        }
        let dropWidth = (height * MenuBarDrop.widthOverHeight).rounded(.up) + 1
        let width = dropWidth + (showsUpdateMark ? updateDotDiameter : 0)
        let image = NSImage(size: NSSize(width: width, height: height + 1), flipped: false) { rect in
            let transform = AffineTransform(translationByX: dropWidth / 2, byY: 0.5)
            let path = MenuBarDrop.path(height: height)
            path.transform(using: transform)
            color.setFill()
            path.fill()
            if showsUpdateMark {
                let dot = NSRect(x: rect.width - updateDotDiameter, y: rect.height - updateDotDiameter, width: updateDotDiameter, height: updateDotDiameter)
                NSBezierPath(ovalIn: dot).fill()
            }
            return true
        }
        image.isTemplate = tint == .plain
        return image
    }
}

/// SceneActions holds the two ways SwiftUI opens a scene, captured from
/// the one view that lives in the app's scene hierarchy from launch (see
/// SceneBridgeView), so AppKit code such as the status item can open
/// Settings and setup, and which Settings pane opens.
@MainActor
final class SceneActions {
    var openWindow: OpenWindowAction?
    var openSettings: (() -> Void)?
    let settingsNavigation = SettingsNavigation()

    /// showSettings brings the app forward and opens Settings on one pane.
    func showSettings(tab: SettingsView.SettingsTab) {
        settingsNavigation.tab = tab
        WindowActivation.bringAppForward()
        openSettings?()
    }
}

/// SceneBridgeView is the app's one always-present view: an invisible
/// window whose only job is to give the app a place in the SwiftUI scene
/// hierarchy from launch, from which it captures the scene actions and
/// opens first-launch setup when the model asks.
struct SceneBridgeView: View {
    @ObservedObject var model: AppModel
    let actions: SceneActions
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    static let windowID = "scene-bridge"

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .background(HiddenWindow())
            .onAppear {
                actions.openWindow = openWindow
                actions.openSettings = { openSettings() }
            }
            .modifier(SetupPresenter(model: model))
    }
}

/// HiddenWindow keeps the window it is placed in off screen for good,
/// including when the system presents it again (an app reopen, a click on
/// the app's Dock icon or a Finder open of the running app).
private struct HiddenWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        HidingView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class HidingView: NSView {
        private var visibility: AnyCancellable?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.isExcludedFromWindowsMenu = true
            window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
            visibility = window.publisher(for: \.isVisible)
                .filter { $0 }
                .receive(on: DispatchQueue.main)
                .sink { _ in window.orderOut(nil) }
        }
    }
}

import AppKit
import CGMRelayCore

/// AppShutdown is what runs before the app process ends for a real quit:
/// the model stops its poller and its engine and waits for the engine to
/// be gone. CGMRelayApp sets it once the model exists.
@MainActor
enum AppShutdown {
    static var run: (() async -> Void)?
}

/// AppDelegate keeps the relay running when the person quits from the Dock
/// or from another app: that only closes the windows and returns the app to
/// the menu bar. Every quit asked for inside the app, the session ending
/// and the updater replacing the app really quit (QuitPolicy), and each
/// waits for the engine to exit before the app does.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// updaterBundleIdentifier names Sparkle's installer helper, the process
    /// that sends the quit request when an update is ready to replace the app.
    private static let updaterBundleIdentifier = "org.sparkle-project.Sparkle.Updater"

    private var sessionEnding = false
    private var windowClosings: NSObjectProtocol?
    private var powerOff: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Every window of the app returns it to the menu bar when the last
        // one closes, however it was closed.
        windowClosings = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { WindowActivation.returnToMenuBarOnlyIfNoWindowsRemain() }
        }
        powerOff = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessionEnding = true }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let isQuitEvent = event?.eventClass == AEEventClass(kCoreEventClass) && event?.eventID == AEEventID(kAEQuitApplication)
        let terminates = QuitPolicy.shouldTerminate(
            quitEventPresent: isQuitEvent,
            eventReason: isQuitEvent ? Self.quitReason(of: event) : nil,
            sessionEnding: sessionEnding,
            fromUpdater: isQuitEvent && Self.isFromUpdater(event)
        )
        guard terminates else {
            WindowActivation.closeAppWindows()
            return .terminateCancel
        }
        Task { @MainActor in
            await AppShutdown.run?()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// isFromUpdater is whether the quit Apple event came from Sparkle's own
    /// installer helper, which asks the app to quit so it can replace it.
    private static func isFromUpdater(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let senderPID = event?.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value,
              let sender = NSRunningApplication(processIdentifier: senderPID)
        else { return false }
        return sender.bundleIdentifier == Self.updaterBundleIdentifier
    }

    /// quitReason is the reason the quit Apple event in flight carries: the
    /// system's own quit at log out, restart or shut down names one, and a
    /// Dock quit does not.
    private static func quitReason(of event: NSAppleEventDescriptor?) -> UInt32? {
        let key: AEKeyword = 0x7768_793F
        guard let event else { return nil }
        let descriptor = event.attributeDescriptor(forKeyword: key) ?? event.paramDescriptor(forKeyword: key)
        guard let descriptor else { return nil }
        return descriptor.enumCodeValue != 0 ? descriptor.enumCodeValue : descriptor.typeCodeValue
    }
}

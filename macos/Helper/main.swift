import CGMRelayCore
import Darwin
import Foundation
import IOKit.ps
import Security

// The sleep reset helper: a launchd daemon that runs as root while it is
// registered. It looks at the process list and the power source, and when
// CGM Relay is not running and the sleep setting is on or unknown it runs
// the one fixed command in SleepResetHelper.command. It takes no input from
// anyone and reads nothing from a place a user can write.

/// intervalSeconds is how often the helper looks when nothing has told it
/// to. A power source change looks at once.
let intervalSeconds: TimeInterval = 20

/// processListing is the real process list for SleepResetHelper.appIsRunning,
/// nil when the signature requirement cannot be built (the caller then counts
/// the app as running).
func processListing() -> SleepResetHelper.ProcessListing? {
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(SleepResetHelper.appRequirement as CFString, [], &requirement) == errSecSuccess,
          let requirement
    else { return nil }
    return SleepResetHelper.ProcessListing(
        countHint: { proc_listallpids(nil, 0) },
        fill: { pids in proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)) },
        executableName: { pid in
            var pathBuffer = [CChar](repeating: 0, count: 4096)
            let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            guard length > 0 else { return nil }
            let path = String(decoding: pathBuffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return (path as NSString).lastPathComponent
        },
        isGenuineApp: { pid in
            var code: SecCode?
            let attributes = [kSecGuestAttributePid: pid] as CFDictionary
            guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
            return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
        }
    )
}

/// sleepDisabled is the system's current sleep setting, nil when it cannot
/// be read.
func sleepDisabled() -> Bool? {
    typealias CopySettings = @convention(c) () -> Unmanaged<CFDictionary>?
    guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
          let symbol = dlsym(handle, "IOPMCopySystemPowerSettings")
    else { return nil }
    let copy = unsafeBitCast(symbol, to: CopySettings.self)
    guard let settings = copy()?.takeRetainedValue() as? [String: Any],
          let value = settings["SleepDisabled"] as? Int
    else { return nil }
    return value != 0
}

func runResetCommand() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: SleepResetHelper.command[0])
    process.arguments = Array(SleepResetHelper.command.dropFirst())
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

nonisolated(unsafe) var state = SleepResetHelper.Look()

func look() {
    let running = processListing().map { SleepResetHelper.appIsRunning(using: $0) } ?? true
    let power = SystemPowerSource().snapshot()
    state.run(
        appRunning: running,
        onBattery: power.isLaptop && !power.onACPower,
        sleepDisabled: sleepDisabled(),
        runCommand: runResetCommand
    )
}

look()
let timer = Timer(timeInterval: intervalSeconds, repeats: true) { _ in look() }
RunLoop.main.add(timer, forMode: .common)
if let source = IOPSNotificationCreateRunLoopSource({ _ in
    state.powerSourceChanged()
    look()
}, nil)?.takeRetainedValue() {
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
}
RunLoop.main.run()

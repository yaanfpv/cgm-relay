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

/// appIsRunning is whether a process of CGM Relay is in the process list:
/// one whose code signature meets SleepResetHelper.appRequirement, which
/// names the bundle identifier. The process's file name only narrows the
/// list to the few worth checking.
func appIsRunning() -> Bool {
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(SleepResetHelper.appRequirement as CFString, [], &requirement) == errSecSuccess,
          let requirement
    else { return true }
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return true }
    var pids = [pid_t](repeating: 0, count: Int(count) + 64)
    let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard filled > 0 else { return true }
    var pathBuffer = [CChar](repeating: 0, count: 4096)
    for pid in pids.prefix(Int(filled)) where pid > 0 {
        let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard length > 0 else { continue }
        let path = String(decoding: pathBuffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard (path as NSString).lastPathComponent == SleepResetHelper.appExecutableName else { continue }
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { continue }
        if SecCodeCheckValidity(code, [], requirement) == errSecSuccess { return true }
    }
    return false
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

/// wroteWithoutReading is set after a write made while the setting could
/// not be read, so an unreadable setting does not run the command at every
/// look. Anything that could have changed the answer clears it: the app
/// running, or a power source change.
nonisolated(unsafe) var wroteWithoutReading = false

func look() {
    let running = appIsRunning()
    let power = SystemPowerSource().snapshot()
    let current = sleepDisabled()
    if running || current != nil { wroteWithoutReading = false }
    guard SleepResetPolicy.decide(
        appRunning: running,
        onBattery: power.isLaptop && !power.onACPower,
        sleepDisabled: current
    ) == .writeOff else { return }
    if current == nil && wroteWithoutReading { return }
    if runResetCommand() && current == nil { wroteWithoutReading = true }
}

look()
let timer = Timer(timeInterval: intervalSeconds, repeats: true) { _ in look() }
RunLoop.main.add(timer, forMode: .common)
if let source = IOPSNotificationCreateRunLoopSource({ _ in
    wroteWithoutReading = false
    look()
}, nil)?.takeRetainedValue() {
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
}
RunLoop.main.run()

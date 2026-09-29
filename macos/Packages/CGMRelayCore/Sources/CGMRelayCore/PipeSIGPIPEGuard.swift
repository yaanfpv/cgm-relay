import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// disableSIGPIPE asks the kernel to fail fileDescriptor's own writes
/// with EPIPE instead of raising SIGPIPE into this process once its
/// read end has closed: this app writes an engine's whole stdin
/// configuration in one shot and has no chance to notice the child
/// exiting or closing stdin first (a crash-restart race, or a binary
/// that fails at once), so without this guard that write's default
/// SIGPIPE action would kill CGM Relay itself, with no log and no menu
/// state. Scoped to this one file descriptor (macOS's own F_SETNOSIGPIPE
/// fcntl) rather than signal(SIGPIPE, SIG_IGN) process-wide: a global
/// ignore would silence a genuine pipe break anywhere else in the
/// process too, not just this app's own two child-process writes.
func disableSIGPIPE(for fileDescriptor: Int32) {
    _ = fcntl(fileDescriptor, F_SETNOSIGPIPE, 1)
}

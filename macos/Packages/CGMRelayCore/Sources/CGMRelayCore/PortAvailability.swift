import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// PortBinding answers whether a listener could bind one address and port
/// right now. SystemPortBinder is the real answer, made by binding a
/// socket; tests may hand in a table instead.
public protocol PortBinding: Sendable {
    func canBind(host: String, port: Int) -> Bool
}

/// SystemPortBinder binds a real listening socket on host:port with the
/// same address-reuse option the engine's own listener sets, then closes it
/// at once. A successful bind reserves nothing: another program can take the
/// port the moment this returns, which is why a failed bind by the engine
/// itself is still reported separately (EngineSupervisor.FailureReason.portInUse).
public struct SystemPortBinder: PortBinding {
    public init() {}

    public func canBind(host: String, port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }
        let isIPv6 = host.contains(":")
        var address4 = sockaddr_in()
        var address6 = sockaddr_in6()
        if isIPv6 {
            address6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address6.sin6_family = sa_family_t(AF_INET6)
            address6.sin6_port = in_port_t(port).bigEndian
            guard inet_pton(AF_INET6, host, &address6.sin6_addr) == 1 else { return false }
        } else {
            address4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address4.sin_family = sa_family_t(AF_INET)
            address4.sin_port = in_port_t(port).bigEndian
            guard inet_pton(AF_INET, host, &address4.sin_addr) == 1 else { return false }
        }

        let descriptor = socket(isIPv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var enabled: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))
        if isIPv6 {
            // Only the IPv6 address itself is being tested: a dual-stack
            // wildcard would also claim the IPv4 one.
            _ = setsockopt(descriptor, IPPROTO_IPV6, IPV6_V6ONLY, &enabled, socklen_t(MemoryLayout<Int32>.size))
        }

        let bound: Int32 = if isIPv6 {
            withUnsafePointer(to: &address6) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            withUnsafePointer(to: &address4) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if bound != 0 {
            // An address family or address this Mac does not have cannot be
            // taken by anyone, so it never blocks the port.
            return errno == EADDRNOTAVAIL || errno == EAFNOSUPPORT
        }
        return listen(descriptor, 1) == 0
    }
}

/// PortAvailability decides which follower port setup uses and whether a
/// typed one is free, over the addresses the chosen reach actually binds.
public enum PortAvailability {
    /// candidateCount is how many ports setup tries in all, the default port
    /// first and then each next one up.
    public static let candidateCount = 50

    /// SetupPortChoice is where the search for a free port ended.
    public enum SetupPortChoice: Sendable, Equatable {
        case free(Int)
        /// exhausted means every candidate port was taken; first and last
        /// name the range that was tried, for the sentence setup shows.
        case exhausted(first: Int, last: Int)
    }

    /// StartPortDecision is what happens to the follower port before an
    /// engine start.
    public enum StartPortDecision: Sendable, Equatable {
        /// keep starts on the saved port as it is.
        case keep
        /// use starts on this port, saving it when it differs.
        case use(Int)
        /// exhausted means every candidate port was taken.
        case exhausted(first: Int, last: Int)
        /// statusPortLocked means Tailscale HTTPS holds the port fixed and it
        /// is the reserved status port: the engine can never listen there,
        /// and moving it would strand the Tailscale handler, so the start is
        /// refused until Tailscale HTTPS is turned off.
        case statusPortLocked
    }

    /// hostsToCheck is every address a port must be free on for the engine
    /// to bind bindHost: the IPv4 address itself and, for the loopback and
    /// all-interfaces hosts, the IPv6 counterpart a listener elsewhere on
    /// this Mac could hold. A tailnet address has no IPv6 counterpart here.
    public static func hostsToCheck(bindHost: String) -> [String] {
        switch bindHost {
        case "127.0.0.1": return ["127.0.0.1", "::1"]
        case "0.0.0.0": return ["0.0.0.0", "::"]
        default: return [bindHost]
        }
    }

    /// isFree is whether the engine could listen on port at bindHost. The
    /// reserved port, the relay's own status listener, is never free: both
    /// listeners cannot hold it.
    public static func isFree(port: Int, bindHost: String, binder: any PortBinding, reserved: Int? = nil) -> Bool {
        guard port != reserved else { return false }
        return hostsToCheck(bindHost: bindHost).allSatisfy { binder.canBind(host: $0, port: port) }
    }

    /// port(inAddress:) is the port of a host:port listen address, nil when
    /// it has none.
    public static func port(inAddress address: String) -> Int? {
        address.split(separator: ":").last.flatMap { Int($0) }
    }

    /// typedPortRefusal is the sentence refusing a typed follower port, nil
    /// when it is usable: the relay's own status port is refused as its own,
    /// and one another app holds as that app's.
    public static func typedPortRefusal(port: Int, bindHost: String, binder: any PortBinding, reserved: Int?) -> String? {
        if port == reserved { return reservedMessage(port: port) }
        return isFree(port: port, bindHost: bindHost, binder: binder) ? nil : inUseMessage(port: port)
    }

    /// firstFreePort tries start, then each next port, for candidates ports
    /// in all and never past 65535, and returns the first one free on every
    /// address bindHost needs.
    public static func firstFreePort(
        from start: Int,
        bindHost: String,
        binder: any PortBinding,
        candidates: Int = candidateCount,
        reserved: Int? = nil
    ) -> SetupPortChoice {
        let last = min(start + candidates - 1, AppSettings.portRange.upperBound)
        if start <= last {
            for port in start...last where isFree(port: port, bindHost: bindHost, binder: binder, reserved: reserved) {
                return .free(port)
            }
        }
        return .exhausted(first: start, last: last)
    }

    /// setupPort decides the port for an engine start during setup: current
    /// stays whenever it is still free on every address bindHost needs, since
    /// it may already be in a follower app, and only a taken one is replaced by
    /// the first free port searching from the default.
    public static func setupPort(
        current: Int,
        default defaultPort: Int,
        bindHost: String,
        binder: any PortBinding,
        candidates: Int = candidateCount,
        reserved: Int? = nil
    ) -> SetupPortChoice {
        if AppSettings.portRange.contains(current), isFree(port: current, bindHost: bindHost, binder: binder, reserved: reserved) {
            return .free(current)
        }
        return firstFreePort(from: defaultPort, bindHost: bindHost, binder: binder, candidates: candidates, reserved: reserved)
    }

    /// startPort decides the follower port before an engine start. While
    /// Tailscale HTTPS holds the port (locked) it is kept, unless it is the
    /// reserved status port, which refuses the start. Otherwise, while
    /// searching (setup unfinished and the port not one the person chose) it
    /// is setupPort; after that the saved port stays, unless it is the
    /// reserved status port, which is replaced like a taken port in setup.
    public static func startPort(
        current: Int,
        default defaultPort: Int,
        searching: Bool,
        locked: Bool,
        bindHost: String,
        binder: any PortBinding,
        candidates: Int = candidateCount,
        reserved: Int?
    ) -> StartPortDecision {
        if locked {
            return current == reserved ? .statusPortLocked : .keep
        }
        guard searching || current == reserved else { return .keep }
        switch setupPort(current: current, default: defaultPort, bindHost: bindHost, binder: binder, candidates: candidates, reserved: reserved) {
        case .free(let port):
            return .use(port)
        case .exhausted(let first, let last):
            return .exhausted(first: first, last: last)
        }
    }

    /// inUseMessage is the sentence for a port another app already holds.
    public static func inUseMessage(port: Int) -> String {
        "Port \(port) is in use by another app."
    }

    /// reservedMessage is the sentence for the port the relay's own status
    /// listener uses.
    public static func reservedMessage(port: Int) -> String {
        "CGM Relay already uses port \(port) for itself. Choose another."
    }

    /// exhaustedMessage is the sentence setup shows when no candidate port
    /// was free.
    public static func exhaustedMessage(first: Int, last: Int) -> String {
        "Ports \(first) to \(last) are all in use by other apps. Open Advanced to choose a port."
    }
}

import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(SystemConfiguration)
import SystemConfiguration
#endif

/// NetworkReach names who the Advanced pane's port can accept a
/// connection from. thisMacOnly is the default: it never exposes the
/// engine beyond this one Mac.
public enum NetworkReach: String, Codable, Sendable, CaseIterable {
    case thisMacOnly
    case myTailnet
    case myLocalNetwork
}

/// NetworkInterfaceAddress is one IPv4 address this Mac currently has, on
/// one named interface -- the input ReachAddressResolver's own mapping
/// takes, kept separate from SystemNetworkInterfaces's real
/// getifaddrs-backed collection so the mapping itself is testable with a
/// synthetic list and no dependency on this Mac's actual network state.
public struct NetworkInterfaceAddress: Sendable, Equatable {
    public let name: String
    public let address: String

    public init(name: String, address: String) {
        self.name = name
        self.address = address
    }
}

/// ReachAddressAvailability is whether the address a chosen NetworkReach
/// implies actually exists on this Mac right now: myTailnet before
/// Tailscale connects, or myLocalNetwork with no network connection at
/// all, have no address to offer, and the caller must say so rather than
/// presenting the loopback fallback as if it were a real answer.
public enum ReachAddressAvailability: Sendable, Equatable {
    case available(String)
    case unavailable(reason: String)
}

/// BoundAddressDecision is whether the engine needs restarting onto a
/// freshly resolved bind host: never while nothing is currently bound
/// (currentBoundHost nil -- there is nothing running to restart), and
/// only when the freshly resolved host actually differs from the one the
/// engine is bound to right now, so a network check that finds nothing
/// has changed never disturbs a running engine.
public enum BoundAddressDecision: Sendable, Equatable {
    case restartNeeded
    case unchanged

    public static func decide(currentBoundHost: String?, impliedBindHost: String) -> BoundAddressDecision {
        guard let currentBoundHost else { return .unchanged }
        return currentBoundHost == impliedBindHost ? .unchanged : .restartNeeded
    }
}

/// ConnectPaneAddressState is what the Connect pane shows and encodes into
/// its QR code. .ready never carries an address the running engine is not
/// actually bound to, and, because rebinding onto a freshly chosen reach
/// happens asynchronously (a restart the engine may still be mid-way
/// through), it also never carries an address while boundHost disagrees
/// with impliedBindHost, the host the current reach implies right now: a
/// disagreement there means the network setting is still being applied,
/// not that the address boundHost names is ready. Once bound and implied
/// agree, myTailnet checks the bound host against the Tailscale range
/// itself, since a not-yet-connected tailnet leaves the engine bound to
/// its own loopback fallback instead of a real tailnet address;
/// myLocalNetwork uses this Mac's `.local` name (or, without one, its
/// current LAN address) over https, since the engine listens there on each
/// private address with TLS and the loopback host is no address a follower
/// could use. thisMacOnly always has a
/// real, bindable address (127.0.0.1) but a phone can never use it, which
/// is a different fact from "no address exists" and gets its own case so
/// the pane can explain it rather than silently omitting the QR code with
/// no reason given.
public enum ConnectPaneAddressState: Sendable, Equatable {
    case thisMacOnly
    case unavailable(reason: String)
    case ready(address: String)
    /// certificateStepNeeded is the local network route before the phone has
    /// been given CGM Relay's certificate: no address, token or code is
    /// offered until the person has done that step.
    case certificateStepNeeded

    /// decide is the pane's one pure mapping from network state to what it
    /// shows: boundHost is the host the running engine is actually bound to
    /// right now (nil while nothing is running); impliedBindHost is the
    /// host the current reach implies for the current interfaces
    /// (ReachAddressResolver.bindHost's own answer, computed once by the
    /// caller and never recomputed here); and displayHostAvailability is
    /// ReachAddressResolver.displayHostAvailability's own answer for the
    /// current interfaces. localHostName is this Mac's `.local` name, used
    /// in the local network address where there is one; certificateStepFinished
    /// is whether the person has finished the certificate step for the local
    /// network route, which holds back every address until they have. Nothing
    /// here reads live system state itself, so it is exercised with a plain
    /// table of inputs.
    public static func decide(
        reach: NetworkReach,
        boundHost: String?,
        impliedBindHost: String,
        port: Int,
        displayHostAvailability: ReachAddressAvailability,
        localHostName: String? = nil,
        certificateStepFinished: Bool = true
    ) -> ConnectPaneAddressState {
        switch reach {
        case .thisMacOnly:
            return .thisMacOnly
        case .myTailnet:
            guard let boundHost else {
                return .unavailable(reason: "The engine isn't running right now.")
            }
            guard boundHost == impliedBindHost else {
                return .unavailable(reason: "The network setting is being applied.")
            }
            guard ReachAddressResolver.isTailscaleAddress(boundHost) else {
                return .unavailable(reason: "Waiting for Tailscale to connect.")
            }
            return .ready(address: "http://\(boundHost):\(port)")
        case .myLocalNetwork:
            guard let boundHost else {
                return .unavailable(reason: "The engine isn't running right now.")
            }
            guard boundHost == impliedBindHost else {
                return .unavailable(reason: "The network setting is being applied.")
            }
            switch displayHostAvailability {
            case .available(let host):
                guard certificateStepFinished else { return .certificateStepNeeded }
                return .ready(address: "https://\(localHostName ?? host):\(port)")
            case .unavailable(let reason):
                return .unavailable(reason: reason)
            }
        }
    }
}

/// SetupCompletion decides whether setup may be marked finished: only when a
/// phone can reach this Mac. Closing setup without that never finishes it.
public enum SetupCompletion {
    public static func mayFinish(reachability: PhoneReachability) -> Bool {
        reachability.isReachable
    }
}

/// PhoneReachability is whether a phone can be given an address for this
/// Mac at all, by the choices made so far. Setup's reach step continues
/// only on `.reachable`, and the connect step is shown only then; a
/// `.blocked` reason is one plain sentence naming what is missing.
public enum PhoneReachability: Sendable, Equatable {
    case reachable
    case blocked(reason: String)

    public var isReachable: Bool { self == .reachable }

    /// decide is the one pure answer: Tailscale HTTPS reaches a phone only
    /// when the person chose it and Tailscale itself reports it serving
    /// (httpsServing); otherwise only My tailnet or My local network with an
    /// address right now do. This Mac only never does. httpsChosen is the
    /// saved Tailscale HTTPS choice, so a choice Tailscale no longer backs is
    /// blocked rather than treated as reachable, and a handler serving that
    /// the person did not choose does not count.
    public static func decide(
        reach: NetworkReach,
        httpsChosen: Bool,
        httpsServing: Bool,
        tailnetAvailable: Bool,
        localNetworkAvailable: Bool
    ) -> PhoneReachability {
        if httpsChosen {
            return httpsServing
                ? .reachable
                : .blocked(reason: "Tailscale HTTPS isn't serving right now. Connect Tailscale, or set up later.")
        }
        switch reach {
        case .thisMacOnly:
            return .blocked(reason: "Choose a way for your phone to reach this Mac to continue.")
        case .myTailnet:
            return tailnetAvailable
                ? .reachable
                : .blocked(reason: "This Mac has no Tailscale address right now. Connect Tailscale, or choose another way.")
        case .myLocalNetwork:
            return localNetworkAvailable
                ? .reachable
                : .blocked(reason: "This Mac has no network address right now. Connect to a network, or set up later.")
        }
    }
}

/// ReachAddressResolver computes the two addresses NetworkReach's choice
/// actually implies: the host the engine should bind to (bindHost), and
/// the host a follower app should be given (displayHost). The two differ
/// only for myLocalNetwork: the engine's plain listener stays on loopback
/// there, and the local network is served by TLS listeners on each private
/// address (EngineListenPlan), so a follower is given this Mac's private
/// LAN address instead.
public enum ReachAddressResolver {
    /// tailscaleRangeFirstOctet and tailscaleRangeSecondOctetMin/Max
    /// describe 100.64.0.0/10 (RFC 6598's carrier-grade NAT block), the
    /// fixed range every Tailscale node's own address falls inside,
    /// whatever its account or subnet split.
    private static let tailscaleRangeFirstOctet = 100
    private static let tailscaleRangeSecondOctetMin = 64
    private static let tailscaleRangeSecondOctetMax = 127

    /// isTailscaleAddress reports whether address is an IPv4 literal
    /// inside 100.64.0.0/10.
    static func isTailscaleAddress(_ address: String) -> Bool {
        let parts = address.split(separator: ".")
        guard parts.count == 4,
              let first = Int(parts[0]), let second = Int(parts[1])
        else {
            return false
        }
        return first == tailscaleRangeFirstOctet
            && second >= tailscaleRangeSecondOctetMin
            && second <= tailscaleRangeSecondOctetMax
    }

    /// tailscaleIPv4 returns the first address among interfaces that
    /// falls inside the Tailscale range, or nil if this Mac currently has
    /// none -- either because Tailscale is not installed, or because it
    /// is not currently connected.
    public static func tailscaleIPv4(among interfaces: [NetworkInterfaceAddress]) -> String? {
        interfaces.first { isTailscaleAddress($0.address) }?.address
    }

    /// virtualInterfaceNamePrefixes names every interface family that is
    /// never an ordinary Wi-Fi or Ethernet connection a phone on the same
    /// local network could reach: a VM bridge (bridge100, vmnet1), a VPN
    /// tunnel (utun, ipsec, ppp), AWDL/peer-to-peer Wi-Fi, and the handful
    /// of other virtual link types macOS creates for its own tethering,
    /// bonding, and 6to4 features.
    private static let virtualInterfaceNamePrefixes = [
        "bridge", "vmnet", "utun", "ipsec", "ppp", "awdl", "llw", "stf", "gif", "tun", "tap", "bond",
    ]

    /// isLinkLocalIPv4 reports whether address is inside 169.254.0.0/16,
    /// the self-assigned range an interface picks for itself when it
    /// finds no DHCP server at all: never a usable local-network address,
    /// whatever interface it appears on.
    private static func isLinkLocalIPv4(_ address: String) -> Bool {
        address.hasPrefix("169.254.")
    }

    /// isPhysicalLANCandidate reports whether address, seen on a given
    /// interface name, is the kind of ordinary Wi-Fi or Ethernet address a
    /// phone on the same local network could actually reach: never
    /// loopback, a Tailscale address (already offered by myTailnet), a
    /// self-assigned link-local address, or an address on a virtual
    /// interface.
    private static func isPhysicalLANCandidate(_ interface: NetworkInterfaceAddress) -> Bool {
        guard interface.address != "127.0.0.1",
              !isTailscaleAddress(interface.address),
              !isLinkLocalIPv4(interface.address)
        else {
            return false
        }
        return !virtualInterfaceNamePrefixes.contains { interface.name.hasPrefix($0) }
    }

    /// primaryLANIPv4 returns this Mac's own ordinary local-network
    /// address: the one on primaryInterfaceName (the interface actually
    /// carrying the default route) when that interface has a physical LAN
    /// candidate among interfaces, or otherwise the first physical LAN
    /// candidate found at all. nil means this Mac currently has none --
    /// no network connection, or only virtual and self-assigned addresses.
    /// primaryInterfaceName is a plain argument, never read from live
    /// system state here, so this stays testable with a synthetic list
    /// and no dependency on this Mac's actual routing table.
    public static func primaryLANIPv4(among interfaces: [NetworkInterfaceAddress], primaryInterfaceName: String? = nil) -> String? {
        let candidates = interfaces.filter(isPhysicalLANCandidate)
        if let primaryInterfaceName, let onPrimary = candidates.first(where: { $0.name == primaryInterfaceName }) {
            return onPrimary.address
        }
        return candidates.first?.address
    }

    /// bindHost is the host part of the engine's own listen_addr for
    /// reach: 127.0.0.1 for thisMacOnly and myLocalNetwork (the local
    /// network is served by the TLS listeners on each private address, see
    /// EngineListenPlan, and the plain listener never leaves this Mac); the
    /// discovered Tailscale address for myTailnet, so the engine is
    /// reachable only on the tailnet interface itself, never the plain local
    /// network -- falling back to 127.0.0.1, the most restrictive host, if
    /// this Mac currently has no tailnet address at all.
    public static func bindHost(for reach: NetworkReach, interfaces: [NetworkInterfaceAddress]) -> String {
        switch reach {
        case .thisMacOnly, .myLocalNetwork:
            return "127.0.0.1"
        case .myTailnet:
            return tailscaleIPv4(among: interfaces) ?? "127.0.0.1"
        }
    }

    /// portCheckHost is the host a follower port is tested on before the
    /// engine starts. The local network route listens on loopback and on each
    /// private address, so it is tested on every interface (0.0.0.0), which
    /// is also what a port held by another app on any of them would block.
    public static func portCheckHost(for reach: NetworkReach, interfaces: [NetworkInterfaceAddress]) -> String {
        switch reach {
        case .myLocalNetwork:
            return "0.0.0.0"
        case .thisMacOnly, .myTailnet:
            return bindHost(for: reach, interfaces: interfaces)
        }
    }

    /// isPrivateIPv4 reports whether address is a dotted-quad inside the
    /// 10, 172.16 and 192.168 ranges, the only addresses the local
    /// certificate can name.
    static func isPrivateIPv4(_ address: String) -> Bool {
        (try? LocalCertificateAuthority.normalizedAddresses([address])) != nil
    }

    /// privateLANIPv4s is every private IPv4 address this Mac has on an
    /// ordinary Wi-Fi or wired interface, without duplicates and in a fixed
    /// order: the addresses the local network route listens on and names in
    /// its certificate.
    public static func privateLANIPv4s(among interfaces: [NetworkInterfaceAddress]) -> [String] {
        Set(interfaces.filter(isPhysicalLANCandidate).map(\.address).filter(isPrivateIPv4)).sorted()
    }

    /// primaryPrivateLANIPv4 is the private address a phone is given when an
    /// app takes an address rather than a name: the one on the interface
    /// carrying the default route when it has one, otherwise the first.
    public static func primaryPrivateLANIPv4(among interfaces: [NetworkInterfaceAddress], primaryInterfaceName: String? = nil) -> String? {
        let candidates = interfaces.filter { isPhysicalLANCandidate($0) && isPrivateIPv4($0.address) }
        if let primaryInterfaceName, let onPrimary = candidates.first(where: { $0.name == primaryInterfaceName }) {
            return onPrimary.address
        }
        return candidates.first?.address
    }

    /// displayHost is the host the Connect pane shows and encodes into
    /// its QR code: the same as bindHost for thisMacOnly and myTailnet,
    /// since both bind to exactly the address a follower would use, but
    /// this Mac's own private LAN address for myLocalNetwork, since the
    /// engine's plain listener there is loopback only. Falls back
    /// to 127.0.0.1 when this Mac currently has no address of the kind
    /// the chosen reach needs -- the same safe default bindHost falls
    /// back to.
    public static func displayHost(for reach: NetworkReach, interfaces: [NetworkInterfaceAddress], primaryInterfaceName: String? = nil) -> String {
        switch reach {
        case .thisMacOnly:
            return "127.0.0.1"
        case .myTailnet:
            return tailscaleIPv4(among: interfaces) ?? "127.0.0.1"
        case .myLocalNetwork:
            return primaryPrivateLANIPv4(among: interfaces, primaryInterfaceName: primaryInterfaceName) ?? "127.0.0.1"
        }
    }

    /// displayHostAvailability is displayHost's own honest counterpart:
    /// the same address when this Mac currently has one, or a plain-
    /// language reason when it does not, so a caller never has to guess
    /// whether displayHost's 127.0.0.1 is the real answer or just its
    /// safe fallback.
    public static func displayHostAvailability(for reach: NetworkReach, interfaces: [NetworkInterfaceAddress], primaryInterfaceName: String? = nil) -> ReachAddressAvailability {
        switch reach {
        case .thisMacOnly:
            return .available("127.0.0.1")
        case .myTailnet:
            if let host = tailscaleIPv4(among: interfaces) {
                return .available(host)
            }
            return .unavailable(reason: "Waiting for Tailscale to connect.")
        case .myLocalNetwork:
            if let host = primaryPrivateLANIPv4(among: interfaces, primaryInterfaceName: primaryInterfaceName) {
                return .available(host)
            }
            return .unavailable(reason: "Waiting for a network connection.")
        }
    }
}

/// SystemNetworkInterfaces collects this Mac's real network addresses.
/// Kept to exactly that: every decision about what to do with the result
/// lives in ReachAddressResolver, which takes the list as a plain
/// argument and is tested with a synthetic one instead.
public enum SystemNetworkInterfaces {
    /// currentIPv4Addresses lists every active IPv4 address on this Mac's
    /// own network interfaces, the same information `ifconfig` reads.
    /// Loopback's own interface is skipped, since 127.0.0.1 is never a
    /// meaningful "which interface" answer and every caller already has
    /// its own explicit loopback fallback.
    public static func currentIPv4Addresses() -> [NetworkInterfaceAddress] {
        var result: [NetworkInterfaceAddress] = []

        var firstAddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddr) == 0, let first = firstAddr else { return [] }
        defer { freeifaddrs(firstAddr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }

            // ifa_flags is UInt32; masked against UInt32(IFF_UP) here
            // rather than converting the flags themselves to Int32,
            // which traps at runtime if a future or vendor-defined flag
            // ever sets bit 31.
            let flags = current.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            guard let addr = current.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard status == 0 else { continue }

            let name = String(cString: current.pointee.ifa_name)
            let address = hostBuffer.withUnsafeBufferPointer { buffer in
                String(cString: buffer.baseAddress!)
            }
            result.append(NetworkInterfaceAddress(name: name, address: address))
        }
        return result
    }

    /// primaryInterfaceName names the interface currently carrying this
    /// Mac's default IPv4 route -- the same "which connection is the real
    /// one right now" question System Settings' own Network pane answers
    /// -- read from SCDynamicStore's own State:/Network/Global/IPv4 key,
    /// never by spawning `route`/`netstat`. nil when this Mac currently
    /// has no default route at all (no network connection).
    #if canImport(SystemConfiguration)
    public static func primaryInterfaceName() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "com.yaanfpv.cgmrelay" as CFString, nil, nil) else {
            return nil
        }
        guard let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else {
            return nil
        }
        return global["PrimaryInterface"] as? String
    }
    #else
    public static func primaryInterfaceName() -> String? { nil }
    #endif

    /// localHostName is this Mac's `.local` name: its Bonjour name when the
    /// system has one, otherwise its host name, either made into a valid
    /// `.local` name by LocalHostName.mdnsName.
    public static func localHostName() -> String {
        #if canImport(SystemConfiguration)
        if let bonjour = SCDynamicStoreCopyLocalHostName(nil) as String?, let name = LocalHostName.mdnsName(from: bonjour) {
            return name
        }
        #endif
        return LocalHostName.mdnsName(from: ProcessInfo.processInfo.hostName) ?? LocalHostName.fallback
    }
}

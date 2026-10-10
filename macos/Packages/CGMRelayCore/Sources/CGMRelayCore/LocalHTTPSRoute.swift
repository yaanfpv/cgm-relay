import Foundation

/// LocalHostName turns the names the system reports for this Mac into the
/// one `.local` name the local certificate and the addresses shown to a
/// phone use.
public enum LocalHostName {
    /// fallback is used only when the system reports no name that can be made
    /// into a valid one.
    public static let fallback = "cgm-relay-mac.local"

    /// mdnsName returns the lowercase `<host>.local` name for raw, which may
    /// be a Bonjour name ("Alex's Mac"), a host name already ending in
    /// `.local` or a longer DNS name (only its first label is kept). Anything
    /// outside letters, digits and hyphens becomes a hyphen. nil when nothing
    /// usable is left.
    public static func mdnsName(from raw: String) -> String? {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let first = lowered.split(separator: ".").first else { return nil }
        var label = ""
        for character in first {
            if character.isASCII, character.isLetter || character.isNumber {
                label.append(character)
            } else if label.last != "-" {
                label.append("-")
            }
        }
        label = String(label.prefix(63)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return label.isEmpty ? nil : "\(label).local"
    }
}

/// EngineListenPlan is where the engine listens for a reach: the host of its
/// plain listener (listen_addr), and, on the local network route, the private
/// addresses it serves over TLS, with the `.local` name its certificate names.
public struct EngineListenPlan: Equatable, Sendable {
    /// host is the host of the plain listener: loopback, or this Mac's
    /// Tailscale address on the tailnet route.
    public let host: String
    /// lanAddresses are the private IPv4 addresses served over TLS, empty on
    /// every route but the local network and while this Mac has no private
    /// address.
    public let lanAddresses: [String]
    /// hostName is the `.local` name the certificate carries, set exactly
    /// when lanAddresses is not empty.
    public let hostName: String?

    public var servesLocalNetwork: Bool { !lanAddresses.isEmpty }

    /// identity names everything the running engine was started against, so
    /// a change in any part of it (an address joining or leaving, a new
    /// name) reads as a different identity and the engine restarts onto it.
    public var identity: String {
        guard let hostName, servesLocalNetwork else { return host }
        return "\(host)|\(hostName)|\(lanAddresses.joined(separator: ","))"
    }

    public static func make(reach: NetworkReach, interfaces: [NetworkInterfaceAddress], hostName: String) -> EngineListenPlan {
        let host = ReachAddressResolver.bindHost(for: reach, interfaces: interfaces)
        guard reach == .myLocalNetwork else {
            return EngineListenPlan(host: host, lanAddresses: [], hostName: nil)
        }
        let addresses = ReachAddressResolver.privateLANIPv4s(among: interfaces)
        return EngineListenPlan(host: host, lanAddresses: addresses, hostName: addresses.isEmpty ? nil : hostName)
    }
}

/// LocalFollowerRoute is how a follower app is given this Mac on the local
/// network: always https, by `.local` name where the app resolves one and by
/// private address where it does not.
public struct LocalFollowerRoute: Equatable, Sendable {
    public let hostName: String
    public let ipv4: String
    public let port: Int

    public init(hostName: String, ipv4: String, port: Int) {
        self.hostName = hostName
        self.ipv4 = ipv4
        self.port = port
    }

    public var nameAddress: String { "https://\(hostName):\(port)" }
    public var ipAddress: String { "https://\(ipv4):\(port)" }

    /// address is the address app is given. xDrip+ runs on Android, which
    /// does not reliably resolve a `.local` name, so it takes the private
    /// address; every iPhone app takes the name.
    public func address(for app: FollowerApp) -> String {
        switch app {
        case .xDripPlus: ipAddress
        case .xDrip4iOS, .loopFollow, .nightguard: nameAddress
        }
    }
}

extension AppSettings {
    /// needsCertificateStep is true on the local network route until the
    /// person has finished giving their phone the certificate: no token,
    /// code or address that carries one is shown meanwhile. On every other
    /// route it is false, whatever the saved flag says.
    public var needsCertificateStep: Bool {
        effectiveReach == .myLocalNetwork && !localCertificateStepFinished
    }

    /// authorityReplacedNotice is the sentence the menu shows after the
    /// certificate authority was replaced.
    public static let authorityReplacedNotice = "This Mac's name changed, so each phone needs the HTTPS step again."

    /// noteAuthorityChange records what happened to the certificate authority
    /// when the engine's certificate was last made: a new or replaced
    /// authority means phones trust nothing that works now, so the step is
    /// asked for again. It returns the sentence to show when an authority a
    /// phone had been given was replaced, nil otherwise.
    public mutating func noteAuthorityChange(_ change: LocalCertificateMaterial.AuthorityChange) -> String? {
        switch change {
        case .unchanged:
            return nil
        case .created:
            localCertificateStepFinished = false
            return nil
        case .replaced:
            let hadFinished = localCertificateStepFinished
            localCertificateStepFinished = false
            return hadFinished ? Self.authorityReplacedNotice : nil
        }
    }
}

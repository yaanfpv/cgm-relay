import Foundation

/// FollowerAppEntry splits the relay's address into what each follower app
/// asks for in its own fields.
public enum FollowerAppEntry {
    /// hostAndPort splits an address like `http://192.168.1.5:1337` into
    /// its scheme-and-host and its port, for an app with a URL field and a
    /// separate Port field. An address with no explicit port (the https
    /// tailnet address) has a nil port.
    public static func hostAndPort(of address: String) -> (host: String, port: String?) {
        guard
            let components = URLComponents(string: address),
            let scheme = components.scheme,
            let host = components.host
        else {
            return (address, nil)
        }
        return ("\(scheme)://\(host)", components.port.map(String.init))
    }

    /// urlWithToken puts the token in front of the address's host, as the
    /// single URL an app takes its credential from: `http://<token>@host:port`.
    public static func urlWithToken(address: String, token: String) -> String {
        guard let separator = address.range(of: "://") else { return address }
        return address.replacingCharacters(in: separator.upperBound..<separator.upperBound, with: "\(token)@")
    }

    /// tokenPlaceholder stands for the access token in a field's value. The
    /// Mac pane replaces it with the real token; the engine's pairing page
    /// does, so the token never travels in a mint request.
    public static let tokenPlaceholder = "{token}"

    /// Field is one value a follower app asks for, named as that app names it.
    public struct Field: Codable, Equatable, Sendable {
        public let label: String
        public let value: String
    }

    /// Link is a button on the pairing page (opening or getting the app).
    public struct Link: Codable, Equatable, Sendable {
        public let label: String
        public let url: String
    }

    /// Instructions is everything said about one app for one address: the
    /// steps and the values. It is the single source for the Mac pane and
    /// for the pairing page the engine serves to a phone, which renders
    /// exactly what the Mac sends.
    public struct Instructions: Codable, Equatable, Sendable {
        public let name: String
        public let steps: [String]
        public let fields: [Field]
        public let links: [Link]
    }

    /// instructions is what to do in app for the relay at address. A port is
    /// given only where the address names one.
    public static func instructions(for app: FollowerApp, address: String) -> Instructions {
        let entry = hostAndPort(of: address)
        let token = tokenPlaceholder
        switch app {
        case .xDrip4iOS:
            var fields = [Field(label: "URL", value: entry.host)]
            let portStep: String
            if let port = entry.port {
                fields.append(Field(label: "Port", value: port))
                portStep = "In URL, enter the address without its port, \(port) in Port, and the token in Token."
            } else {
                portStep = "In URL, enter the address, and the token in Token."
            }
            fields.append(Field(label: "Token", value: token))
            return Instructions(
                name: app.displayName,
                steps: [
                    "In Settings, set Master or Follower to Follower, and Data Source to Nightscout.",
                    "In Settings, open Sharing and Services, then Nightscout, and turn it on.",
                    portStep,
                    "Leave API_SECRET blank.",
                ],
                fields: fields,
                links: [Link(label: "Open xDrip4iOS", url: "xdripswift://open")]
            )
        case .xDripPlus:
            return Instructions(
                name: app.displayName,
                steps: [
                    "In Settings, set Hardware Data Source to Nightscout Follower.",
                    "In Nightscout Follow URL, enter the address with the token in front of it.",
                ],
                fields: [Field(label: "Nightscout Follow URL", value: urlWithToken(address: address, token: token))],
                links: []
            )
        case .loopFollow:
            return Instructions(
                name: app.displayName,
                steps: ["In Settings, open Nightscout, then enter the address in URL and the token in Token."],
                fields: [Field(label: "URL", value: address), Field(label: "Token", value: token)],
                links: []
            )
        case .nightguard:
            return Instructions(
                name: app.displayName,
                steps: ["When Nightguard first opens, enter the address in Nightscout URL and the token in API Token."],
                fields: [Field(label: "Nightscout URL", value: address), Field(label: "API Token", value: token)],
                links: [Link(label: "Get Nightguard on the App Store", url: "https://apps.apple.com/us/app/nightguard/id1116430352")]
            )
        }
    }

    /// pairingApps is every app's instructions, in the order the pane offers
    /// them: what the Mac sends to the engine for the pairing page.
    public static func pairingApps(address: String) -> [Instructions] {
        FollowerApp.allCases.map { instructions(for: $0, address: address) }
    }
}

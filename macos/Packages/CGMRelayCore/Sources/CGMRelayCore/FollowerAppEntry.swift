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
}

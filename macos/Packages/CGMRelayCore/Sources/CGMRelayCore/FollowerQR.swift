import Compression
import Foundation

/// FollowerQR is what the Connect pane's QR code encodes for one follower
/// app, and the sentence that says how to scan it.
public struct FollowerQR: Equatable, Sendable {
    /// payload is the exact string the QR code carries.
    public let payload: String
    /// carriesToken is whether the payload itself holds the access token,
    /// in which case it is scanned from inside the app rather than with the
    /// camera.
    public let carriesToken: Bool
    /// caption says which app scans it and where.
    public let caption: String
}

/// FollowerQRPlanner is the one place that decides what each follower app's
/// QR code holds: a settings-import code for an app that can import one,
/// otherwise a link to the relay's own pairing page (never the token).
public enum FollowerQRPlanner {
    /// pairingCodeLifetimeMinutes is how long a pairing code stays valid;
    /// it must match pairing.CodeLifetime in the engine.
    public static let pairingCodeLifetimeMinutes = 10

    /// caption says which app scans app's code and where. It is the same
    /// whether or not the code can be built yet, so a screen can hold room
    /// for the longest one and keep what follows it in one place.
    public static func caption(for app: FollowerApp) -> String {
        switch app {
        case .xDrip4iOS, .nightguard:
            return "Scan with the iPhone camera. It opens a page where you copy each value into \(app.displayName). The code lasts \(pairingCodeLifetimeMinutes) minutes."
        case .xDripPlus:
            return "In xDrip+, open Settings, then Auto Configure, and scan this code. It holds your token, so keep it private."
        case .loopFollow:
            return "In LoopFollow, open Settings, then Nightscout, then Import Settings from QR Code, and scan this code. It holds your token, so keep it private."
        }
    }

    /// qr returns app's QR code for the relay at address (an origin such as
    /// `https://host` or `http://192.168.1.5:10000`), or nil when it cannot
    /// be built yet: app needs a pairing code and none is given, or the
    /// token is empty.
    ///
    /// xDrip4iOS registers `xdripswift://` only to come to the front and to
    /// import backup files, and Nightguard has no settings import at all,
    /// so both open the pairing page. A future settings link would replace
    /// the `.xDrip4iOS` case here and nowhere else.
    public static func qr(
        for app: FollowerApp,
        address: String,
        token: String,
        pairingCode: String?,
        now: Date = Date()
    ) -> FollowerQR? {
        switch app {
        case .xDrip4iOS, .nightguard:
            guard let pairingCode else { return nil }
            return FollowerQR(
                payload: "\(address)/connect/\(pairingCode)",
                carriesToken: false,
                caption: caption(for: app)
            )
        case .xDripPlus:
            guard !token.isEmpty, let payload = XDripPlusSettingsQR.payload(followURL: FollowerAppEntry.urlWithToken(address: address, token: token)) else { return nil }
            return FollowerQR(
                payload: payload,
                carriesToken: true,
                caption: caption(for: app)
            )
        case .loopFollow:
            guard !token.isEmpty, let payload = LoopFollowSettingsQR.payload(url: address, token: token, now: now) else { return nil }
            return FollowerQR(
                payload: payload,
                carriesToken: true,
                caption: caption(for: app)
            )
        }
    }
}

/// XDripPlusSettingsQR builds the settings QR code xDrip+ reads with
/// Settings, then Auto Configure: the marker `xdpref:`, then the base64
/// (no padding) of a zlib stream holding a JSON object of preference names
/// to string values. Format taken from xDrip+'s QRcodeUtils.decodeString,
/// JoH.compressString and Preferences.installxDripPlusPreferencesFromQRCode
/// (NightscoutFoundation/xDrip at 9898cb8); the preference names and the
/// `NSFollower` value are from its pref_data_source.xml and
/// DexCollectionType.NSFollow.
public enum XDripPlusSettingsQR {
    public static let marker = "xdpref:"

    /// preferences is the whole object the code carries: the Nightscout
    /// Follower data source and its follow URL, nothing else.
    public static func preferences(followURL: String) -> [String: String] {
        ["dex_collection_method": "NSFollower", "nsfollow_url": followURL]
    }

    public static func payload(followURL: String) -> String? {
        guard
            let json = try? JSONSerialization.data(
                withJSONObject: preferences(followURL: followURL),
                options: [.sortedKeys, .withoutEscapingSlashes]
            ),
            let compressed = ZlibStream.compress(json)
        else { return nil }
        return marker + compressed.base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}

/// LoopFollowSettingsQR builds the Nightscout settings QR code LoopFollow
/// reads with Import Settings from QR Code: the JSON of its
/// CombinedSettingsExport holding a NightscoutSettingsExport with the URL
/// and token (loopandlearn/LoopFollow at 4a74b78,
/// Settings/ImportExport/ExportableSettings.swift). Its `timestamp` is a
/// Swift Date, which JSONEncoder writes as seconds since 2001-01-01.
public enum LoopFollowSettingsQR {
    struct Nightscout: Encodable {
        let version = "1.0"
        let url: String
        let token: String
    }

    struct Combined: Encodable {
        let version = "1.0"
        let appVersion = "1.0"
        let nightscout: Nightscout
        let exportType = "Nightscout Settings"
        let timestamp: Double
    }

    public static func payload(url: String, token: String, now: Date) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let combined = Combined(nightscout: Nightscout(url: url, token: token), timestamp: now.timeIntervalSinceReferenceDate)
        guard let data = try? encoder.encode(combined) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// ZlibStream wraps and unwraps the zlib container (RFC 1950) around the
/// raw deflate data Apple's Compression framework produces, since the
/// framework's ZLIB algorithm reads and writes the raw form only and Java's
/// Inflater, which xDrip+ uses, expects the container.
enum ZlibStream {
    /// header is a zlib header for a 32 KiB window at the default level.
    private static let header: [UInt8] = [0x78, 0x9C]

    static func compress(_ input: Data) -> Data? {
        let capacity = input.count + input.count / 8 + 64
        var output = [UInt8](repeating: 0, count: capacity)
        let written = input.withUnsafeBytes { source -> Int in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(&output, capacity, base, input.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }
        var stream = Data(header)
        stream.append(contentsOf: output[0..<written])
        let sum = adler32(input)
        stream.append(contentsOf: [UInt8(sum >> 24), UInt8((sum >> 16) & 0xFF), UInt8((sum >> 8) & 0xFF), UInt8(sum & 0xFF)])
        return stream
    }

    /// decompress reads a zlib stream, or returns nil when its header,
    /// deflate data or checksum is wrong.
    static func decompress(_ stream: Data, maxSize: Int = 10_000) -> Data? {
        let bytes = [UInt8](stream)
        guard bytes.count > 6, bytes[0] & 0x0F == 8, (Int(bytes[0]) << 8 | Int(bytes[1])) % 31 == 0 else { return nil }
        let deflated = Array(bytes[2..<(bytes.count - 4)])
        var output = [UInt8](repeating: 0, count: maxSize)
        let count = compression_decode_buffer(&output, maxSize, deflated, deflated.count, nil, COMPRESSION_ZLIB)
        guard count > 0 else { return nil }
        let result = Data(output[0..<count])
        let tail = bytes.suffix(4)
        let expected = tail.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return adler32(result) == expected ? result : nil
    }

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return b << 16 | a
    }
}

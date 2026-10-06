import Foundation

/// SafetyNoticeAcceptance records that a person accepted the safety notice:
/// which wording they accepted and the app version they accepted it in.
public struct SafetyNoticeAcceptance: Codable, Equatable, Sendable {
    public var noticeVersion: String
    public var appVersion: String

    public init(noticeVersion: String, appVersion: String) {
        self.noticeVersion = noticeVersion
        self.appVersion = appVersion
    }
}

/// SafetyNotice is the plain statement of what CGM Relay is not, shown once
/// in setup and always in Settings > About. Its version is derived from its
/// wording, so changing a word asks everyone again and leaving it alone never
/// does.
public enum SafetyNotice {
    public static let text = """
    CGM Relay is not a medical device. Readings and alerts can arrive late, go missing or be wrong. \
    Don't make treatment decisions from it, and keep the official Libre app and its alarms on for lows. \
    It isn't made by or affiliated with Abbott, and it comes with no warranty.
    """

    /// alertsCaveat is the one line the Alerts pane carries under its toggles.
    public static let alertsCaveat = "Alerts can be late or missed. They don't replace the official Libre app's alarms."

    /// version identifies the wording: an FNV-1a hash of the text, stable
    /// across launches and builds.
    public static let version: String = {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }()

    /// needsAcceptance is true until the current wording has been accepted.
    public static func needsAcceptance(_ acceptance: SafetyNoticeAcceptance?) -> Bool {
        acceptance?.noticeVersion != version
    }

    public static func acceptance(appVersion: String) -> SafetyNoticeAcceptance {
        SafetyNoticeAcceptance(noticeVersion: version, appVersion: appVersion)
    }
}

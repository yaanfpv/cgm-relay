import Foundation

/// GlucoseUnit is how the menu's reading is displayed. It never changes
/// what the engine stores or serves -- every follower app and the saved
/// database stay in mg/dL regardless -- only how this Mac's own menu
/// renders one.
public enum GlucoseUnit: String, Codable, Sendable, CaseIterable {
    case mgDl
    case mmolL

    /// mgDlPerMmolL is the conversion factor LibreLinkUp's own tooling
    /// uses (18.0182), not the simplified 18.0 many consumer apps round
    /// to, since a discrepancy here would read as a wrong reading rather
    /// than a rounding choice.
    public static let mgDlPerMmolL = 18.0182

    /// formatValue renders mgDl as just the numeral this unit shows, with
    /// no unit suffix: the value half of what format(mgDl:) joins
    /// together, and what MenuDisplayState's own readingValue field
    /// reuses so the hero's large numeral and the combined "value unit"
    /// string can never disagree.
    public func formatValue(mgDl: Int) -> String {
        switch self {
        case .mgDl:
            return "\(mgDl)"
        case .mmolL:
            let value = Double(mgDl) / Self.mgDlPerMmolL
            return String(format: "%.1f", value)
        }
    }

    /// label is this unit's own suffix, exactly as format(mgDl:) renders
    /// it after the value.
    public var label: String {
        switch self {
        case .mgDl: return "mg/dL"
        case .mmolL: return "mmol/L"
        }
    }

    /// format renders mgDl in this unit, to one decimal place in mmol/L.
    public func format(mgDl: Int) -> String {
        "\(formatValue(mgDl: mgDl)) \(label)"
    }
}

/// AppSettings is every non-secret setting the Settings window's General,
/// Advanced, and Alerts panes expose. It carries no LibreLinkUp account,
/// token, or store key -- those stay in CredentialStore -- so this whole
/// type is safe to keep in UserDefaults in plain JSON.
public struct AppSettings: Equatable, Sendable {
    public var port: Int
    public var reach: NetworkReach
    public var retentionDays: Int
    public var units: GlucoseUnit
    public var noReadingAlertEnabled: Bool
    public var noReadingAlertMinutes: Int
    public var signInFailingAlertEnabled: Bool

    public static let defaultPort = 1337
    public static let portRange = 1024...65535
    public static let defaultRetentionDays = 15
    public static let retentionDaysRange = 1...90
    public static let defaultNoReadingAlertMinutes = 20
    public static let noReadingAlertMinutesRange = 5...120

    public static let `default` = AppSettings(
        port: defaultPort,
        reach: .thisMacOnly,
        retentionDays: defaultRetentionDays,
        units: .mgDl,
        noReadingAlertEnabled: false,
        noReadingAlertMinutes: defaultNoReadingAlertMinutes,
        signInFailingAlertEnabled: false
    )

    public init(
        port: Int,
        reach: NetworkReach,
        retentionDays: Int,
        units: GlucoseUnit,
        noReadingAlertEnabled: Bool,
        noReadingAlertMinutes: Int,
        signInFailingAlertEnabled: Bool
    ) {
        self.port = port
        self.reach = reach
        self.retentionDays = retentionDays
        self.units = units
        self.noReadingAlertEnabled = noReadingAlertEnabled
        self.noReadingAlertMinutes = noReadingAlertMinutes
        self.signInFailingAlertEnabled = signInFailingAlertEnabled
    }
}

/// AppSettings' own Codable conformance decodes each field with
/// decodeIfPresent, falling back to that field's own default rather than
/// letting the whole struct's synthesized init(from:) throw and reset
/// every other field along with it: a later version adding one new field
/// must never wipe every existing person's port, reach, retention, and
/// alert settings on upgrade just because that one field was not in the
/// JSON they already had saved.
extension AppSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case port, reach, retentionDays, units, noReadingAlertEnabled, noReadingAlertMinutes, signInFailingAlertEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppSettings.default
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? fallback.port
        reach = try container.decodeIfPresent(NetworkReach.self, forKey: .reach) ?? fallback.reach
        retentionDays = try container.decodeIfPresent(Int.self, forKey: .retentionDays) ?? fallback.retentionDays
        units = try container.decodeIfPresent(GlucoseUnit.self, forKey: .units) ?? fallback.units
        noReadingAlertEnabled = try container.decodeIfPresent(Bool.self, forKey: .noReadingAlertEnabled) ?? fallback.noReadingAlertEnabled
        noReadingAlertMinutes = try container.decodeIfPresent(Int.self, forKey: .noReadingAlertMinutes) ?? fallback.noReadingAlertMinutes
        signInFailingAlertEnabled = try container.decodeIfPresent(Bool.self, forKey: .signInFailingAlertEnabled) ?? fallback.signInFailingAlertEnabled
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(port, forKey: .port)
        try container.encode(reach, forKey: .reach)
        try container.encode(retentionDays, forKey: .retentionDays)
        try container.encode(units, forKey: .units)
        try container.encode(noReadingAlertEnabled, forKey: .noReadingAlertEnabled)
        try container.encode(noReadingAlertMinutes, forKey: .noReadingAlertMinutes)
        try container.encode(signInFailingAlertEnabled, forKey: .signInFailingAlertEnabled)
    }
}

/// SettingsStoring reads and writes AppSettings. Production code uses
/// UserDefaultsSettingsStore; tests use a fake that never touches
/// UserDefaults at all.
public protocol SettingsStoring: Sendable {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}

/// UserDefaultsSettingsStore keeps AppSettings as one JSON-encoded value
/// under one key, the same one-item shape KeychainCredentialStore uses for
/// its own secrets.
public final class UserDefaultsSettingsStore: SettingsStoring, @unchecked Sendable {
    private static let key = "com.yaanfpv.cgmrelay.settings"

    private let defaults: UserDefaults

    /// init points at .standard, this Mac's one real settings domain,
    /// when suiteName is nil, or a suite scoped to it otherwise: passing
    /// the Debug build's own throwaway Keychain service override here
    /// too means a development walk driven against a throwaway account
    /// never changes the owner's real settings either.
    public init(suiteName: String? = nil) {
        if let suiteName, let suite = UserDefaults(suiteName: suiteName) {
            defaults = suite
        } else {
            defaults = .standard
        }
    }

    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return .default
        }
        return decoded
    }

    public func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// PortCommitValidation is the Advanced pane's own decision for a
/// person's typed port entry, once they commit it (Return or focus
/// loss): a whole number inside AppSettings.portRange commits; anything
/// else is refused with a message the pane shows inline, rather than
/// silently saved or clamped into range.
public enum PortCommitValidation: Sendable, Equatable {
    case valid(Int)
    case invalid(message: String)

    public static func validate(_ text: String) -> PortCommitValidation {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let value = Int(trimmed) else {
            return .invalid(message: "Enter a whole number from \(AppSettings.portRange.lowerBound) to \(AppSettings.portRange.upperBound).")
        }
        guard AppSettings.portRange.contains(value) else {
            return .invalid(message: "Port must be between \(AppSettings.portRange.lowerBound) and \(AppSettings.portRange.upperBound).")
        }
        return .valid(value)
    }
}

/// RetentionCommitValidation is the General pane's own decision for a
/// person's typed retention entry, once they commit it: the numeric half
/// of the same contract PortCommitValidation gives the port field, over
/// AppSettings.retentionDaysRange instead.
public enum RetentionCommitValidation: Sendable, Equatable {
    case valid(Int)
    case invalid(message: String)

    public static func validate(_ text: String) -> RetentionCommitValidation {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let value = Int(trimmed) else {
            return .invalid(message: "Enter a whole number of days from \(AppSettings.retentionDaysRange.lowerBound) to \(AppSettings.retentionDaysRange.upperBound).")
        }
        guard AppSettings.retentionDaysRange.contains(value) else {
            return .invalid(message: "Days must be between \(AppSettings.retentionDaysRange.lowerBound) and \(AppSettings.retentionDaysRange.upperBound).")
        }
        return .valid(value)
    }
}

/// RetentionCommitDecision is the General pane's own decision for a
/// newly committed retention value, once it is already known valid:
/// lowering it deletes readings older than the new value at the engine's
/// next prune, so the pane confirms first; raising it or leaving it
/// unchanged deletes nothing and needs no confirmation.
public enum RetentionCommitDecision: Sendable, Equatable {
    case needsConfirmation
    case commitsImmediately

    public static func decide(current: Int, new: Int) -> RetentionCommitDecision {
        new < current ? .needsConfirmation : .commitsImmediately
    }
}

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
    /// tailscaleHTTPSEnabled is the person's choice to reach the relay over
    /// Tailscale HTTPS, and consent for the relay to stay bound to this Mac
    /// only. It is a choice, never evidence: whether HTTPS is actually on
    /// is whatever Tailscale itself reports serving.
    public var tailscaleHTTPSEnabled: Bool
    /// setupFinished is whether the person reached Done in first-launch
    /// setup. Setup is complete only together with a signed-in account.
    public var setupFinished: Bool
    /// showReadingInMenuBar puts the latest reading and its trend arrow
    /// beside the menu bar mark. Off by default: the mark alone says all is
    /// well.
    public var showReadingInMenuBar: Bool
    /// connectFollowerApp is the follower app last chosen in the Connect
    /// pane, so its QR code is the one shown the next time.
    public var connectFollowerApp: FollowerApp
    /// safetyNoticeAcceptance is the safety notice wording the person last
    /// accepted, nil until they have; see SafetyNotice.needsAcceptance.
    public var safetyNoticeAcceptance: SafetyNoticeAcceptance?

    /// effectiveReach is the reach the relay is actually bound to: this
    /// Mac only whenever the person chose Tailscale HTTPS, whatever reach
    /// was chosen before it, and the chosen reach otherwise. Following the
    /// choice rather than Tailscale's live state is the safe direction: the
    /// relay never widens while Tailscale is down or being re-read.
    public var effectiveReach: NetworkReach {
        tailscaleHTTPSEnabled ? .thisMacOnly : reach
    }

    public static let defaultPort = RelayDefaults.followerPort
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
        signInFailingAlertEnabled: false,
        tailscaleHTTPSEnabled: false,
        setupFinished: false,
        showReadingInMenuBar: false,
        connectFollowerApp: .xDrip4iOS,
        safetyNoticeAcceptance: nil
    )

    public init(
        port: Int,
        reach: NetworkReach,
        retentionDays: Int,
        units: GlucoseUnit,
        noReadingAlertEnabled: Bool,
        noReadingAlertMinutes: Int,
        signInFailingAlertEnabled: Bool,
        tailscaleHTTPSEnabled: Bool = false,
        setupFinished: Bool = false,
        showReadingInMenuBar: Bool = false,
        connectFollowerApp: FollowerApp = .xDrip4iOS,
        safetyNoticeAcceptance: SafetyNoticeAcceptance? = nil
    ) {
        self.port = port
        self.reach = reach
        self.retentionDays = retentionDays
        self.units = units
        self.noReadingAlertEnabled = noReadingAlertEnabled
        self.noReadingAlertMinutes = noReadingAlertMinutes
        self.signInFailingAlertEnabled = signInFailingAlertEnabled
        self.tailscaleHTTPSEnabled = tailscaleHTTPSEnabled
        self.setupFinished = setupFinished
        self.showReadingInMenuBar = showReadingInMenuBar
        self.connectFollowerApp = connectFollowerApp
        self.safetyNoticeAcceptance = safetyNoticeAcceptance
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
        case tailscaleHTTPSEnabled, setupFinished, showReadingInMenuBar, connectFollowerApp, safetyNoticeAcceptance
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
        tailscaleHTTPSEnabled = try container.decodeIfPresent(Bool.self, forKey: .tailscaleHTTPSEnabled) ?? fallback.tailscaleHTTPSEnabled
        setupFinished = try container.decodeIfPresent(Bool.self, forKey: .setupFinished) ?? fallback.setupFinished
        showReadingInMenuBar = try container.decodeIfPresent(Bool.self, forKey: .showReadingInMenuBar) ?? fallback.showReadingInMenuBar
        // A value this version does not know (a newer version's app) falls
        // back to the default rather than failing the whole decode.
        connectFollowerApp = ((try? container.decodeIfPresent(FollowerApp.self, forKey: .connectFollowerApp)) ?? nil) ?? fallback.connectFollowerApp
        safetyNoticeAcceptance = ((try? container.decodeIfPresent(SafetyNoticeAcceptance.self, forKey: .safetyNoticeAcceptance)) ?? nil)
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
        try container.encode(tailscaleHTTPSEnabled, forKey: .tailscaleHTTPSEnabled)
        try container.encode(setupFinished, forKey: .setupFinished)
        try container.encode(showReadingInMenuBar, forKey: .showReadingInMenuBar)
        try container.encode(connectFollowerApp, forKey: .connectFollowerApp)
        try container.encodeIfPresent(safetyNoticeAcceptance, forKey: .safetyNoticeAcceptance)
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

/// RetentionLeaveDecision is what happens to a retention entry the person
/// has typed or clicked but not yet committed when the General pane goes
/// away: a raise is saved as Return would have saved it, an unchanged value
/// leaves nothing behind, and anything that cannot be saved silently is
/// held with the message the pane shows when it next appears. A lowering is
/// never applied from a pane that is leaving, since it deletes readings and
/// needs the person's confirmation.
public enum RetentionLeaveDecision: Sendable, Equatable {
    case nothing
    case save(Int)
    case held(message: String)

    public static func decide(current: Int, text: String) -> RetentionLeaveDecision {
        switch RetentionCommitValidation.validate(text) {
        case .invalid(let message):
            return .held(message: "Not saved. \(message)")
        case .valid(let value):
            guard value != current else { return .nothing }
            switch RetentionCommitDecision.decide(current: current, new: value) {
            case .commitsImmediately:
                return .save(value)
            case .needsConfirmation:
                return .held(message: "\(value) days was not saved. Lowering deletes older readings and needs confirming, so enter it again.")
            }
        }
    }
}

/// RelayDefaults are the follower port and status address a build uses
/// until a port is saved. A Debug build takes its own pair so a development
/// run never contends with an installed copy for a listener; Release keeps
/// the engine's own defaults.
public enum RelayDefaults {
    #if DEBUG
    public static let followerPort = 1347
    public static let statusAddr = "127.0.0.1:1348"
    #else
    public static let followerPort = 1337
    public static let statusAddr = "127.0.0.1:1338"
    #endif
}

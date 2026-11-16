import Foundation

/// SleepAuthority is the four things that can change how the Mac sleeps:
/// the permission that lets the app change the sleep setting, the writer of
/// that setting, the idle sleep assertion, and the helper that lets the Mac
/// sleep again when the app is not running.
public struct SleepAuthority {
    public let rules: any SleepRuleManaging
    public let setting: any SleepSettingWriting
    public let assertion: any IdleSleepAsserting
    public let helperRegistration: any SleepHelperRegistering
}

/// SleepAuthorityLocator decides which sleep authority a launch gets. It
/// takes the Keychain service decision the launch actually resolved to, not
/// the raw launch argument, so every run backed by throwaway data is inert:
/// a plain debug launch with no argument resolves to a throwaway service
/// just as an explicit one does, and neither may run sudo, install anything
/// hold a real power assertion or register a helper. Only the real service gets the real
/// authority.
public enum SleepAuthorityLocator {
    public static func resolve(service: SyntheticAccountSeeder.KeychainServiceDecision) -> SleepAuthority {
        guard case .useRealService = service else {
            return SleepAuthority(
                rules: UnavailableSleepRules(),
                setting: IgnoredSleepSetting(),
                assertion: IgnoredIdleSleepAssertion(),
                helperRegistration: InertSleepHelper()
            )
        }
        return SleepAuthority(
            rules: SleepRuleAdministrator(),
            setting: PrivilegedSleepSettingWriter(),
            assertion: SystemIdleSleepAssertion(),
            helperRegistration: SMAppServiceSleepHelper()
        )
    }
}

/// IgnoredSleepSetting accepts every change and makes none.
public struct IgnoredSleepSetting: SleepSettingWriting {
    public init() {}
    public func setDisableSleep(_ on: Bool) throws {}
}

/// IgnoredIdleSleepAssertion holds nothing.
public struct IgnoredIdleSleepAssertion: IdleSleepAsserting {
    public init() {}
    public func hold() throws {}
    public func release() {}
}

/// UnavailableSleepRules is the sleep permission in a run on throwaway
/// data: nothing is installed, and asking to install fails.
public struct UnavailableSleepRules: SleepRuleManaging {
    public init() {}
    public func isInstalled() async -> Bool { false }
    public func install() async -> SleepRuleOutcome { .failed }
    public func remove() async -> SleepRuleOutcome { .done }
}

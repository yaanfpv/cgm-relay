import Foundation

/// SleepAuthority is the three things that can change how the Mac sleeps:
/// the permission that lets the app change the sleep setting, the writer of
/// that setting, and the idle sleep assertion.
public struct SleepAuthority {
    public let rules: any SleepRuleManaging
    public let setting: any SleepSettingWriting
    public let assertion: any IdleSleepAsserting
}

/// SleepAuthorityLocator decides which sleep authority a launch gets. It
/// takes the Keychain service decision the launch actually resolved to, not
/// the raw launch argument, so every run backed by throwaway data is inert:
/// a plain debug launch with no argument resolves to a throwaway service
/// just as an explicit one does, and neither may run sudo, install anything
/// or hold a real power assertion. Only the real service gets the real
/// authority.
public enum SleepAuthorityLocator {
    public static func resolve(service: SyntheticAccountSeeder.KeychainServiceDecision) -> SleepAuthority {
        guard case .useRealService = service else {
            return SleepAuthority(
                rules: UnavailableSleepRules(),
                setting: IgnoredSleepSetting(),
                assertion: IgnoredIdleSleepAssertion()
            )
        }
        return SleepAuthority(
            rules: SleepRuleAdministrator(),
            setting: PrivilegedSleepSettingWriter(),
            assertion: SystemIdleSleepAssertion()
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

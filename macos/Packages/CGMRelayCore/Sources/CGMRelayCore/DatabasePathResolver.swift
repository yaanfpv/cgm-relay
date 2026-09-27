import Foundation

/// DatabasePathResolver computes where the reading database lives under a
/// given base directory (this app's own Application Support/CGM Relay
/// directory, in production): the real `readings.db` path when no Keychain
/// service override is given, or a path scoped to that override's own name
/// when one is -- so a debug run pointed at a throwaway Keychain service
/// can never touch the real database, and two throwaway services never
/// collide with each other or with a database sealed by an earlier one's
/// generated key.
public enum DatabasePathResolver {
    /// resolve returns baseDirectory/readings.db when keychainServiceOverride
    /// is nil or empty, and baseDirectory/Development/<service>/readings.db
    /// otherwise. It does not judge whether an override is genuinely
    /// throwaway, or safe to use as a single path component -- the caller
    /// (CGMRelayApp's own launch-argument handling, via
    /// SyntheticAccountSeeder.isThrowawayService) has already refused to
    /// start at all if it is not both, so by the time a non-nil override
    /// reaches here it is always a single plain name: never ".", "..", or
    /// anything containing "/", so the path built from it can never
    /// resolve outside Development/ or onto another service's own folder.
    public static func resolve(baseDirectory: URL, keychainServiceOverride: String?) -> URL {
        guard let service = keychainServiceOverride, !service.isEmpty else {
            return baseDirectory.appendingPathComponent("readings.db")
        }
        return baseDirectory
            .appendingPathComponent("Development", isDirectory: true)
            .appendingPathComponent(service, isDirectory: true)
            .appendingPathComponent("readings.db")
    }
}

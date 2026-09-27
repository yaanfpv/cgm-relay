import Testing
import Foundation
@testable import CGMRelayCore

@Suite("DatabasePathResolver")
struct DatabasePathResolverTests {
    static let base = URL(fileURLWithPath: "/tmp/cgm-relay-tests/CGM Relay", isDirectory: true)

    @Test("no override resolves to the real readings.db, directly under the base directory")
    func noOverrideUsesRealPath() {
        let resolved = DatabasePathResolver.resolve(baseDirectory: Self.base, keychainServiceOverride: nil)
        #expect(resolved == Self.base.appendingPathComponent("readings.db"))
    }

    @Test("an empty override is treated the same as no override")
    func emptyOverrideUsesRealPath() {
        let resolved = DatabasePathResolver.resolve(baseDirectory: Self.base, keychainServiceOverride: "")
        #expect(resolved == Self.base.appendingPathComponent("readings.db"))
    }

    @Test("a throwaway service name resolves under Development/<service>, never the real path")
    func throwawayServiceUsesScopedPath() {
        let resolved = DatabasePathResolver.resolve(baseDirectory: Self.base, keychainServiceOverride: "com.yaanfpv.cgmrelay.dev.walkthrough")
        let want = Self.base
            .appendingPathComponent("Development", isDirectory: true)
            .appendingPathComponent("com.yaanfpv.cgmrelay.dev.walkthrough", isDirectory: true)
            .appendingPathComponent("readings.db")
        #expect(resolved == want)
        #expect(resolved != Self.base.appendingPathComponent("readings.db"), "a throwaway run must never resolve to the real database")
    }

    @Test("two distinct throwaway services resolve to two distinct paths")
    func distinctServicesNeverCollide() {
        let first = DatabasePathResolver.resolve(baseDirectory: Self.base, keychainServiceOverride: "com.yaanfpv.cgmrelay.dev.one")
        let second = DatabasePathResolver.resolve(baseDirectory: Self.base, keychainServiceOverride: "com.yaanfpv.cgmrelay.dev.two")
        #expect(first != second)
    }
}

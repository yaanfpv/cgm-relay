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

@Suite("SingleInstance")
struct SingleInstanceTests {
    @Test("the lowest process id proceeds and every other copy yields to it")
    func decisions() {
        #expect(SingleInstance.decide(ownPID: 10, runningPIDs: []) == .proceed)
        #expect(SingleInstance.decide(ownPID: 10, runningPIDs: [10]) == .proceed)
        #expect(SingleInstance.decide(ownPID: 10, runningPIDs: [10, 20, 30]) == .proceed)
        #expect(SingleInstance.decide(ownPID: 10, runningPIDs: [10, 7]) == .yield(to: 7))
        #expect(SingleInstance.decide(ownPID: 20, runningPIDs: [30, 20, 10, 15]) == .yield(to: 10))
    }

    @Test("two copies launched together see the same set and exactly one proceeds")
    func simultaneousLaunch() {
        let both: [Int32] = [100, 200]
        let low = SingleInstance.decide(ownPID: 100, runningPIDs: both)
        let high = SingleInstance.decide(ownPID: 200, runningPIDs: both)
        #expect(low == .proceed)
        #expect(high == .yield(to: 100))
    }
}

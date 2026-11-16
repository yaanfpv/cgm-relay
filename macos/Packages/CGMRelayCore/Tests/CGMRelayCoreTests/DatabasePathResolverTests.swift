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

    @Test("two copies given the same set of running pids agree on which one proceeds")
    func simultaneousLaunch() {
        let both: [Int32] = [100, 200]
        let low = SingleInstance.decide(ownPID: 100, runningPIDs: both)
        let high = SingleInstance.decide(ownPID: 200, runningPIDs: both)
        #expect(low == .proceed)
        #expect(high == .yield(to: 100))
    }

    // StateDirectoryPolicy has no test file of its own; the folder it prepares
    // is the one the engine keeps beside the database.
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("state-dir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func excluded(_ url: URL) throws -> Bool? {
        try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
    }

    private func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test("the Tailscale state folder is created private and excluded from Time Machine every time it is created")
    func stateDirectoryIsCreatedExcludedFromBackup() throws {
        let parent = try scratch()
        defer { try? FileManager.default.removeItem(at: parent) }
        let dir = parent.appendingPathComponent("tailscale", isDirectory: true)

        try StateDirectoryPolicy.prepare(at: dir)
        #expect(try excluded(dir) == true)
        #expect(try mode(dir) == 0o700)

        // Leaving the route deletes the folder; choosing it again creates a new one.
        try FileManager.default.removeItem(at: dir)
        try StateDirectoryPolicy.prepare(at: dir)
        #expect(try excluded(dir) == true, "a folder created again must be excluded again")
        #expect(try mode(dir) == 0o700)
    }

    @Test("a state folder that already exists without the exclusion or with loose permissions is fixed, not trusted")
    func existingStateDirectoryIsTightenedAndExcluded() throws {
        let parent = try scratch()
        defer { try? FileManager.default.removeItem(at: parent) }
        let dir = parent.appendingPathComponent("tailscale", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let key = dir.appendingPathComponent("tailscaled.state")
        try Data("node-key".utf8).write(to: key)
        #expect(try excluded(dir) != true, "the check cannot tell: the fresh folder was already excluded")

        try StateDirectoryPolicy.prepare(at: dir)
        #expect(try excluded(dir) == true)
        #expect(try mode(dir) == 0o700)
        #expect(try Data(contentsOf: key) == Data("node-key".utf8), "preparing must keep what the folder holds")
    }

    @Test("a path that is a file is an error, never a silent success")
    func stateDirectoryOverAFileThrows() throws {
        let parent = try scratch()
        defer { try? FileManager.default.removeItem(at: parent) }
        let file = parent.appendingPathComponent("tailscale")
        try Data("not a folder".utf8).write(to: file)
        #expect(throws: (any Error).self) { try StateDirectoryPolicy.prepare(at: file) }
    }
}

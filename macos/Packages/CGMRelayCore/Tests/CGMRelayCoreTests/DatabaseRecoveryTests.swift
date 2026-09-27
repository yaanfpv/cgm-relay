import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#endif
@testable import CGMRelayCore

@Suite("DatabaseRecovery")
struct DatabaseRecoveryTests {
    static let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("movedAsidePath keeps the directory and extension, marking the base name as unreadable with a timestamp")
    func movedAsidePathShape() {
        let got = DatabaseRecovery.movedAsidePath(for: "/tmp/CGM Relay/readings.db", now: Self.fixedNow)
        #expect(got == "/tmp/CGM Relay/readings (unreadable, 20270115-080000).db")
    }

    @Test("moveAside renames an existing file to movedAsidePath, leaving the original path empty")
    func moveAsideRenamesExistingFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = dir.appendingPathComponent("readings.db").path
        try "not a real database".write(toFile: original, atomically: true, encoding: .utf8)

        try DatabaseRecovery.moveAside(databasePath: original, now: Self.fixedNow)

        #expect(!FileManager.default.fileExists(atPath: original), "the original path must be empty after moving aside")
        let destination = DatabaseRecovery.movedAsidePath(for: original, now: Self.fixedNow)
        #expect(FileManager.default.fileExists(atPath: destination), "the moved file must exist at its new name")
        let contents = try String(contentsOfFile: destination, encoding: .utf8)
        #expect(contents == "not a real database", "moveAside must rename the file, never delete or recreate it")
    }

    @Test("moveAside also moves -wal and -shm sidecars when present, to the same new base name")
    func moveAsideMovesSidecarsWhenPresent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = dir.appendingPathComponent("readings.db").path
        try "not a real database".write(toFile: original, atomically: true, encoding: .utf8)
        try "wal contents".write(toFile: original + "-wal", atomically: true, encoding: .utf8)
        try "shm contents".write(toFile: original + "-shm", atomically: true, encoding: .utf8)

        try DatabaseRecovery.moveAside(databasePath: original, now: Self.fixedNow)

        let destination = DatabaseRecovery.movedAsidePath(for: original, now: Self.fixedNow)
        #expect(!FileManager.default.fileExists(atPath: original))
        #expect(!FileManager.default.fileExists(atPath: original + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: original + "-shm"))
        #expect(FileManager.default.fileExists(atPath: destination + "-wal"), "the -wal sidecar must move to the same new base name")
        #expect(FileManager.default.fileExists(atPath: destination + "-shm"), "the -shm sidecar must move to the same new base name")
        #expect(try String(contentsOfFile: destination + "-wal", encoding: .utf8) == "wal contents")
        #expect(try String(contentsOfFile: destination + "-shm", encoding: .utf8) == "shm contents")
    }

    @Test("moveAside with no sidecars present moves only the main file, and creates no sidecar at the destination")
    func moveAsideWithNoSidecarsMovesOnlyMainFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = dir.appendingPathComponent("readings.db").path
        try "not a real database".write(toFile: original, atomically: true, encoding: .utf8)

        try DatabaseRecovery.moveAside(databasePath: original, now: Self.fixedNow)

        let destination = DatabaseRecovery.movedAsidePath(for: original, now: Self.fixedNow)
        #expect(FileManager.default.fileExists(atPath: destination))
        #expect(!FileManager.default.fileExists(atPath: destination + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: destination + "-shm"))
    }

    @Test("moveAside with nothing at databasePath is a harmless no-op")
    func moveAsideWithNoExistingFileIsANoOp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let neverCreated = dir.appendingPathComponent("readings.db").path
        try DatabaseRecovery.moveAside(databasePath: neverCreated, now: Self.fixedNow)

        #expect(!FileManager.default.fileExists(atPath: DatabaseRecovery.movedAsidePath(for: neverCreated, now: Self.fixedNow)))
    }

    @Test("moveAside refuses and moves nothing while another process holds the database's lock")
    func moveAsideRefusesWhileLockIsHeld() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = dir.appendingPathComponent("readings.db").path
        try "not a real database".write(toFile: original, atomically: true, encoding: .utf8)

        // Stand in for the engine still holding the database open: the
        // same exclusive, non-blocking flock internal/store's own Open
        // takes, on the same lock file path moveAside itself locks.
        let lockPath = original + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        #expect(fd >= 0, "could not open lock file for the test's own holder")
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0, "the test's own holder could not take the lock")

        #expect(throws: DatabaseRecoveryError.locked) {
            try DatabaseRecovery.moveAside(databasePath: original, now: Self.fixedNow)
        }

        #expect(FileManager.default.fileExists(atPath: original), "the original file must still be at its own path")
        let destination = DatabaseRecovery.movedAsidePath(for: original, now: Self.fixedNow)
        #expect(!FileManager.default.fileExists(atPath: destination), "nothing must have moved while the lock was held")
        #expect(FileManager.default.fileExists(atPath: lockPath), "the lock file itself must never move")
    }

    @Test("moveAside succeeds once the lock is released")
    func moveAsideSucceedsAfterLockIsReleased() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = dir.appendingPathComponent("readings.db").path
        try "not a real database".write(toFile: original, atomically: true, encoding: .utf8)

        let lockPath = original + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        #expect(fd >= 0, "could not open lock file for the test's own holder")
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0, "the test's own holder could not take the lock")
        close(fd) // releases the flock, as a process quitting would.

        try DatabaseRecovery.moveAside(databasePath: original, now: Self.fixedNow)

        #expect(!FileManager.default.fileExists(atPath: original))
        let destination = DatabaseRecovery.movedAsidePath(for: original, now: Self.fixedNow)
        #expect(FileManager.default.fileExists(atPath: destination))
        #expect(FileManager.default.fileExists(atPath: lockPath), "the lock file itself must never move")
    }

    @Test("a failed -wal rename restores the whole set to its original path and leaves no dated file behind")
    func moveAsideRestoresWholeSetWhenWalRenameFails() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = dir.appendingPathComponent("readings.db").path
        try "not a real database".write(toFile: original, atomically: true, encoding: .utf8)
        try "wal contents".write(toFile: original + "-wal", atomically: true, encoding: .utf8)
        try "shm contents".write(toFile: original + "-shm", atomically: true, encoding: .utf8)

        let failing = FailingMoveFileManager(failingSourcePaths: [original + "-wal"])
        #expect(throws: (any Error).self) {
            try DatabaseRecovery.moveAside(databasePath: original, now: Self.fixedNow, fileManager: failing)
        }

        #expect(FileManager.default.fileExists(atPath: original), "the main file must be back at its own path")
        #expect(FileManager.default.fileExists(atPath: original + "-wal"), "the -wal sidecar must be back at its own path")
        #expect(FileManager.default.fileExists(atPath: original + "-shm"), "the -shm sidecar must be back at its own path")
        let destination = DatabaseRecovery.movedAsidePath(for: original, now: Self.fixedNow)
        #expect(!FileManager.default.fileExists(atPath: destination), "no dated file must remain")
        #expect(!FileManager.default.fileExists(atPath: destination + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: destination + "-shm"))
    }

    @Test("a failed -shm rename restores the whole set to its original path and leaves no dated file behind")
    func moveAsideRestoresWholeSetWhenShmRenameFails() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = dir.appendingPathComponent("readings.db").path
        try "not a real database".write(toFile: original, atomically: true, encoding: .utf8)
        try "wal contents".write(toFile: original + "-wal", atomically: true, encoding: .utf8)
        try "shm contents".write(toFile: original + "-shm", atomically: true, encoding: .utf8)

        let failing = FailingMoveFileManager(failingSourcePaths: [original + "-shm"])
        #expect(throws: (any Error).self) {
            try DatabaseRecovery.moveAside(databasePath: original, now: Self.fixedNow, fileManager: failing)
        }

        #expect(FileManager.default.fileExists(atPath: original), "the main file must be back at its own path")
        #expect(FileManager.default.fileExists(atPath: original + "-wal"), "the -wal sidecar must be back at its own path")
        #expect(FileManager.default.fileExists(atPath: original + "-shm"), "the -shm sidecar must be back at its own path")
        let destination = DatabaseRecovery.movedAsidePath(for: original, now: Self.fixedNow)
        #expect(!FileManager.default.fileExists(atPath: destination), "no dated file must remain")
        #expect(!FileManager.default.fileExists(atPath: destination + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: destination + "-shm"))
    }

    @Test("when a rename and its own rollback both fail, a later retry finishes the same move under one dated base")
    func moveAsideResumesSameDestinationWhenRollbackAlsoFails() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = dir.appendingPathComponent("readings.db").path
        try "not a real database".write(toFile: original, atomically: true, encoding: .utf8)
        try "wal contents".write(toFile: original + "-wal", atomically: true, encoding: .utf8)
        try "shm contents".write(toFile: original + "-shm", atomically: true, encoding: .utf8)

        let firstDestination = DatabaseRecovery.movedAsidePath(for: original, now: Self.fixedNow)
        // The main file's forward move succeeds, then the -wal rename
        // fails; the rollback that would move the main file back to
        // `original` fails too (its atPath is `firstDestination`).
        let failing = FailingMoveFileManager(failingSourcePaths: [original + "-wal", firstDestination])
        #expect(throws: (any Error).self) {
            try DatabaseRecovery.moveAside(databasePath: original, now: Self.fixedNow, fileManager: failing)
        }

        // The set is now split: the main file at firstDestination, the
        // sidecars still at original. A retry a second later, with
        // nothing failing this time, must finish under firstDestination
        // rather than choosing a new timestamp.
        let retryNow = Self.fixedNow.addingTimeInterval(1)
        try DatabaseRecovery.moveAside(databasePath: original, now: retryNow)

        let secondDestination = DatabaseRecovery.movedAsidePath(for: original, now: retryNow)
        #expect(FileManager.default.fileExists(atPath: firstDestination), "the whole set must land under the first dated base")
        #expect(FileManager.default.fileExists(atPath: firstDestination + "-wal"))
        #expect(FileManager.default.fileExists(atPath: firstDestination + "-shm"))
        #expect(!FileManager.default.fileExists(atPath: secondDestination), "the retry must never open a second dated base")
        #expect(!FileManager.default.fileExists(atPath: original), "the original path must hold none of the set")
        #expect(!FileManager.default.fileExists(atPath: original + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: original + "-shm"))
    }

    @Test("a stale record naming a base that already holds a complete set is ignored, and the new database at the original path moves to a fresh base")
    func moveAsideIgnoresAStaleRecordNamingACompleteSet() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = dir.appendingPathComponent("readings.db").path
        let staleNow = Self.fixedNow.addingTimeInterval(-3600)
        let staleDestination = DatabaseRecovery.movedAsidePath(for: original, now: staleNow)

        // A dated base that already holds a complete set, as it would
        // once an earlier move finished but clearing its own record
        // afterward failed.
        try "old moved database".write(toFile: staleDestination, atomically: true, encoding: .utf8)
        try "old wal".write(toFile: staleDestination + "-wal", atomically: true, encoding: .utf8)
        try "old shm".write(toFile: staleDestination + "-shm", atomically: true, encoding: .utf8)

        // The stale record survives, still naming that old base.
        let markerPath = original + ".moving"
        try staleDestination.write(toFile: markerPath, atomically: true, encoding: .utf8)

        // A new, unrelated unreadable database now sits at the original
        // path -- this is not the set the stale record describes.
        try "new unreadable database".write(toFile: original, atomically: true, encoding: .utf8)

        try DatabaseRecovery.moveAside(databasePath: original, now: Self.fixedNow)

        #expect(!FileManager.default.fileExists(atPath: original), "the original path must be empty after moving aside")
        let freshDestination = DatabaseRecovery.movedAsidePath(for: original, now: Self.fixedNow)
        #expect(freshDestination != staleDestination, "the fresh destination must differ from the stale record's destination")
        #expect(FileManager.default.fileExists(atPath: freshDestination), "the new database must move to a fresh base")
        #expect(try String(contentsOfFile: freshDestination, encoding: .utf8) == "new unreadable database")

        // The old dated base is untouched: the stale record never caused
        // it to be read from, written to, or merged with anything.
        #expect(try String(contentsOfFile: staleDestination, encoding: .utf8) == "old moved database")
        #expect(try String(contentsOfFile: staleDestination + "-wal", encoding: .utf8) == "old wal")
        #expect(try String(contentsOfFile: staleDestination + "-shm", encoding: .utf8) == "old shm")
    }

    @Test("hasSplitMove is true when a record exists and the set is genuinely split across it")
    func hasSplitMoveTrueForAGenuineSplit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = dir.appendingPathComponent("readings.db").path
        let destination = DatabaseRecovery.movedAsidePath(for: original, now: Self.fixedNow)

        // The main file already landed at destination; the -wal sidecar
        // is still at original -- exactly what a rename that failed
        // partway, with a rollback that also failed, leaves behind.
        try "moved main file".write(toFile: destination, atomically: true, encoding: .utf8)
        try "sidecar left behind".write(toFile: original + "-wal", atomically: true, encoding: .utf8)
        try destination.write(toFile: original + ".moving", atomically: true, encoding: .utf8)

        #expect(DatabaseRecovery.hasSplitMove(databasePath: original) == true)
    }

    @Test("hasSplitMove is false with no record at all")
    func hasSplitMoveFalseWithNoRecord() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = dir.appendingPathComponent("readings.db").path
        try "a whole database, never touched by any move".write(toFile: original, atomically: true, encoding: .utf8)

        #expect(DatabaseRecovery.hasSplitMove(databasePath: original) == false)
    }

    @Test("hasSplitMove is false for a stale record naming a destination that already holds an unrelated complete set, and leaves the record in place")
    func hasSplitMoveFalseForAStaleRecord() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = dir.appendingPathComponent("readings.db").path
        let staleNow = Self.fixedNow.addingTimeInterval(-3600)
        let staleDestination = DatabaseRecovery.movedAsidePath(for: original, now: staleNow)

        // The stale destination already holds a complete, unrelated set.
        try "old moved database".write(toFile: staleDestination, atomically: true, encoding: .utf8)
        // A new, whole database now sits at the original path too, so
        // the record no longer describes any real split.
        try "new database at the original path".write(toFile: original, atomically: true, encoding: .utf8)

        let markerPath = original + ".moving"
        try staleDestination.write(toFile: markerPath, atomically: true, encoding: .utf8)

        #expect(DatabaseRecovery.hasSplitMove(databasePath: original) == false)
        #expect(FileManager.default.fileExists(atPath: markerPath), "hasSplitMove must not remove a stale record; only moveAside decides that")
    }

    @Test("hasSplitMove is false once the whole set already sits at the recorded destination and nothing remains at the original path")
    func hasSplitMoveFalseWhenTheWholeSetAlreadyMoved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = dir.appendingPathComponent("readings.db").path
        let destination = DatabaseRecovery.movedAsidePath(for: original, now: Self.fixedNow)

        // The move finished in full -- nothing left at the original path
        // -- but its own record survived, as it would if clearing the
        // record afterward failed.
        try "moved main file".write(toFile: destination, atomically: true, encoding: .utf8)
        try "moved wal".write(toFile: destination + "-wal", atomically: true, encoding: .utf8)
        try destination.write(toFile: original + ".moving", atomically: true, encoding: .utf8)

        #expect(DatabaseRecovery.hasSplitMove(databasePath: original) == false)
    }

    @Test("moveAside throws and moves nothing when it cannot record the destination before its first rename")
    func moveAsideThrowsWhenItCannotRecordTheDestination() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = dir.appendingPathComponent("readings.db").path
        try "not a real database".write(toFile: original, atomically: true, encoding: .utf8)
        try "wal contents".write(toFile: original + "-wal", atomically: true, encoding: .utf8)

        let markerPath = original + ".moving"
        let failing = FailingCreateFileManager(failingPath: markerPath)

        #expect(throws: DatabaseRecoveryError.destinationNotRecorded) {
            try DatabaseRecovery.moveAside(databasePath: original, now: Self.fixedNow, fileManager: failing)
        }

        #expect(FileManager.default.fileExists(atPath: original), "the main file must still be at its own path")
        #expect(FileManager.default.fileExists(atPath: original + "-wal"), "the -wal sidecar must still be at its own path")
        let destination = DatabaseRecovery.movedAsidePath(for: original, now: Self.fixedNow)
        #expect(!FileManager.default.fileExists(atPath: destination), "nothing must have moved when the destination could not be recorded")
        #expect(!FileManager.default.fileExists(atPath: markerPath), "no record must exist either, since the write itself failed")
    }
}

/// FailingMoveFileManager throws for any moveItem(atPath:toPath:) whose
/// atPath is one of failingSourcePaths, in either direction: moveAside
/// calls it with the source as atPath on the way out, and with the
/// already-moved destination as atPath while rolling back, so a path
/// placed here fails a rename it takes part in regardless of which way
/// that rename runs.
private final class FailingMoveFileManager: FileManager, @unchecked Sendable {
    private let failingSourcePaths: Set<String>

    init(failingSourcePaths: Set<String>) {
        self.failingSourcePaths = failingSourcePaths
        super.init()
    }

    override func moveItem(atPath srcPath: String, toPath dstPath: String) throws {
        if failingSourcePaths.contains(srcPath) {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EACCES),
                userInfo: [NSLocalizedDescriptionKey: "synthetic failure for a test"]
            )
        }
        try super.moveItem(atPath: srcPath, toPath: dstPath)
    }
}

/// FailingCreateFileManager fails createFile(atPath:contents:) for exactly
/// one path, standing in for a folder that has gone unwritable right when
/// moveAside tries to record its destination there.
private final class FailingCreateFileManager: FileManager, @unchecked Sendable {
    private let failingPath: String

    init(failingPath: String) {
        self.failingPath = failingPath
        super.init()
    }

    override func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]? = nil) -> Bool {
        if path == failingPath {
            return false
        }
        return super.createFile(atPath: path, contents: data, attributes: attr)
    }
}

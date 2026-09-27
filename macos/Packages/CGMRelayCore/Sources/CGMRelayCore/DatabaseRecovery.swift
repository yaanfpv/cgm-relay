import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// DatabaseRecoveryError is thrown by moveAside for a condition specific
/// to this type, rather than one FileManager itself reports.
public enum DatabaseRecoveryError: Error, Sendable, Equatable {
    /// locked means another process -- the engine, most likely, still
    /// running against this same database -- currently holds its
    /// exclusive lock, so moveAside refused rather than racing it for the
    /// same file. Nothing was moved.
    case locked
    /// destinationNotRecorded means moveAside could not write down the
    /// destination it is about to move the set into, before renaming
    /// anything. It moved nothing rather than risk leaving the set split
    /// with no record a later call could resume from.
    case destinationNotRecorded
}

/// DatabaseRecovery moves a reading database this Mac's key can no longer
/// open out of the way, so a person recovering from that can start fresh
/// without ever losing the old file: it is renamed, never deleted.
public enum DatabaseRecovery {
    /// lockPath is where internal/store's own dbLock keeps its exclusive
    /// advisory flock while a database is open: databasePath with
    /// ".lock" appended. internal/store/lock.go's own lockSuffix constant
    /// must always agree with this suffix.
    private static func lockPath(for databasePath: String) -> String {
        databasePath + ".lock"
    }

    /// movedAsidePath is where moveAside renames databasePath to: the same
    /// directory and extension, with " (unreadable, <timestamp>)" appended
    /// to the base name. The timestamp is down to the second so two
    /// recoveries on the same day still produce distinct names. A `-wal`
    /// or `-shm` sidecar moves to this same returned string with its own
    /// suffix appended, exactly as it sat beside the original file.
    public static func movedAsidePath(for databasePath: String, now: Date) -> String {
        let url = URL(fileURLWithPath: databasePath)
        let stamp = recoveryTimestampFormatter().string(from: now)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let renamedName = ext.isEmpty
            ? "\(base) (unreadable, \(stamp))"
            : "\(base) (unreadable, \(stamp)).\(ext)"
        return url.deletingLastPathComponent().appendingPathComponent(renamedName).path
    }

    /// moveAside renames the file at databasePath to movedAsidePath(...),
    /// and does the same for a `-wal` and a `-shm` sidecar if either sits
    /// beside it: internal/store opens the database in WAL mode, so a
    /// database that did not close cleanly can leave one or both holding
    /// committed pages the main file alone lacks, and it sits at the
    /// original path where a fresh database is about to be created next.
    /// Each sidecar keeps the same new base name as the moved database,
    /// with its own suffix, so the moved set still opens together. Any
    /// one of the three missing at its original path is a harmless
    /// no-op for that one, rather than an error -- including every one of
    /// them, on a fresh install that never reached this recovery.
    ///
    /// The move is all-or-nothing from the caller's point of view. If a
    /// rename fails partway, moveAside moves everything it already moved
    /// back to its original path, in reverse order, before throwing --
    /// the caller sees the set exactly as it was. If one of those
    /// restoring renames also fails, the set is left split between the
    /// original path and the destination this attempt chose.
    ///
    /// The destination this call is about to use is written to
    /// pendingMovePath(for:) before the first rename, not after the
    /// first failure: a rename can split the set, then leave the folder
    /// unwritable for the record meant to describe that split, so the
    /// record has to already exist before either can happen. If that
    /// write itself fails, moveAside throws
    /// DatabaseRecoveryError.destinationNotRecorded and moves nothing --
    /// a folder that cannot hold the record can never be left holding an
    /// unrecorded split. The record is removed again, best effort, the
    /// moment nothing of the set remains at the destination any more --
    /// by the move completing or by a full rollback -- so an ordinary
    /// attempt leaves no trace behind it.
    ///
    /// On entry, a call finds whatever record the previous attempt left.
    /// It resumes into the recorded destination only when the set is
    /// actually split across it and the original path right now: some
    /// member sits only at the original path, some member sits only at
    /// the destination, and no member sits at both. Any other reading --
    /// no record, or a record whose destination does not describe a
    /// split of what is at the original path right now -- is stale
    /// rather than resumable: it is discarded, and this call chooses a
    /// fresh destination from the current timestamp instead, exactly as
    /// it would with no record at all. This is what keeps a marker that
    /// survived its own removal failure, after an earlier move had
    /// already completed, from pulling a later and unrelated recovery
    /// into the old destination.
    ///
    /// Before moving anything, moveAside takes the same exclusive lock
    /// internal/store's own Open takes: if some other process still has
    /// the database open, moveAside throws DatabaseRecoveryError.locked
    /// and moves nothing, rather than renaming a file another process is
    /// actively reading or writing out from under it. The lock file
    /// itself is never one of the three moved; it stays at its own path
    /// so the next Open, of either the moved-aside file or a fresh one,
    /// finds it right where it left it.
    public static func moveAside(
        databasePath: String,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws {
        let lockFilePath = lockPath(for: databasePath)
        let fd = open(lockFilePath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "could not open lock file \(lockFilePath): \(String(cString: strerror(errno)))"]
            )
        }
        defer { close(fd) }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if errno == EWOULDBLOCK {
                throw DatabaseRecoveryError.locked
            }
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "could not lock \(lockFilePath): \(String(cString: strerror(errno)))"]
            )
        }

        let markerPath = pendingMovePath(for: databasePath)
        let destination = resumableDestination(
            databasePath: databasePath,
            markerPath: markerPath,
            fileManager: fileManager
        ) ?? movedAsidePath(for: databasePath, now: now)

        guard fileManager.createFile(atPath: markerPath, contents: Data(destination.utf8)) else {
            throw DatabaseRecoveryError.destinationNotRecorded
        }

        var moved: [(source: String, destination: String)] = []
        var thrown: Error?
        for suffix in ["", "-wal", "-shm"] {
            let source = databasePath + suffix
            guard fileManager.fileExists(atPath: source) else { continue }
            let movedTo = destination + suffix
            do {
                try fileManager.moveItem(atPath: source, toPath: movedTo)
                moved.append((source: source, destination: movedTo))
            } catch {
                thrown = error
                break
            }
        }

        guard let thrown else {
            try? fileManager.removeItem(atPath: markerPath)
            return
        }

        // Best effort: put back everything this call moved, in reverse
        // order. A failure here is exactly the case the record already
        // written above describes, so nothing further needs recording --
        // only clearing it again once it no longer applies.
        for entry in moved.reversed() {
            try? fileManager.moveItem(atPath: entry.destination, toPath: entry.source)
        }
        clearPendingMoveIfRolledBack(markerPath: markerPath, destination: destination, fileManager: fileManager)
        throw thrown
    }

    /// hasSplitMove reports whether databasePath is right now genuinely
    /// split by an earlier moveAside that recorded a destination and then
    /// failed to finish or roll back: true only when a record exists and
    /// still describes a real split, per isGenuinelySplit(...). A stale
    /// record -- one describing no split that exists any more -- reads
    /// false here, exactly as resumableDestination would discard it, but
    /// this call never removes it: it only answers the question, leaving
    /// moveAside itself as the one place that decides what to do with a
    /// stale record.
    public static func hasSplitMove(databasePath: String, fileManager: FileManager = .default) -> Bool {
        let markerPath = pendingMovePath(for: databasePath)
        guard let recorded = recordedPendingDestination(markerPath: markerPath, fileManager: fileManager) else {
            return false
        }
        return isGenuinelySplit(databasePath: databasePath, destination: recorded, fileManager: fileManager)
    }

    /// pendingMovePath is where moveAside records the destination it is
    /// about to use, written before its first rename and read back by a
    /// later call to decide whether to resume it. It holds nothing but
    /// that one path, from just before this attempt's first rename until
    /// either the move completes or a full rollback restores the
    /// original set -- both clear it again, best effort.
    private static func pendingMovePath(for databasePath: String) -> String {
        databasePath + ".moving"
    }

    /// recordedPendingDestination reads back whatever destination a
    /// previous attempt wrote, with no judgement about whether it still
    /// describes anything real -- resumableDestination makes that call.
    private static func recordedPendingDestination(markerPath: String, fileManager: FileManager) -> String? {
        guard let data = fileManager.contents(atPath: markerPath),
              let destination = String(data: data, encoding: .utf8),
              !destination.isEmpty
        else {
            return nil
        }
        return destination
    }

    /// resumableDestination returns a previous attempt's recorded
    /// destination only when the set is actually split across it and
    /// databasePath right now, per isGenuinelySplit(...). Any other
    /// record is stale -- it describes no split that exists any more, or
    /// never described one to begin with -- so it is removed here and
    /// treated as absent, exactly like a fresh recovery with no record
    /// at all.
    private static func resumableDestination(
        databasePath: String,
        markerPath: String,
        fileManager: FileManager
    ) -> String? {
        guard let recorded = recordedPendingDestination(markerPath: markerPath, fileManager: fileManager) else {
            return nil
        }
        guard isGenuinelySplit(databasePath: databasePath, destination: recorded, fileManager: fileManager) else {
            try? fileManager.removeItem(atPath: markerPath)
            return nil
        }
        return recorded
    }

    /// isGenuinelySplit reports whether the set is actually divided
    /// between databasePath and destination right now: at least one
    /// member (main file, -wal, or -shm) sits only at databasePath, at
    /// least one sits only at destination, and no member sits at both.
    /// That last condition is what tells a genuine split -- the same
    /// member can only be at one place, since a rename moves it rather
    /// than copying it -- apart from two independent, unrelated sets
    /// that happen to share a stale record: a member present at both is
    /// exactly that case, and turns the whole record stale regardless of
    /// what the other members show.
    private static func isGenuinelySplit(databasePath: String, destination: String, fileManager: FileManager) -> Bool {
        var onlyAtOriginal = false
        var onlyAtDestination = false
        for suffix in ["", "-wal", "-shm"] {
            let atOriginal = fileManager.fileExists(atPath: databasePath + suffix)
            let atDestination = fileManager.fileExists(atPath: destination + suffix)
            if atOriginal && atDestination {
                return false
            }
            onlyAtOriginal = onlyAtOriginal || atOriginal
            onlyAtDestination = onlyAtDestination || atDestination
        }
        return onlyAtOriginal && onlyAtDestination
    }

    /// clearPendingMoveIfRolledBack is called after a failed move and its
    /// best-effort rollback, to decide whether the record this attempt
    /// already wrote before its first rename still applies. It looks at
    /// what is actually at destination now, not at whether the rollback
    /// reported success, since a partial rollback and a full one both
    /// leave real files behind that a later call must still be told
    /// about. Nothing there means the set is back at databasePath in
    /// full, so the record is cleared; its content never needs rewriting
    /// here, since it already names this same destination.
    private static func clearPendingMoveIfRolledBack(markerPath: String, destination: String, fileManager: FileManager) {
        let stillAtDestination = ["", "-wal", "-shm"].contains { fileManager.fileExists(atPath: destination + $0) }
        if !stillAtDestination {
            try? fileManager.removeItem(atPath: markerPath)
        }
    }

    /// recoveryTimestampFormatter is built fresh on every call rather than
    /// cached as shared state: DateFormatter is not Sendable, and this
    /// type has no other reason to hold any state at all. UTC and a fixed
    /// POSIX locale keep the rendered name identical regardless of where
    /// or in what locale the app runs, and its digits-and-dashes shape is
    /// always a valid path component on every filesystem this app ships
    /// on.
    private static func recoveryTimestampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }
}

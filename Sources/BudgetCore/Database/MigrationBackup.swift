import Foundation
import GRDB
import OSLog

/// A copy of the database taken at launch, before a build that has migrations the file
/// hasn't run applies them. Lives beside the database; the newest few are kept.
public enum MigrationBackup {
    public static let fileNamePrefix = "budget.sqlite.pre-migration-backup-"
    private static let log = Logger(subsystem: "com.personal.budget", category: "MigrationBackup")
    /// Exactly a finished backup: the stamp, then an optional collision suffix. Anything else
    /// (-wal, -shm, .partial, a user's lookalike) is never touched by retention.
    private static let namePattern = #"^budget\.sqlite\.pre-migration-backup-\d{8}-\d{6}(-\d+)?$"#

    /// The whole launch sequence: back up if migrations are pending, then migrate. A backup
    /// that can't be made throws before `migrate()` runs, leaving the database untouched.
    @discardableResult
    public static func backUpThenMigrate(manager: DatabaseManager, databasePath: String, now: Date) throws -> URL? {
        let url = try backUpIfNeeded(manager: manager, databasePath: databasePath, now: now)
        try manager.migrate()
        return url
    }

    /// Returns the backup's URL, or nil when nothing is pending or the database file doesn't
    /// exist yet (a first launch). Throws if the copy can't be made, so launch stops with the
    /// database untouched.
    public static func backUpIfNeeded(
        manager: DatabaseManager, databasePath: String, now: Date, keep: Int = 5
    ) throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: databasePath), try manager.hasPendingMigrations() else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        let directory = URL(fileURLWithPath: databasePath).deletingLastPathComponent()
        let base = fileNamePrefix + formatter.string(from: now)
        // Never overwrite an existing backup: a same-second one keeps its name, this one gets a suffix.
        var target = directory.appendingPathComponent(base)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = directory.appendingPathComponent("\(base)-\(n)")
            n += 1
        }
        // Written under a temporary name and moved into place only once complete, so a
        // crash never leaves a truncated file under a backup name.
        let partial = target.appendingPathExtension("partial")
        do {
            try? fm.removeItem(at: partial)
            let destination = try DatabaseQueue(path: partial.path)
            // The SQLite backup API from the open queue, so anything still in the WAL is included.
            try manager.dbQueue.backup(to: destination)
            try destination.close()
            try fm.moveItem(at: partial, to: target)
        } catch {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try? fm.removeItem(atPath: partial.path + suffix)
            }
            throw error
        }
        log.info("Pre-migration backup written: \(target.path, privacy: .public)")

        let existing = try fm.contentsOfDirectory(atPath: directory.path)
            .filter { $0.range(of: namePattern, options: .regularExpression) != nil && $0 != target.lastPathComponent }
            .sorted(by: >)
        for name in existing.dropFirst(max(keep, 1) - 1) {
            do { try fm.removeItem(at: directory.appendingPathComponent(name)) }
            catch { log.error("Couldn't remove old backup \(name, privacy: .public): \(error.localizedDescription, privacy: .public)") }
        }
        return target
    }
}

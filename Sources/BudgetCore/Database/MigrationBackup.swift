import Foundation
import GRDB

/// A copy of the database taken at launch, before a build that has migrations the file
/// hasn't run applies them. Lives beside the database; the newest few are kept.
public enum MigrationBackup {
    public static let fileNamePrefix = "budget.sqlite.pre-migration-backup-"

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

        let source = URL(fileURLWithPath: databasePath)
        let directory = source.deletingLastPathComponent()
        let target = directory.appendingPathComponent(fileNamePrefix + formatter.string(from: now))
        do {
            // The SQLite backup API from the open queue, so anything still in the WAL is included.
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            let destination = try DatabaseQueue(path: target.path)
            try manager.dbQueue.backup(to: destination)
            try destination.close()
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }

        let existing = try fm.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(fileNamePrefix) }
            .sorted(by: >)
        for name in existing.dropFirst(max(keep, 1)) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
        return target
    }
}

import Foundation
import GRDB

/// A copy of the database taken before an import that writes a lot (any statement, or 25 or
/// more items), next to the database as `"<db>.pre-import-backup-yyyyMMdd-HHmmss"`. Only the
/// newest `keep` are kept. An in-memory database (no path) is never backed up.
public enum ImportBackup {
    static let keep = 10
    static let marker = ".pre-import-backup-"
    /// Ready items from which a plan is backed up even without a statement.
    static let itemThreshold = 25

    /// Whether applying the plan warrants a backup: among the items the importer applies
    /// (`ImportApplier.appliedItems`), a statement, or `itemThreshold` items.
    static func isNeeded(_ plan: ImportPlan) -> Bool {
        let ready = ImportApplier.appliedItems(plan)
        if ready.count >= itemThreshold { return true }
        return ready.contains { item in
            if case .ukStatement = item.effect { return true }
            return false
        }
    }

    /// The backup's path, or nil when none was needed (or the database is in memory). Older
    /// backups beyond the newest `keep` are removed.
    public static func backupIfNeeded(dbQueue: DatabaseQueue, databasePath: String?, plan: ImportPlan, now: Date) throws -> String? {
        guard let databasePath, !databasePath.isEmpty, databasePath != ":memory:", isNeeded(plan) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let path = databasePath + marker + formatter.string(from: now)
        do {
            let destination = try DatabaseQueue(path: path)
            try dbQueue.backup(to: destination)
            try destination.close()
        } catch {
            try? FileManager.default.removeItem(atPath: path)
            throw error
        }
        prune(databasePath: databasePath)
        return path
    }

    /// Removes the backups of `databasePath` older than the newest `keep` (by the time in their
    /// name), with any `-wal` / `-shm` / `-journal` files beside them.
    static func prune(databasePath: String) {
        let url = URL(fileURLWithPath: databasePath)
        let directory = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + marker
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        let sidecars = ["-wal", "-shm", "-journal"]
        let backups = names.filter { name in name.hasPrefix(prefix) && !sidecars.contains { name.hasSuffix($0) } }.sorted(by: >)
        for name in backups.dropFirst(keep) {
            for file in [name] + sidecars.map({ name + $0 }) where names.contains(file) {
                try? fileManager.removeItem(at: directory.appendingPathComponent(file))
            }
        }
    }
}

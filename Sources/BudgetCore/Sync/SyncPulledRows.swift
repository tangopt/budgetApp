import Foundation
import GRDB

/// The transactions a sync pull inserted on this device (step 9: the waiting documents are matched only against
/// rows new here). Each insert of an incoming transaction (`SyncTranslator`) is noted in a connection-local TEMP
/// table, so it is never synced nor stored, and a simulated apply that rolls back (`FiledYearSyncCheck`) takes its
/// notes back with it; `takeTransactions` reads and clears them.
public enum SyncPulledRows {
    static func record(table: String, localId: Int64, db: Database) throws {
        guard table == Transaction.databaseTableName else { return }
        try db.execute(sql: "CREATE TEMP TABLE IF NOT EXISTS syncPulledTransaction (id INTEGER PRIMARY KEY)")
        try db.execute(sql: "INSERT OR IGNORE INTO temp.syncPulledTransaction (id) VALUES (?)", arguments: [localId])
    }

    /// The transactions inserted by pulls since the last call (still present), and forgets them.
    public static func takeTransactions(db: Database) throws -> Set<Int64> {
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM sqlite_temp_master WHERE name = 'syncPulledTransaction')") == true else {
            return []
        }
        let ids = Set(try Int64.fetchAll(db, sql: """
            SELECT p.id FROM temp.syncPulledTransaction p JOIN main.\(Transaction.databaseTableName) t ON t.id = p.id
            """))
        try db.execute(sql: "DELETE FROM temp.syncPulledTransaction")
        return ids
    }
}

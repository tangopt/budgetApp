import Foundation
import GRDB

/// How the iPhone opens its database (plan step 4 Task 4, Review Focus 1). The phone is read-only and the Mac is
/// the hub (sync spec §3): before its first pull the phone's database must hold no row of any synced table and
/// nothing pending, or a seeded category or a matched transfer would collide with the household's records when
/// they arrive. So it migrates and nothing else: no `CategorySeeder`, no `TransferCategories.ensure`, no
/// `TransferMatcher`, no forecast or rate writer.
///
/// File protection (`completeUntilFirstUserAuthentication`) and the backup exclusion are the caller's
/// (`Phone/PhoneDatabase.swift`), applied with Foundation file attributes.
public enum PhoneDatabasePolicy {
    /// The folder under the app's Application Support that holds `budget.sqlite` on the phone. The app-data
    /// refusal (`TaxRegression.appDataFolders`) treats it as the app's own data.
    public static let folderName = "Mango"
    public static let fileName = "budget.sqlite"

    /// Opens (creating if needed) and migrates the database at `path`. Writes nothing else.
    public static func open(at path: String) throws -> DatabaseManager {
        let manager = try DatabaseManager(path: path)
        try manager.migrate()
        return manager
    }

    /// Rows across every synced table (`SyncSchema.tables`), except the rows every device's migrations seed
    /// alike: the built-in categories (`builtInRole` set: balance adjustment, market movement). Those carry the
    /// same UUID on every device (`SyncRecordStore.builtInCategoryUUID`) and merge by identity
    /// (`SyncSchema.uniqueKeys`), so they can't collide with the household's on arrival. Any other row counts.
    public static func syncedRowCount(db: Database) throws -> Int {
        try SyncSchema.tables.reduce(0) { total, table in
            let filter = table.name == "category" ? " WHERE builtInRole IS NULL" : ""
            return total + (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table.name.quotedDatabaseIdentifier)\(filter)") ?? 0)
        }
    }
}

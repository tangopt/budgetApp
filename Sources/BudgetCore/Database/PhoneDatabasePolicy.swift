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

    /// Why a `BUDGET_DB_PATH` override (DEBUG simulator builds only) can't be opened, or nil when it can. The
    /// simulator reaches the Mac's files, and inside it `TaxRegression.isAppData` sees only the simulator's own
    /// container, so the override must name a demo database (`DemoMarker`) that is neither the app's data nor under
    /// any Mac app's data folder (`Library/Application Support/Budget`, `Library/Containers`). Checked before
    /// anything opens or migrates the file.
    public static func overrideRefusal(path: String, fileManager: FileManager = .default) -> String? {
        guard path.hasPrefix("/"), !path.lowercased().hasPrefix("file:") else {
            return "BUDGET_DB_PATH must be an absolute file path."
        }
        let resolved = TaxRegression.resolvedPath(path, fileManager: fileManager)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return "There is no database file at BUDGET_DB_PATH."
        }
        let lowered = resolved.lowercased()
        guard !TaxRegression.isAppData(resolved, fileManager: fileManager),
              !lowered.contains("/library/application support/budget/"),
              !lowered.contains("/library/containers/") else {
            return "BUDGET_DB_PATH is the app's own data; the phone opens only a demo database there."
        }
        guard DemoMarker.isDemoDatabase(atPath: resolved, fileManager: fileManager) else {
            return "BUDGET_DB_PATH isn't the demo database (MakeDemoDatabase builds one)."
        }
        return nil
    }

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

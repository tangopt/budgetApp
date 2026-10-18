import Foundation
import GRDB

/// How the synthetic demo database (`BudgetDemo`, `MakeDemoDatabase`) is told apart from a
/// real one: its SQLite `application_id`, and a marker file in its evidence folder. The UI
/// snapshot harness opens only a database carrying the id; the demo tool replaces only files
/// and folders carrying the markers.
public enum DemoMarker {
    /// The demo database's `PRAGMA application_id` ("BDEM").
    public static let applicationID: Int32 = 0x4244_454D
    /// The file a demo evidence folder holds.
    public static let evidenceFileName = ".budget-demo-evidence"

    /// Whether the database file at `path` exists and carries the demo id (opened read-only).
    public static func isDemoDatabase(atPath path: String, fileManager: FileManager = .default) -> Bool {
        guard fileManager.fileExists(atPath: path) else { return false }
        var configuration = Configuration()
        configuration.readonly = true
        guard let queue = try? DatabaseQueue(path: path, configuration: configuration),
              let id = try? queue.read({ db in try Int32.fetchOne(db, sql: "PRAGMA application_id") }) else { return false }
        return id == applicationID
    }

    /// Marks a database as the demo's.
    public static func mark(_ db: Database) throws {
        try db.execute(sql: "PRAGMA application_id = \(applicationID)")
    }
}

import GRDB
import Foundation

/// An edit to a single occurrence of a recurring `ForecastEntry`, keyed by
/// `(entryId, originalDate)` — the date the series would have produced.
public struct PlannedOccurrenceException: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var entryId: Int64
    /// Must equal the series' generated occurrence date exactly; build keys only from
    /// `PlannedOccurrence.originalDate`.
    public var originalDate: Date
    public var isSkipped: Bool
    public var amountMinorUnits: Int?
    public var date: Date?
    public var categoryId: Int64?

    public init(id: Int64? = nil, entryId: Int64, originalDate: Date, isSkipped: Bool = false, amountMinorUnits: Int? = nil, date: Date? = nil, categoryId: Int64? = nil) {
        self.id = id
        self.entryId = entryId
        self.originalDate = originalDate
        self.isSkipped = isSkipped
        self.amountMinorUnits = amountMinorUnits
        self.date = date
        self.categoryId = categoryId
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "plannedOccurrenceException"
}

func registerPlannedOccurrenceExceptionMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createPlannedOccurrenceException") { db in
        try db.create(table: "plannedOccurrenceException") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("entryId", .integer).notNull().references("forecastEntry", onDelete: .cascade)
            t.column("originalDate", .datetime).notNull()
            t.column("isSkipped", .boolean).notNull().defaults(to: false)
            t.column("amountMinorUnits", .integer)
            t.column("date", .datetime)
            t.column("categoryId", .integer).references("category", onDelete: .setNull)
        }
        try db.create(index: "plannedOccurrenceException_entry_original", on: "plannedOccurrenceException", columns: ["entryId", "originalDate"], unique: true)
        // Detection no longer owns planned items; existing auto entries become manual.
        try db.execute(sql: "UPDATE forecastEntry SET status = 'manual' WHERE status = 'auto'")
    }
}

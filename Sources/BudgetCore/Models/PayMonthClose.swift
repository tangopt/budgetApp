import GRDB
import Foundation

/// A manual override of the day a pay month closes (for months with no imported salary yet,
/// or to correct one). At most one per `(year, month)`.
public struct PayMonthClose: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var year: Int
    public var month: Int
    public var closeDate: Date

    public init(id: Int64? = nil, year: Int, month: Int, closeDate: Date) {
        self.id = id
        self.year = year
        self.month = month
        self.closeDate = closeDate
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "payMonthClose"
}

func registerPayMonthCloseMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createPayMonthClose") { db in
        try db.create(table: "payMonthClose") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("year", .integer).notNull()
            t.column("month", .integer).notNull()
            t.column("closeDate", .datetime).notNull()
        }
        try db.create(index: "payMonthClose_year_month", on: "payMonthClose", columns: ["year", "month"], unique: true)
    }
}

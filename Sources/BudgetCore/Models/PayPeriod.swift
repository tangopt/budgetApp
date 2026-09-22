import GRDB
import Foundation

public enum PayPeriodType: String, Codable, CaseIterable {
    case actual
    case projected
}

public struct PayPeriod: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var startDate: Date
    public var endDate: Date
    public var type: PayPeriodType

    public init(id: Int64? = nil, startDate: Date, endDate: Date, type: PayPeriodType) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.type = type
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "payPeriod"
}

func registerPayPeriodMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createPayPeriod") { db in
        try db.create(table: "payPeriod") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("startDate", .datetime).notNull()
            t.column("endDate", .datetime).notNull()
            t.column("type", .text).notNull()
        }
    }
}

import GRDB
import Foundation

public enum ForecastFrequency: String, Codable, CaseIterable {
    case once
    case weekly
    case monthly
    case annually
}

public enum ForecastEntryStatus: String, Codable, CaseIterable {
    case auto
    case manual
    case hypothetical
    case confirmed
}

public struct ForecastEntry: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var groupId: Int64
    public var categoryId: Int64
    public var amountMinorUnits: Int
    public var frequency: ForecastFrequency
    public var interval: Int
    public var startDate: Date
    public var endDate: Date?
    public var isEnabled: Bool
    public var status: ForecastEntryStatus
    public var note: String?

    public init(id: Int64? = nil, groupId: Int64, categoryId: Int64, amountMinorUnits: Int, frequency: ForecastFrequency, interval: Int, startDate: Date, endDate: Date?, isEnabled: Bool, status: ForecastEntryStatus, note: String?) {
        self.id = id
        self.groupId = groupId
        self.categoryId = categoryId
        self.amountMinorUnits = amountMinorUnits
        self.frequency = frequency
        self.interval = interval
        self.startDate = startDate
        self.endDate = endDate
        self.isEnabled = isEnabled
        self.status = status
        self.note = note
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "forecastEntry"
}

func registerForecastEntryMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createForecastEntry") { db in
        try db.create(table: "forecastEntry") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("groupId", .integer).notNull().references("forecastGroup")
            t.column("categoryId", .integer).notNull().references("category")
            t.column("amountMinorUnits", .integer).notNull()
            t.column("frequency", .text).notNull()
            t.column("interval", .integer).notNull().defaults(to: 1)
            t.column("startDate", .datetime).notNull()
            t.column("endDate", .datetime)
            t.column("isEnabled", .boolean).notNull().defaults(to: true)
            t.column("status", .text).notNull()
            t.column("note", .text)
        }
    }
}

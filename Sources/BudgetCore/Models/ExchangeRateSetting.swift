import GRDB
import Foundation

public struct ExchangeRateSetting: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var eurToGbpRate: Double
    public var updatedAt: Date

    public init(id: Int64? = nil, eurToGbpRate: Double, updatedAt: Date) {
        self.id = id
        self.eurToGbpRate = eurToGbpRate
        self.updatedAt = updatedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "exchangeRateSetting"

    /// Returns the most recently saved rate, or a sensible default (0.87) if none has been set yet.
    public static func currentOrDefault(db: Database) throws -> ExchangeRateSetting {
        if let latest = try ExchangeRateSetting.order(Column("updatedAt").desc).fetchOne(db) {
            return latest
        }
        return ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: Date())
    }
}

func registerExchangeRateSettingMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createExchangeRateSetting") { db in
        try db.create(table: "exchangeRateSetting") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("eurToGbpRate", .double).notNull()
            t.column("updatedAt", .datetime).notNull()
        }
    }
}

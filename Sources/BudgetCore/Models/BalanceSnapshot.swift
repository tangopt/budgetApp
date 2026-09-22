import GRDB
import Foundation

public struct BalanceSnapshot: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var accountId: Int64
    public var date: Date
    public var balanceMinorUnits: Int
    public var note: String?

    public init(id: Int64? = nil, accountId: Int64, date: Date, balanceMinorUnits: Int, note: String?) {
        self.id = id
        self.accountId = accountId
        self.date = date
        self.balanceMinorUnits = balanceMinorUnits
        self.note = note
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "balanceSnapshot"
}

func registerBalanceSnapshotMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createBalanceSnapshot") { db in
        try db.create(table: "balanceSnapshot") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("accountId", .integer).notNull().references("account")
            t.column("date", .datetime).notNull()
            t.column("balanceMinorUnits", .integer).notNull()
            t.column("note", .text)
        }
    }
}

import GRDB

public struct CategoryGroup: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var name: String

    public init(id: Int64? = nil, name: String) {
        self.id = id
        self.name = name
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "categoryGroup"
}

func registerCategoryGroupMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createCategoryGroup") { db in
        try db.create(table: "categoryGroup") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull().unique()
        }
    }
}

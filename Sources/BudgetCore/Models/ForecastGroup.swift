import GRDB

public struct ForecastGroup: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var name: String
    public var note: String?
    public var isEnabled: Bool
    public var isSystemManaged: Bool

    public init(id: Int64? = nil, name: String, note: String?, isEnabled: Bool, isSystemManaged: Bool) {
        self.id = id
        self.name = name
        self.note = note
        self.isEnabled = isEnabled
        self.isSystemManaged = isSystemManaged
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "forecastGroup"
}

func registerForecastGroupMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createForecastGroup") { db in
        try db.create(table: "forecastGroup") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull()
            t.column("note", .text)
            t.column("isEnabled", .boolean).notNull().defaults(to: true)
            t.column("isSystemManaged", .boolean).notNull().defaults(to: false)
        }
    }
}

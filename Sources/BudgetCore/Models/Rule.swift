import GRDB

public enum RuleMatchType: String, Codable, CaseIterable {
    case contains
    case regex
}

public struct Rule: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var matchPattern: String
    public var matchType: RuleMatchType
    public var categoryId: Int64
    public var priority: Int

    public init(id: Int64? = nil, matchPattern: String, matchType: RuleMatchType, categoryId: Int64, priority: Int) {
        self.id = id
        self.matchPattern = matchPattern
        self.matchType = matchType
        self.categoryId = categoryId
        self.priority = priority
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static let databaseTableName = "rule"
}

func registerRuleMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createRule") { db in
        try db.create(table: "rule") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("matchPattern", .text).notNull()
            t.column("matchType", .text).notNull()
            t.column("categoryId", .integer).notNull().references("category")
            t.column("priority", .integer).notNull()
        }
    }
}

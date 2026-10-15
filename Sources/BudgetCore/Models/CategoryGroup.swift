import GRDB

public struct CategoryGroup: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var name: String
    /// The type section an empty group shows in (spec 2026-10-15 §2); nil (rows from before
    /// the column existed) counts as expense. A group with members shows wherever its
    /// members' types are, whatever this says.
    public var type: CategoryType?

    public init(id: Int64? = nil, name: String, type: CategoryType? = nil) {
        self.id = id
        self.name = name
        self.type = type
    }

    /// The section an empty group belongs in: its type, expense when unset.
    public var sectionType: CategoryType { type ?? .expense }

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

/// Adds `categoryGroup.type` and backfills each group with its members' majority type
/// (expense, income or transfer); ties and empty groups get expense.
func registerCategoryGroupTypeMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("addCategoryGroupType") { db in
        try db.alter(table: "categoryGroup") { t in
            t.add(column: "type", .text)
        }
        let groupIds = try Int64.fetchAll(db, sql: "SELECT id FROM categoryGroup")
        for id in groupIds {
            let counts = try Row.fetchAll(db, sql: """
                SELECT type, COUNT(*) AS n FROM category
                WHERE groupId = ? AND type IN ('expense', 'income', 'transfer') AND isReserved = 0
                GROUP BY type
                """, arguments: [id])
            let tally = counts.map { (type: $0["type"] as String, n: $0["n"] as Int) }
            let top = tally.map(\.n).max() ?? 0
            let leaders = tally.filter { $0.n == top }
            let best = leaders.count == 1 ? CategoryType(rawValue: leaders[0].type) ?? .expense : .expense
            try db.execute(sql: "UPDATE categoryGroup SET type = ? WHERE id = ?", arguments: [best.rawValue, id])
        }
    }
}

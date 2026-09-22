import GRDB

func registerCategoryMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createCategory") { db in
        try db.create(table: "category") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull().unique()
            t.column("type", .text).notNull()
        }
    }
}

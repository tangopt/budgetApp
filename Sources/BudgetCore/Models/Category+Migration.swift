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

func registerCategoryGroupIdMigration(_ migrator: inout DatabaseMigrator) {
    // No `.references("categoryGroup")` here: every other foreign key in this codebase
    // declares its reference inside a `create(table:)` block (see BalanceSnapshot.swift,
    // Transaction.swift, etc.) — there's no existing precedent for adding a foreign-key
    // constraint via `alter(table:)`, and SQLite's ALTER TABLE ADD COLUMN has enough
    // historical restrictions around constraints that it's not worth the risk for a
    // column the app never needs the database itself to enforce. `groupId` is a plain
    // nullable reference to `categoryGroup.id`, validated at the application layer
    // (`CategoriesViewModel` only ever assigns an id it just read from `CategoryGroup`).
    migrator.registerMigration("addCategoryGroupIdToCategory") { db in
        try db.alter(table: "category") { t in
            t.add(column: "groupId", .integer)
        }
    }
}

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

func registerCategoryCatchAllMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("addIsCatchAllToCategory") { db in
        try db.alter(table: "category") { t in
            t.add(column: "isCatchAll", .boolean).notNull().defaults(to: false)
        }
    }
}

func registerCategoryReservedMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("addReservedCategoryFlags") { db in
        try db.alter(table: "category") { t in
            t.add(column: "isReserved", .boolean).notNull().defaults(to: false)
            t.add(column: "excludeFromAutoForecast", .boolean).notNull().defaults(to: false)
        }
        // A reserve is forecast-only: no transaction or rule may point at it.
        for table in ["transaction_", "rule"] {
            try db.execute(sql: """
                CREATE TRIGGER \(table)_reserved_insert BEFORE INSERT ON \(table)
                WHEN NEW.categoryId IS NOT NULL AND (SELECT isReserved FROM category WHERE id = NEW.categoryId) = 1
                BEGIN SELECT RAISE(ABORT, 'Reserved categories can''t hold transactions.'); END;
                """)
            try db.execute(sql: """
                CREATE TRIGGER \(table)_reserved_update BEFORE UPDATE OF categoryId ON \(table)
                WHEN NEW.categoryId IS NOT NULL AND (SELECT isReserved FROM category WHERE id = NEW.categoryId) = 1
                BEGIN SELECT RAISE(ABORT, 'Reserved categories can''t hold transactions.'); END;
                """)
        }
    }
}

func registerCategoryDropCatchAllMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("dropCatchAll") { db in
        // The catch-all's job ("keep my allowance; never auto-forecast me") is now
        // `excludeFromAutoForecast`; reserves replace the single bulk allowance.
        try db.execute(sql: "UPDATE category SET excludeFromAutoForecast = 1 WHERE isCatchAll = 1")
        try db.alter(table: "category") { t in t.drop(column: "isCatchAll") }
    }
}

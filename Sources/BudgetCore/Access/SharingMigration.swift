import Foundation
import GRDB

/// Step 6's storage (sharing spec 2026-10-25 §3): account ownership and levels, per-person sharing,
/// member permissions, the summary tables the household zone gets for accounts below Everything, and the
/// local sync bookkeeping the private zones need. One migration; every statement is guarded, so running
/// the body again changes nothing.
enum SharingMigration {
    static let identifier = "sharingLevels"

    static func apply(db: Database) throws {
        // Every existing account stays joint and at Everything until the ownership sheet: no value changes.
        let accountColumns = Set(try db.columns(in: "account").map(\.name))
        if !accountColumns.contains("ownerPersonId") {
            try db.alter(table: "account") { t in
                t.add(column: "ownerPersonId", .integer).references("person", onDelete: .restrict)
            }
        }
        if !accountColumns.contains("sharingLevel") {
            try db.alter(table: "account") { t in
                t.add(column: "sharingLevel", .text).notNull().defaults(to: SharingLevel.everything.rawValue)
                    .check { ["everything", "categoryTotals", "balanceOnly", "hidden"].contains($0) }
            }
        }

        try db.create(table: "personSharing", options: .ifNotExists) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("personId", .integer).notNull().unique().references("person", onDelete: .cascade)
            t.column("taxIncomeLevel", .text).notNull().defaults(to: TaxIncomeLevel.everything.rawValue)
                .check { ["everything", "hidden"].contains($0) }
            t.column("ownershipConfirmedAt", .datetime)
        }
        try db.create(table: "memberPermission", options: .ifNotExists) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("appUserId", .integer).notNull().references("appUser", onDelete: .cascade)
            t.column("area", .text).notNull()
            t.column("level", .text).notNull().check { ["none", "view", "edit"].contains($0) }
            t.uniqueKey(["appUserId", "area"])
        }
        try db.create(table: "accountBalancePoint", options: .ifNotExists) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("accountId", .integer).notNull().references("account", onDelete: .cascade)
            t.column("payMonth", .text).notNull()
            t.column("date", .date).notNull()
            t.column("balanceMinorUnits", .integer).notNull()
            t.uniqueKey(["accountId", "payMonth"])
        }
        try db.create(table: "accountSummaryMonth", options: .ifNotExists) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("accountId", .integer).notNull().references("account", onDelete: .cascade)
            t.column("payMonth", .text).notNull()
            t.column("categoryId", .integer).references("category", onDelete: .cascade)
            t.column("amountMinorUnits", .integer).notNull()
            t.column("transactionCount", .integer).notNull()
            t.uniqueKey(["accountId", "payMonth", "categoryId"])
        }

        // Local only. The write origin the triggers copy from `syncWriter` into `syncRecord`.
        if !(try db.columns(in: "syncRecord").map(\.name).contains("origin")) {
            try db.alter(table: "syncRecord") { t in t.add(column: "origin", .text) }
        }
        if !(try db.columns(in: "syncWriter").map(\.name).contains("origin")) {
            try db.alter(table: "syncWriter") { t in t.add(column: "origin", .text) }
        }
        // Move markers: a record's old copy in the zone it moved out of (`pending` until the marker is saved).
        try db.create(table: "syncZoneMove", options: .ifNotExists) { t in
            t.column("uuid", .text).notNull()
            t.column("zone", .text).notNull()
            t.column("tableName", .text).notNull()
            t.column("systemFields", .blob)
            t.column("pending", .integer).notNull().defaults(to: 1)
            t.primaryKey(["uuid", "zone"])
        }
        // Server stamps of companion records (an `accountDetails` record beside a household account stub).
        try db.create(table: "syncCompanion", options: .ifNotExists) { t in
            t.column("recordType", .text).notNull()
            t.column("uuid", .text).notNull()
            t.column("zone", .text).notNull()
            t.column("systemFields", .blob)
            t.column("changeTag", .text)
            t.primaryKey(["recordType", "uuid"])
        }
        // The log of incoming changes reverted on apply because the writer had no permission for them.
        try db.create(table: "syncAccessRevert", options: .ifNotExists) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("at", .datetime).notNull()
            t.column("writerAppUserUuid", .text)
            t.column("area", .text).notNull()
            t.column("tableName", .text).notNull()
            t.column("uuid", .text).notNull()
            t.column("fields", .text).notNull()
        }
    }
}

func registerSharingMigration(_ migrator: inout DatabaseMigrator) {
    // Adds columns (NULL owner, Everything) and tables only: no existing value changes.
    migrator.registerMigration(SharingMigration.identifier) { db in
        try SharingMigration.apply(db: db)
    }
}

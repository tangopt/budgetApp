import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Step 6 task 2: Layer 2 permissions, the actors that write, write origins and the area each change needs.
final class AccessPolicyTests: XCTestCase {
    private static let day = Date(timeIntervalSince1970: 1_790_000_000)

    private struct Household {
        var adminPersonId: Int64
        var memberPersonId: Int64
        var admin: AccessActor
        var member: AccessActor
    }

    /// Two synthetic people, each with an app user; the first is the admin.
    private func household(_ db: Database) throws -> Household {
        try db.execute(sql: "INSERT INTO person(name) VALUES ('Synthetic Admin')")
        let adminPersonId = db.lastInsertedRowID
        try db.execute(sql: "INSERT INTO person(name) VALUES ('Synthetic Member')")
        let memberPersonId = db.lastInsertedRowID
        var admin = AppUser(personId: adminPersonId, displayName: "Admin", isAdmin: true, createdAt: Self.day)
        try admin.insert(db)
        var member = AppUser(personId: memberPersonId, displayName: "Member", isAdmin: false, createdAt: Self.day)
        try member.insert(db)
        return Household(adminPersonId: adminPersonId, memberPersonId: memberPersonId,
                         admin: try AccessActor.load(appUserId: admin.id!, db: db),
                         member: try AccessActor.load(appUserId: member.id!, db: db))
    }

    private func personUuid(_ id: Int64, _ db: Database) throws -> String {
        try SyncRecordStore.uuid(for: "person", localId: id, db: db)
    }

    private func insertAccount(_ db: Database, owner: Int64? = nil, level: SharingLevel = .everything) throws -> Int64 {
        var account = Account(name: "Synthetic \(UUID().uuidString.prefix(6))", currency: .gbp, kind: .cash, trackingMode: .imported)
        account.ownerPersonId = owner
        account.sharingLevel = level
        try account.insert(db)
        return account.id!
    }

    private func writer(_ db: Database) throws -> Row? {
        try Row.fetchOne(db, sql: "SELECT appUserUuid, origin FROM syncWriter WHERE id = 1")
    }

    // MARK: Levels

    func testEveryAreaAndLevelForAdminAndMember() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            let areas: [AccessArea] = AccessArea.fixedAreas + [.tax(personUuid: try personUuid(h.adminPersonId, db)),
                                                               .tax(personUuid: try personUuid(h.memberPersonId, db))]
            XCTAssertEqual(areas.count, 9)
            let memberEdits: Set<String> = ["documents", "import", "property"]
            for area in areas {
                XCTAssertTrue(try AccessPolicy.can(h.admin, .view, area, db: db), "admin view \(area)")
                XCTAssertTrue(try AccessPolicy.can(h.admin, .edit, area, db: db), "admin edit \(area)")
                XCTAssertTrue(try AccessPolicy.can(h.member, .view, area, db: db), "member view \(area)")
                XCTAssertEqual(try AccessPolicy.can(h.member, .edit, area, db: db), memberEdits.contains(area.storageKey), "member edit \(area)")
                XCTAssertEqual(MemberPermissions.defaultLevel(area, isAdmin: true), .edit)
                XCTAssertEqual(MemberPermissions.defaultLevel(area, isAdmin: false), memberEdits.contains(area.storageKey) ? .edit : .view)
                XCTAssertEqual(AccessArea(storageKey: area.storageKey), area)
            }
            XCTAssertEqual(areas.map(\.title), ["Budget & accounts", "Property", "Forecast", "Documents", "Import",
                                                "Rules & categories", "Household settings", "Tax", "Tax"])
            XCTAssertNil(AccessArea(storageKey: "tax:"))
            XCTAssertNil(AccessArea(storageKey: "somethingElse"))
            XCTAssertTrue(PermissionLevel.none < .view && PermissionLevel.view < .edit)
        }
    }

    func testStoredRowOverridesDefault() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            XCTAssertTrue(try AccessPolicy.can(h.member, .view, .forecast, db: db))
            var row = MemberPermission(appUserId: h.member.appUserId, area: AccessArea.forecast.storageKey, level: .none)
            try row.insert(db)
            XCTAssertFalse(try AccessPolicy.can(h.member, .view, .forecast, db: db))
            XCTAssertFalse(try AccessPolicy.can(h.member, .edit, .forecast, db: db))
            // Raising one too.
            var budget = MemberPermission(appUserId: h.member.appUserId, area: AccessArea.budgetAndAccounts.storageKey, level: .edit)
            try budget.insert(db)
            XCTAssertTrue(try AccessPolicy.can(h.member, .edit, .budgetAndAccounts, db: db))
        }
    }

    func testOnlyTheOwnerSetsALevel() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            let memberOwned = try insertAccount(db, owner: h.memberPersonId, level: .balanceOnly)
            let joint = try insertAccount(db, owner: nil)
            let adminOwned = try insertAccount(db, owner: h.adminPersonId, level: .balanceOnly)
            XCTAssertFalse(try AccessPolicy.canSetLevel(h.admin, accountId: memberOwned, db: db))
            XCTAssertFalse(try AccessPolicy.canSetLevel(h.admin, accountId: joint, db: db))
            XCTAssertFalse(try AccessPolicy.canSetLevel(h.member, accountId: joint, db: db))
            XCTAssertTrue(try AccessPolicy.canSetLevel(h.member, accountId: memberOwned, db: db))
            XCTAssertTrue(try AccessPolicy.canSetLevel(h.admin, accountId: adminOwned, db: db))
            XCTAssertFalse(try AccessPolicy.canSetLevel(h.member, accountId: adminOwned, db: db))
            XCTAssertFalse(try AccessPolicy.canSetLevel(h.admin, accountId: 999_999, db: db))
        }
    }

    // MARK: Area map

    func testEverySyncedTableHasAnArea() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            let adminTax = AccessArea.tax(personUuid: try personUuid(h.adminPersonId, db))
            for table in SyncSchema.tables.map(\.name) {
                let fields = Set(SyncSchema.table(table)!.syncedColumns)
                let area = try AccessAreaMap.area(table: table, origin: .edit, changedFields: fields, row: [:], db: db)
                XCTAssertTrue(area != nil || AccessAreaMap.isOwnerOnly(table: table, fields: fields), "\(table) has no area")
                // A tax row that names no person is the admin's tax.
                if case .tax? = area { XCTAssertEqual(area, adminTax, table) }
            }
            XCTAssertEqual(try AccessAreaMap.area(table: "rechargeNettingRule", origin: nil, changedFields: ["mode"], row: [:], db: db),
                           .householdSettings)
            XCTAssertEqual(try AccessAreaMap.area(table: "rechargeLine", origin: nil, changedFields: ["note"], row: [:], db: db), .property)
            XCTAssertEqual(try AccessAreaMap.area(table: "evidenceWaiver", origin: nil, changedFields: ["note"], row: [:], db: db), .property)
            XCTAssertNil(try AccessAreaMap.area(table: "notASyncedTable", origin: nil, changedFields: [], row: [:], db: db))
            XCTAssertTrue(AccessAreaMap.isOwnerOnly(table: "accountSummaryMonth", fields: ["amountMinorUnits"]))
            XCTAssertTrue(AccessAreaMap.isOwnerOnly(table: "account", fields: ["sharingLevel"]))
            XCTAssertFalse(AccessAreaMap.isOwnerOnly(table: "account", fields: ["name"]))
        }
    }

    func testAreaFollowsOriginFirst() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            _ = try household(db)
            XCTAssertEqual(try AccessAreaMap.area(table: "transaction_", origin: .import, changedFields: ["amountMinorUnits"], row: [:], db: db), .import)
            XCTAssertEqual(try AccessAreaMap.area(table: "rechargePayment", origin: .propertyMatching, changedFields: ["transactionId"], row: [:], db: db), .property)
            XCTAssertEqual(try AccessAreaMap.area(table: "documentLink", origin: .documentLink, changedFields: ["entityId"], row: [:], db: db), .documents)
            XCTAssertEqual(try AccessAreaMap.area(table: "transaction_", origin: .system, changedFields: ["amountMinorUnits"], row: [:], db: db), .budgetAndAccounts)
        }
    }

    func testTaxRowIsItsPersonsTax() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            let memberUuid = try personUuid(h.memberPersonId, db)
            try db.execute(sql: "INSERT INTO employment(startYear, personId, employerName) VALUES (2024, ?, 'Synthetic Employer')",
                           arguments: [h.memberPersonId])
            let employmentId = db.lastInsertedRowID
            let employmentUuid = try SyncRecordStore.uuid(for: "employment", localId: employmentId, db: db)
            XCTAssertEqual(try AccessAreaMap.area(table: "taxYear", origin: .edit, changedFields: ["notes"],
                                                  row: ["personId": .string(memberUuid)], db: db), .tax(personUuid: memberUuid))
            XCTAssertEqual(try AccessAreaMap.area(table: "taxYear", origin: .edit, changedFields: ["notes"],
                                                  row: ["personId": .int(h.memberPersonId)], db: db), .tax(personUuid: memberUuid))
            XCTAssertEqual(try AccessAreaMap.area(table: "employmentIncome", origin: .edit, changedFields: ["notes"],
                                                  row: ["employmentId": .string(employmentUuid)], db: db), .tax(personUuid: memberUuid))
        }
    }

    /// A property category's transaction, in an account below Everything that no property links to.
    private func propertyCategoryTransaction(_ db: Database, owner: Int64) throws -> (transactionId: Int64, accountId: Int64, propertyCategory: Int64, otherCategory: Int64) {
        try db.execute(sql: "INSERT INTO property(name, country) VALUES ('Synthetic flat', 'PT')")
        let propertyId = db.lastInsertedRowID
        try db.execute(sql: "INSERT INTO categoryGroup(name) VALUES ('Synthetic flat costs')")
        let groupId = db.lastInsertedRowID
        try db.execute(sql: "INSERT INTO propertyCategoryGroup(propertyId, categoryGroupId) VALUES (?, ?)", arguments: [propertyId, groupId])
        try db.execute(sql: "INSERT INTO category(name, type, groupId) VALUES ('Synthetic flat repairs', 'expense', ?)", arguments: [groupId])
        let propertyCategory = db.lastInsertedRowID
        try db.execute(sql: "INSERT INTO category(name, type) VALUES ('Synthetic groceries', 'expense')")
        let otherCategory = db.lastInsertedRowID
        let accountId = try insertAccount(db, owner: owner, level: .balanceOnly)
        var batch = ImportBatch(accountId: accountId, sourceFileName: "synthetic.csv", importedAt: Self.day)
        try batch.insert(db)
        var t = Transaction(importBatchId: batch.id!, accountId: accountId, date: Self.day, rawDescription: "Synthetic repair",
                            amountMinorUnits: -12_000, categoryId: propertyCategory, status: .pendingReview, categorizedBy: .none,
                            fingerprint: "fp-synthetic", note: nil, isManual: false)
        try t.insert(db)
        return (t.id!, accountId, propertyCategory, otherCategory)
    }

    func testPropertyNoteOnPropertyCategoryTransactionIsProperty() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            let fixture = try propertyCategoryTransaction(db, owner: h.adminPersonId)
            let accountUuid = try SyncRecordStore.uuid(for: "account", localId: fixture.accountId, db: db)
            let categoryUuid = try SyncRecordStore.uuid(for: "category", localId: fixture.propertyCategory, db: db)
            let otherUuid = try SyncRecordStore.uuid(for: "category", localId: fixture.otherCategory, db: db)
            // As a payload carries it: references are UUIDs.
            let payloadRow: [String: SyncValue] = ["accountId": .string(accountUuid), "categoryId": .string(categoryUuid), "note": .string("Plumber")]
            XCTAssertEqual(try AccessAreaMap.area(table: "transaction_", origin: .edit, changedFields: ["note"], row: payloadRow, db: db), .property)
            // As local ids.
            let localRow: [String: SyncValue] = ["accountId": .int(fixture.accountId), "categoryId": .int(fixture.propertyCategory)]
            XCTAssertEqual(try AccessAreaMap.area(table: "transaction_", origin: nil, changedFields: ["categoryId", "categorizedBy", "status"],
                                                  row: localRow, db: db), .property)
            // Moved out of the property category: the category before the change counts.
            let movedOut: [String: SyncValue] = ["accountId": .string(accountUuid), "categoryId": .string(otherUuid)]
            XCTAssertEqual(try AccessAreaMap.area(table: "transaction_", origin: .edit, changedFields: ["categoryId"], row: movedOut,
                                                  before: payloadRow, db: db), .property)
            XCTAssertEqual(try AccessAreaMap.area(table: "transaction_", origin: .edit, changedFields: ["categoryId"], row: movedOut, db: db),
                           .budgetAndAccounts)
        }
    }

    func testNoteOnEverythingPropertyAccountIsProperty() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            try db.execute(sql: "INSERT INTO property(name, country) VALUES ('Synthetic flat', 'PT')")
            let propertyId = db.lastInsertedRowID
            let linked = try insertAccount(db, owner: h.adminPersonId, level: .everything)
            try db.execute(sql: "INSERT INTO propertyAccount(propertyId, accountId, role) VALUES (?, ?, 'rent')", arguments: [propertyId, linked])
            let row: [String: SyncValue] = ["accountId": .int(linked), "categoryId": .null]
            XCTAssertEqual(try AccessAreaMap.area(table: "transaction_", origin: .edit, changedFields: ["note"], row: row, db: db), .property)
            // The same account below Everything isn't.
            try db.execute(sql: "UPDATE account SET sharingLevel = 'balanceOnly' WHERE id = ?", arguments: [linked])
            XCTAssertEqual(try AccessAreaMap.area(table: "transaction_", origin: .edit, changedFields: ["note"], row: row, db: db), .budgetAndAccounts)
        }
    }

    func testAmountEditIsBudgetAndAccounts() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            let fixture = try propertyCategoryTransaction(db, owner: h.adminPersonId)
            let row: [String: SyncValue] = ["accountId": .int(fixture.accountId), "categoryId": .int(fixture.propertyCategory)]
            XCTAssertEqual(try AccessAreaMap.area(table: "transaction_", origin: .edit, changedFields: ["amountMinorUnits"], row: row, db: db),
                           .budgetAndAccounts)
            XCTAssertEqual(try AccessAreaMap.area(table: "transaction_", origin: .edit, changedFields: ["note", "amountMinorUnits"], row: row, db: db),
                           .budgetAndAccounts)
        }
    }

    // MARK: ActorWrite

    func testPerformRefusesWithoutEditAndRestoresWriter() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            try SyncChangeTracker.setWriter("previous-writer", origin: nil, db: db)
            var ran = false
            XCTAssertThrowsError(try ActorWrite.perform(h.member, area: .budgetAndAccounts, db: db) { ran = true }) { error in
                XCTAssertEqual(error as? AccessDenied, AccessDenied(area: .budgetAndAccounts))
                XCTAssertEqual(error.localizedDescription, "You can't change Budget & accounts in this household.")
            }
            XCTAssertFalse(ran)
            XCTAssertEqual(try writer(db)?["appUserUuid"] as String?, "previous-writer")
            XCTAssertNil(try writer(db)?["origin"] as String?)

            // A permitted body that throws also leaves the previous writer.
            struct Boom: Error {}
            XCTAssertThrowsError(try ActorWrite.perform(h.member, area: .documents, db: db) {
                XCTAssertEqual(try self.writer(db)?["appUserUuid"] as String?, h.member.appUserUuid)
                XCTAssertEqual(try self.writer(db)?["origin"] as String?, "edit")
                throw Boom()
            })
            XCTAssertEqual(try writer(db)?["appUserUuid"] as String?, "previous-writer")
            XCTAssertNil(try writer(db)?["origin"] as String?)
        }
    }

    func testPerformStampsOriginOnWrittenRows() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            let accountId = try ActorWrite.perform(h.admin, area: .import, origin: .import, db: db) {
                try insertAccount(db)
            }
            let record = try Row.fetchOne(db, sql: "SELECT origin, modifiedBy FROM syncRecord WHERE tableName = 'account' AND localId = ?",
                                          arguments: [accountId])
            XCTAssertEqual(record?["origin"] as String?, "import")
            XCTAssertEqual(record?["modifiedBy"] as String?, h.admin.appUserUuid)

            // Nested: an inner edit keeps the outer origin; an inner matching replaces it, then the outer is back.
            try ActorWrite.perform(h.member, area: .import, origin: .import, db: db) {
                try ActorWrite.perform(h.member, area: .documents, db: db) {
                    XCTAssertEqual(try self.writer(db)?["origin"] as String?, "import")
                }
                try ActorWrite.perform(h.member, area: .property, origin: .propertyMatching, db: db) {
                    XCTAssertEqual(try self.writer(db)?["origin"] as String?, "propertyMatching")
                }
                XCTAssertEqual(try self.writer(db)?["origin"] as String?, "import")
            }
            XCTAssertNil(try writer(db)?["origin"] as String?)
        }
    }

    // MARK: Defaults

    func testEnsureDefaultsWritesOnceAndKeepsChanges() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            try MemberPermissions.ensureDefaults(appUserId: h.member.appUserId, db: db)
            let rows = try MemberPermission.filter(Column("appUserId") == h.member.appUserId).fetchAll(db)
            XCTAssertEqual(rows.count, 9, "seven fixed areas and one tax area per person")
            for row in rows {
                let area = try XCTUnwrap(AccessArea(storageKey: row.area), row.area)
                XCTAssertEqual(row.level, MemberPermissions.defaultLevel(area, isAdmin: false), row.area)
            }
            try db.execute(sql: "UPDATE memberPermission SET level = 'none' WHERE appUserId = ? AND area = 'forecast'",
                           arguments: [h.member.appUserId])
            try MemberPermissions.ensureDefaults(appUserId: h.member.appUserId, db: db)
            XCTAssertEqual(try MemberPermission.filter(Column("appUserId") == h.member.appUserId).fetchCount(db), 9)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT level FROM memberPermission WHERE appUserId = ? AND area = 'forecast'",
                                               arguments: [h.member.appUserId]), "none")
            XCTAssertFalse(try AccessPolicy.can(h.member, .view, .forecast, db: db))

            // A person added later gets their tax row on the next run.
            try db.execute(sql: "INSERT INTO person(name) VALUES ('Synthetic Third')")
            try MemberPermissions.ensureDefaults(appUserId: h.member.appUserId, db: db)
            XCTAssertEqual(try MemberPermission.filter(Column("appUserId") == h.member.appUserId).fetchCount(db), 10)
        }
    }

    func testAdminActorIsTheFirstAdmin() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            XCTAssertThrowsError(try AccessActor.admin(db: db)) { XCTAssertEqual($0 as? AccessActorError, .noAdmin) }
            let h = try household(db)
            XCTAssertEqual(try AccessActor.admin(db: db), h.admin)
            XCTAssertTrue(h.admin.isAdmin)
            XCTAssertFalse(h.member.isAdmin)
            XCTAssertEqual(h.member.personId, h.memberPersonId)
            XCTAssertEqual(h.admin.appUserUuid, try SyncRecordStore.uuid(for: "appUser", localId: h.admin.appUserId, db: db))
        }
    }
}

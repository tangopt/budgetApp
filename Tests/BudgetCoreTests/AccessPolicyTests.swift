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

    func testAdminIsNeverLockedOut() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            for area in [AccessArea.budgetAndAccounts, .householdSettings] {
                var row = MemberPermission(appUserId: h.admin.appUserId, area: area.storageKey, level: .none)
                try row.insert(db)
                XCTAssertTrue(try AccessPolicy.can(h.admin, .edit, area, db: db), area.storageKey)
                XCTAssertEqual(try AccessPolicy.level(h.admin, area, db: db), .edit)
            }
            try db.execute(sql: "DELETE FROM memberPermission")
            try MemberPermissions.ensureDefaults(appUserId: h.admin.appUserId, db: db)
            XCTAssertEqual(try MemberPermission.fetchCount(db), 0, "no rows for the admin")
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

    private func decide(_ table: String, origin: WriteOrigin? = .edit, change: AccessChange = .insert, fields: Set<String>,
                        row: [String: SyncValue] = [:], _ db: Database) throws -> AccessDecision {
        try AccessAreaMap.area(table: table, origin: origin, change: change, changedFields: fields, row: row, db: db)
    }

    func testEverySyncedTableHasAnArea() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            let adminTax = AccessArea.tax(personUuid: try personUuid(h.adminPersonId, db))
            for table in SyncSchema.tables.map(\.name) {
                let fields = Set(SyncSchema.table(table)!.syncedColumns)
                let decision = try decide(table, fields: fields, db)
                XCTAssertTrue(decision != .denied || AccessAreaMap.isOwnerOnly(table: table, fields: fields), "\(table) has no area")
                // A tax row that names no person is the admin's tax.
                if case .area(.tax) = decision { XCTAssertEqual(decision, .area(adminTax), table) }
            }
            XCTAssertEqual(try decide("rechargeNettingRule", origin: nil, fields: ["mode"], db), .area(.householdSettings))
            XCTAssertEqual(try decide("rechargeLine", origin: nil, fields: ["note"], db), .area(.property))
            XCTAssertEqual(try decide("evidenceWaiver", origin: nil, fields: ["note"], db), .area(.property))
            XCTAssertTrue(AccessAreaMap.isOwnerOnly(table: "accountSummaryMonth", fields: ["amountMinorUnits"]))
            XCTAssertTrue(AccessAreaMap.isOwnerOnly(table: "account", fields: ["sharingLevel"]))
            XCTAssertTrue(AccessAreaMap.isOwnerOnly(table: "personSharing", fields: ["taxIncomeLevel"]))
            XCTAssertFalse(AccessAreaMap.isOwnerOnly(table: "account", fields: ["name"]))
        }
    }

    func testUnknownTableIsDeniedWhateverTheOrigin() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            for origin in [WriteOrigin.edit, .import, .propertyMatching, .documentLink, .system] {
                XCTAssertEqual(try decide("notASyncedTable", origin: origin, fields: ["x"], db), .denied, origin.rawValue)
            }
            XCTAssertFalse(try AccessPolicy.allows(h.admin, .denied, db: db))
        }
    }

    func testOriginCountsOnlyForTheTablesItWrites() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            let memberTax = AccessArea.tax(personUuid: try personUuid(h.memberPersonId, db))
            let cases: [(String, Set<String>, [String: SyncValue], AccessDecision)] = [
                ("memberPermission", ["level"], [:], .area(.householdSettings)),
                ("appUser", ["isAdmin"], [:], .area(.householdSettings)),
                ("person", ["name"], [:], .area(.householdSettings)),
                ("category", ["name"], [:], .area(.rulesAndCategories)),
                ("taxYear", ["notes"], ["personId": .int(h.memberPersonId)], .area(memberTax)),
            ]
            for origin in [WriteOrigin.import, .propertyMatching, .documentLink] {
                for (table, fields, row, expected) in cases {
                    let decision = try decide(table, origin: origin, fields: fields, row: row, db)
                    XCTAssertEqual(decision, expected, "\(table) under \(origin)")
                    XCTAssertFalse(try AccessPolicy.allows(h.member, decision, db: db), "\(table) under \(origin)")
                }
            }
            // The tables an import writes count as Import.
            for table in ["transaction_", "importBatch", "transferLink", "balanceSnapshot", "importRun"] {
                let decision = try decide(table, origin: .import, fields: ["amountMinorUnits"], db)
                XCTAssertEqual(decision, .area(.import), table)
                XCTAssertTrue(try AccessPolicy.allows(h.member, decision, db: db), table)
            }
            // An import's statement check on an account, but nothing else of it.
            XCTAssertEqual(try decide("account", origin: .import, change: .update(before: [:]), fields: ["statementLastCheckedDate"], db),
                           .area(.import))
            XCTAssertEqual(try decide("account", origin: .import, change: .update(before: [:]), fields: ["name"], db),
                           .area(.budgetAndAccounts))
            // Matching and document links on their own tables.
            XCTAssertEqual(try decide("rechargePayment", origin: .propertyMatching, fields: ["transactionId"], db), .area(.property))
            XCTAssertEqual(try decide("documentLink", origin: .documentLink, fields: ["entityId"], db), .area(.documents))
            XCTAssertEqual(try decide("transaction_", origin: .system, change: .update(before: [:]), fields: ["amountMinorUnits"], db),
                           .area(.budgetAndAccounts))
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
            XCTAssertEqual(try decide("taxYear", fields: ["notes"], row: ["personId": .string(memberUuid)], db), .area(.tax(personUuid: memberUuid)))
            XCTAssertEqual(try decide("taxYear", fields: ["notes"], row: ["personId": .int(h.memberPersonId)], db), .area(.tax(personUuid: memberUuid)))
            XCTAssertEqual(try decide("employmentIncome", fields: ["notes"], row: ["employmentId": .string(employmentUuid)], db),
                           .area(.tax(personUuid: memberUuid)))
        }
    }

    func testRepointingATaxRowNeedsBothPeople() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            let memberTax = AccessArea.tax(personUuid: try personUuid(h.memberPersonId, db))
            let adminTax = AccessArea.tax(personUuid: try personUuid(h.adminPersonId, db))
            // The member may edit their own tax.
            var own = MemberPermission(appUserId: h.member.appUserId, area: memberTax.storageKey, level: .edit)
            try own.insert(db)
            let notes = try decide("taxYear", change: .update(before: ["personId": .int(h.memberPersonId)]), fields: ["notes"],
                                   row: ["personId": .int(h.memberPersonId)], db)
            XCTAssertEqual(notes, .area(memberTax))
            XCTAssertTrue(try AccessPolicy.allows(h.member, notes, db: db))
            // Taking the admin's row (or giving theirs to the admin) needs both.
            for (before, after) in [(h.adminPersonId, h.memberPersonId), (h.memberPersonId, h.adminPersonId)] {
                let decision = try decide("taxYear", change: .update(before: ["personId": .int(before)]), fields: ["personId"],
                                          row: ["personId": .int(after)], db)
                XCTAssertEqual(Set(decision.areas), [memberTax, adminTax])
                XCTAssertFalse(try AccessPolicy.allows(h.member, decision, db: db))
                XCTAssertTrue(try AccessPolicy.allows(h.admin, decision, db: db))
            }
        }
    }

    func testATransactionSplitBetweenOwnersNeedsEveryOwner() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            let fixture = try propertyCategoryTransaction(db, owner: h.adminPersonId)
            for person in [h.adminPersonId, h.memberPersonId] {
                try db.execute(sql: "INSERT INTO propertyOwner(propertyId, personId, shareBasisPoints) VALUES (?, ?, 5000)",
                               arguments: [fixture.propertyId, person])
            }
            let memberTax = AccessArea.tax(personUuid: try personUuid(h.memberPersonId, db))
            let adminTax = AccessArea.tax(personUuid: try personUuid(h.adminPersonId, db))
            let decision = try decide("taxNotClaimed", fields: ["notes"], row: ["transactionId": .int(fixture.transactionId)], db)
            XCTAssertEqual(Set(decision.areas), [memberTax, adminTax])
            let receipt = try decide("taxPolicyReceipt", fields: ["notes"], row: ["propertyId": .int(fixture.propertyId)], db)
            XCTAssertEqual(Set(receipt.areas), [memberTax, adminTax])
            // Once the transaction has one owner, it is theirs alone.
            try db.execute(sql: "INSERT INTO taxTransactionOwner(transactionId, personId) VALUES (?, ?)",
                           arguments: [fixture.transactionId, h.memberPersonId])
            XCTAssertEqual(try decide("taxNotClaimed", fields: ["notes"], row: ["transactionId": .int(fixture.transactionId)], db),
                           .area(memberTax))
        }
    }

    /// A property category's transaction, in an account below Everything that no property links to.
    private func propertyCategoryTransaction(_ db: Database, owner: Int64)
        throws -> (transactionId: Int64, accountId: Int64, propertyId: Int64, propertyCategory: Int64, otherCategory: Int64) {
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
        return (t.id!, accountId, propertyId, propertyCategory, otherCategory)
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
            let property: [String: SyncValue] = ["accountId": .string(accountUuid), "categoryId": .string(categoryUuid), "note": .string("Plumber")]
            let noted = try decide("transaction_", change: .update(before: property), fields: ["note"], row: property, db)
            XCTAssertEqual(noted, .area(.property))
            XCTAssertTrue(try AccessPolicy.allows(h.member, noted, db: db))
            // As local ids.
            let local: [String: SyncValue] = ["accountId": .int(fixture.accountId), "categoryId": .int(fixture.propertyCategory)]
            XCTAssertEqual(try decide("transaction_", origin: nil, change: .update(before: local), fields: ["categoryId", "categorizedBy", "status"],
                                      row: local, db), .area(.property))
            // Moved out of the property category: allowed, the transaction was property money.
            let movedOut: [String: SyncValue] = ["accountId": .string(accountUuid), "categoryId": .string(otherUuid)]
            let out = try decide("transaction_", change: .update(before: property), fields: ["categoryId"], row: movedOut, db)
            XCTAssertEqual(out, .area(.property))
            XCTAssertTrue(try AccessPolicy.allows(h.member, out, db: db))
        }
    }

    func testMovingATransactionIntoAPropertyCategoryIsBudgetAndAccounts() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            let fixture = try propertyCategoryTransaction(db, owner: h.adminPersonId)
            let groceries: [String: SyncValue] = ["accountId": .int(fixture.accountId), "categoryId": .int(fixture.otherCategory)]
            let property: [String: SyncValue] = ["accountId": .int(fixture.accountId), "categoryId": .int(fixture.propertyCategory)]
            let moveIn = try decide("transaction_", change: .update(before: groceries), fields: ["categoryId"], row: property, db)
            XCTAssertEqual(moveIn, .area(.budgetAndAccounts))
            XCTAssertFalse(try AccessPolicy.allows(h.member, moveIn, db: db))
            // An insert grants nothing from its category either.
            XCTAssertEqual(try decide("transaction_", change: .insert, fields: ["categoryId", "note"], row: property, db), .area(.budgetAndAccounts))
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
            XCTAssertEqual(try decide("transaction_", change: .update(before: row), fields: ["note"], row: row, db), .area(.property))
            // The same account below Everything isn't.
            try db.execute(sql: "UPDATE account SET sharingLevel = 'balanceOnly' WHERE id = ?", arguments: [linked])
            XCTAssertEqual(try decide("transaction_", change: .update(before: row), fields: ["note"], row: row, db), .area(.budgetAndAccounts))
        }
    }

    func testAmountEditIsBudgetAndAccounts() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            let fixture = try propertyCategoryTransaction(db, owner: h.adminPersonId)
            let row: [String: SyncValue] = ["accountId": .int(fixture.accountId), "categoryId": .int(fixture.propertyCategory)]
            XCTAssertEqual(try decide("transaction_", change: .update(before: row), fields: ["amountMinorUnits"], row: row, db),
                           .area(.budgetAndAccounts))
            XCTAssertEqual(try decide("transaction_", change: .update(before: row), fields: ["note", "amountMinorUnits"], row: row, db),
                           .area(.budgetAndAccounts))
        }
    }

    func testLevelsAndSummariesAreTheOwnersAlone() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            let memberOwned = try insertAccount(db, owner: h.memberPersonId, level: .balanceOnly)
            let joint = try insertAccount(db, owner: nil)
            let level = try decide("account", change: .update(before: ["ownerPersonId": .int(h.memberPersonId)]), fields: ["sharingLevel"],
                                   row: ["ownerPersonId": .int(h.memberPersonId), "sharingLevel": .string("hidden")], db)
            XCTAssertEqual(level, .ownerOnly(personId: h.memberPersonId))
            XCTAssertTrue(try AccessPolicy.allows(h.member, level, db: db))
            XCTAssertFalse(try AccessPolicy.allows(h.admin, level, db: db))
            // A joint account's level: nobody.
            XCTAssertEqual(try decide("account", change: .update(before: ["ownerPersonId": .null]), fields: ["sharingLevel"],
                                      row: ["ownerPersonId": .null], db), .denied)
            // A name and a level together need both.
            let mixed = try decide("account", change: .update(before: ["ownerPersonId": .int(h.memberPersonId)]), fields: ["name", "sharingLevel"],
                                   row: ["ownerPersonId": .int(h.memberPersonId)], db)
            XCTAssertFalse(try AccessPolicy.allows(h.member, mixed, db: db), "the member can't rename without Budget & accounts")
            XCTAssertFalse(try AccessPolicy.allows(h.admin, mixed, db: db), "the admin can't set the member's level")
            // Summaries of the member's account.
            let summary = try decide("accountSummaryMonth", origin: .import, fields: ["amountMinorUnits"], row: ["accountId": .int(memberOwned)], db)
            XCTAssertEqual(summary, .ownerOnly(personId: h.memberPersonId))
            XCTAssertEqual(try decide("accountBalancePoint", fields: ["balanceMinorUnits"], row: ["accountId": .int(joint)], db), .denied)
        }
    }

    func testTaxIncomeLevelIsSetOnlyByItsPerson() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            for (person, owner, other) in [(h.memberPersonId, h.member, h.admin), (h.adminPersonId, h.admin, h.member)] {
                let decision = try decide("personSharing", change: .update(before: ["personId": .int(person)]), fields: ["taxIncomeLevel"],
                                          row: ["personId": .int(person), "taxIncomeLevel": .string("hidden")], db)
                XCTAssertEqual(decision, .ownerOnly(personId: person))
                XCTAssertTrue(try AccessPolicy.allows(owner, decision, db: db))
                XCTAssertFalse(try AccessPolicy.allows(other, decision, db: db))
            }
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

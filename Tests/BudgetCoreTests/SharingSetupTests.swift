import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Step 6 task 3: the one-time ownership sheet, default levels, owner-only level changes, what blocks
/// Hidden, and the sharing copy. Synthetic people and accounts only.
final class SharingSetupTests: XCTestCase {
    private static let day = Date(timeIntervalSince1970: 1_790_000_000)

    private struct Household {
        var adminPersonId: Int64
        var memberPersonId: Int64
        var admin: AccessActor
        var member: AccessActor
    }

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

    @discardableResult
    private func addAccount(_ db: Database, _ name: String, bank: String? = nil, owner: AccessActor? = nil) throws -> Int64 {
        let account = try AccountEditing.add(db: db, name: name, currency: .gbp, kind: .cash, openingBalanceEntered: nil, asOf: Self.day,
                                             details: AccountDetails(region: .uk, bankName: bank), owner: owner)
        return account.id!
    }

    private func property(_ db: Database, _ name: String) throws -> Int64 {
        try db.execute(sql: "INSERT INTO property(name, country) VALUES (?, 'PT')", arguments: [name])
        return db.lastInsertedRowID
    }

    private func link(_ db: Database, account: Int64, property: Int64) throws {
        try db.execute(sql: "INSERT INTO propertyAccount(propertyId, accountId, role) VALUES (?, ?, 'current')", arguments: [property, account])
    }

    private func account(_ db: Database, _ id: Int64) throws -> Account { try Account.fetchOne(db, key: id)! }

    /// Every account the admin's own, the named one joint.
    private func confirm(_ h: Household, joint: Int64? = nil, _ db: Database) throws {
        let rows = try SharingSetup.proposal(admin: h.admin, db: db).map { row -> SharingSetup.Row in
            var row = row
            if row.id == joint { row.owner = .joint; row.level = .everything }
            return row
        }
        try SharingSetup.save(rows, admin: h.admin, db: db, now: Self.day)
    }

    // MARK: Ownership sheet

    func testProposalOwnsEverythingAsAdminWithDefaults() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            let personal = try addAccount(db, "Synthetic current", bank: "Synthetic Bank")
            let rental = try addAccount(db, "Synthetic rent account")
            try link(db, account: rental, property: try property(db, "Synthetic flat"))
            XCTAssertFalse(try SharingSetup.isConfirmed(db: db))

            let rows = try SharingSetup.proposal(admin: h.admin, db: db)
            XCTAssertEqual(rows.map(\.id).sorted(), [personal, rental].sorted())
            let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            XCTAssertEqual(byId[personal], SharingSetup.Row(id: personal, displayName: "Synthetic current", bankName: "Synthetic Bank",
                                                            isPropertyLinked: false, owner: .person(h.adminPersonId), level: .balanceOnly))
            XCTAssertEqual(byId[rental], SharingSetup.Row(id: rental, displayName: "Synthetic rent account", bankName: nil,
                                                          isPropertyLinked: true, owner: .person(h.adminPersonId), level: .everything))

            XCTAssertEqual(SharingDefaults.level(ownerPersonId: h.adminPersonId, isPropertyLinked: false), .balanceOnly)
            XCTAssertEqual(SharingDefaults.level(ownerPersonId: h.adminPersonId, isPropertyLinked: true), .everything)
            XCTAssertEqual(SharingDefaults.level(ownerPersonId: nil, isPropertyLinked: false), .everything, "joint")
            XCTAssertEqual(SharingDefaults.taxIncomeLevel, .everything)

            XCTAssertThrowsError(try SharingSetup.proposal(admin: h.member, db: db)) { XCTAssertEqual($0 as? SharingError, .notAdmin) }
        }
    }

    func testSaveWritesOwnersLevelsAndConfirmsOnce() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            let personal = try addAccount(db, "Synthetic current")
            let joint = try addAccount(db, "Synthetic joint")
            let rental = try addAccount(db, "Synthetic rent account")
            try link(db, account: rental, property: try property(db, "Synthetic flat"))
            try SyncChangeTracker.setWriter("previous-writer", origin: nil, db: db)

            try confirm(h, joint: joint, db)

            XCTAssertTrue(try SharingSetup.isConfirmed(db: db))
            XCTAssertEqual(try account(db, personal).ownerPersonId, h.adminPersonId)
            XCTAssertEqual(try account(db, personal).sharingLevel, .balanceOnly)
            XCTAssertNil(try account(db, joint).ownerPersonId)
            XCTAssertEqual(try account(db, joint).sharingLevel, .everything)
            XCTAssertEqual(try account(db, rental).ownerPersonId, h.adminPersonId)
            XCTAssertEqual(try account(db, rental).sharingLevel, .everything)

            let sharing = try PersonSharing.order(Column("personId")).fetchAll(db)
            XCTAssertEqual(sharing.map(\.personId), [h.adminPersonId, h.memberPersonId])
            XCTAssertEqual(sharing.map(\.taxIncomeLevel), [.everything, .everything])
            XCTAssertEqual(sharing.map(\.ownershipConfirmedAt), [Self.day, nil], "confirmed on the admin's row")

            // The member's default permissions are written; the admin gets none.
            let permissions = try MemberPermission.fetchAll(db)
            XCTAssertEqual(permissions.count, AccessArea.fixedAreas.count + 2)
            XCTAssertTrue(permissions.allSatisfy { $0.appUserId == h.member.appUserId })

            // Written as the admin, by hand; the previous writer is back afterwards.
            let record = try Row.fetchOne(db, sql: "SELECT origin, modifiedBy FROM syncRecord WHERE tableName = 'account' AND localId = ?",
                                          arguments: [personal])
            XCTAssertEqual(record?["modifiedBy"] as String?, h.admin.appUserUuid)
            XCTAssertEqual(record?["origin"] as String?, "edit")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT appUserUuid FROM syncWriter WHERE id = 1"), "previous-writer")

            // Once only.
            let again = try SharingSetup.proposal(admin: h.admin, db: db)
            XCTAssertThrowsError(try SharingSetup.save(again, admin: h.admin, db: db, now: Self.day.addingTimeInterval(60))) {
                XCTAssertEqual($0 as? SharingError, .alreadyConfirmed)
            }
            XCTAssertEqual(try PersonSharing.fetchOne(db, key: sharing[0].id)?.ownershipConfirmedAt, Self.day)
        }
    }

    func testSaveRefusesRowsThatDontMatchTheAccounts() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            try addAccount(db, "Synthetic current")
            var rows = try SharingSetup.proposal(admin: h.admin, db: db)
            try addAccount(db, "Synthetic added meanwhile")
            XCTAssertThrowsError(try SharingSetup.save(rows, admin: h.admin, db: db, now: Self.day)) {
                XCTAssertEqual($0 as? SharingError, .rowsDoNotMatchAccounts)
            }
            rows = try SharingSetup.proposal(admin: h.admin, db: db)
            rows[0].owner = .person(h.memberPersonId)
            XCTAssertThrowsError(try SharingSetup.save(rows, admin: h.admin, db: db, now: Self.day)) {
                XCTAssertEqual($0 as? SharingError, .ownerMustBeAdminOrJoint)
            }
            XCTAssertFalse(try SharingSetup.isConfirmed(db: db))
        }
    }

    func testOnlyTheAdminsRowConfirmsOwnership() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            let accountId = try addAccount(db, "Synthetic current")
            try db.execute(sql: "INSERT INTO personSharing(personId, ownershipConfirmedAt) VALUES (?, ?)", arguments: [h.memberPersonId, Self.day])
            XCTAssertFalse(try SharingSetup.isConfirmed(db: db), "a member's row doesn't confirm ownership")
            // The set-up gate stays open: new accounts aren't owned yet, the admin may still save, and the map's set-up rule applies.
            let early = try addAccount(db, "Synthetic early", owner: h.member)
            XCTAssertNil(try account(db, early).ownerPersonId)
            let setup = try AccessAreaMap.area(table: "account", origin: .edit, change: .update(before: ["ownerPersonId": .null]),
                                               changedFields: ["ownerPersonId"], row: ["ownerPersonId": .int(h.adminPersonId)], db: db)
            XCTAssertTrue(try AccessPolicy.allows(h.admin, setup, db: db))
            try SharingSetup.save(try SharingSetup.proposal(admin: h.admin, db: db), admin: h.admin, db: db, now: Self.day)
            XCTAssertTrue(try SharingSetup.isConfirmed(db: db))
            XCTAssertEqual(try account(db, accountId).ownerPersonId, h.adminPersonId)
        }
    }

    func testSaveNeverOverwritesAnExistingOwner() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            let unowned = try addAccount(db, "Synthetic current")
            var owned = Account(name: "Synthetic member card", currency: .gbp, kind: .cash, trackingMode: .imported)
            owned.ownerPersonId = h.memberPersonId
            owned.sharingLevel = .categoryTotals
            try owned.insert(db)

            // The proposal lists only accounts without an owner.
            let rows = try SharingSetup.proposal(admin: h.admin, db: db)
            XCTAssertEqual(rows.map(\.id), [unowned])
            // A row for an owned account is refused, and nothing is written.
            var withOwned = rows
            withOwned.append(SharingSetup.Row(id: owned.id!, displayName: "Synthetic member card", bankName: nil, isPropertyLinked: false,
                                              owner: .person(h.adminPersonId), level: .balanceOnly))
            XCTAssertThrowsError(try SharingSetup.save(withOwned, admin: h.admin, db: db, now: Self.day)) {
                XCTAssertEqual($0 as? SharingError, .accountAlreadyOwned)
            }
            XCTAssertFalse(try SharingSetup.isConfirmed(db: db))
            try SharingSetup.save(rows, admin: h.admin, db: db, now: Self.day)
            XCTAssertEqual(try account(db, owned.id!).ownerPersonId, h.memberPersonId)
            XCTAssertEqual(try account(db, owned.id!).sharingLevel, .categoryTotals)
            XCTAssertEqual(try account(db, unowned).ownerPersonId, h.adminPersonId)
        }
    }

    func testAFailedSaveLeavesNoPartialSetup() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            let accountId = try addAccount(db, "Synthetic current")
            // Fails after the accounts and personSharing rows are written.
            try db.execute(sql: "CREATE TEMP TRIGGER synthetic_boom BEFORE INSERT ON memberPermission BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
            let rows = try SharingSetup.proposal(admin: h.admin, db: db)
            XCTAssertThrowsError(try SharingSetup.save(rows, admin: h.admin, db: db, now: Self.day))
            // The caller caught the error and its transaction goes on: nothing of the set-up is left.
            XCTAssertNil(try account(db, accountId).ownerPersonId)
            XCTAssertEqual(try account(db, accountId).sharingLevel, .everything)
            XCTAssertEqual(try PersonSharing.fetchCount(db), 0)
            XCTAssertFalse(try SharingSetup.isConfirmed(db: db))
            try db.execute(sql: "DROP TRIGGER synthetic_boom")
            try SharingSetup.save(rows, admin: h.admin, db: db, now: Self.day)
            XCTAssertTrue(try SharingSetup.isConfirmed(db: db))
        }
    }

    func testJointMustBeEverything() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            let joint = try addAccount(db, "Synthetic joint")
            var rows = try SharingSetup.proposal(admin: h.admin, db: db)
            rows[0].owner = .joint
            rows[0].level = .balanceOnly
            XCTAssertThrowsError(try SharingSetup.save(rows, admin: h.admin, db: db, now: Self.day)) {
                XCTAssertEqual($0 as? SharingError, .jointMustBeEverything)
            }
            XCTAssertFalse(try SharingSetup.isConfirmed(db: db), "nothing written")
            XCTAssertEqual(try account(db, joint).sharingLevel, .everything)

            rows[0].level = .everything
            try SharingSetup.save(rows, admin: h.admin, db: db, now: Self.day)
            for level in [SharingLevel.hidden, .balanceOnly, .categoryTotals] {
                for actor in [h.admin, h.member] {
                    XCTAssertThrowsError(try SharingLevels.set(level, accountId: joint, actor: actor, db: db)) {
                        XCTAssertEqual($0 as? SharingError, .jointMustBeEverything)
                    }
                }
            }
        }
    }

    func testOnlyAdminSavesOwnership() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            let accountId = try addAccount(db, "Synthetic current")
            let rows = try SharingSetup.proposal(admin: h.admin, db: db)
            XCTAssertThrowsError(try SharingSetup.save(rows, admin: h.member, db: db, now: Self.day)) {
                XCTAssertEqual($0 as? SharingError, .notAdmin)
            }
            XCTAssertFalse(try SharingSetup.isConfirmed(db: db))

            // The area map's set-up rule: while unconfirmed, only the admin gives an unowned account its owner and level.
            func ownerChange(before: SyncValue) throws -> AccessDecision {
                try AccessAreaMap.area(table: "account", origin: .edit, change: .update(before: ["ownerPersonId": before]),
                                       changedFields: ["ownerPersonId", "sharingLevel"],
                                       row: ["ownerPersonId": .int(h.adminPersonId), "sharingLevel": .string("balanceOnly")], db: db)
            }
            let setup = try ownerChange(before: .null)
            XCTAssertTrue(try AccessPolicy.allows(h.admin, setup, db: db))
            XCTAssertFalse(try AccessPolicy.allows(h.member, setup, db: db))

            try SharingSetup.save(rows, admin: h.admin, db: db, now: Self.day)
            XCTAssertEqual(try account(db, accountId).ownerPersonId, h.adminPersonId)
            // Afterwards nobody changes an owner (joint or owned), not even the owner or the admin.
            for before in [SyncValue.null, .int(h.adminPersonId)] {
                let decision = try ownerChange(before: before)
                XCTAssertEqual(decision, .denied)
            }
        }
    }

    // MARK: Levels

    func testSetRefusesNonOwnerAndJoint() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            let adminOwned = try addAccount(db, "Synthetic current")
            XCTAssertThrowsError(try SharingLevels.set(.everything, accountId: adminOwned, actor: h.admin, db: db)) {
                XCTAssertEqual($0 as? SharingError, .ownershipNotConfirmed)
            }
            try confirm(h, db)
            let memberOwned = try addAccount(db, "Synthetic member current", owner: h.member)

            XCTAssertThrowsError(try SharingLevels.set(.everything, accountId: memberOwned, actor: h.admin, db: db)) {
                XCTAssertEqual($0 as? SharingError, .notOwner)
            }
            XCTAssertThrowsError(try SharingLevels.set(.everything, accountId: adminOwned, actor: h.member, db: db)) {
                XCTAssertEqual($0 as? SharingError, .notOwner)
            }
            XCTAssertThrowsError(try SharingLevels.set(.everything, accountId: 999_999, actor: h.admin, db: db)) {
                XCTAssertEqual($0 as? SharingError, .accountNotFound)
            }
            XCTAssertEqual(try account(db, memberOwned).sharingLevel, .balanceOnly)

            // The owner raises and lowers; a member needs no Budget & accounts Edit for their own level.
            XCTAssertEqual(try SharingLevels.set(.categoryTotals, accountId: memberOwned, actor: h.member, db: db),
                           SharingLevels.Change(from: .balanceOnly, to: .categoryTotals, isLowering: false))
            XCTAssertEqual(try account(db, memberOwned).sharingLevel, .categoryTotals)
            let record = try Row.fetchOne(db, sql: "SELECT origin, modifiedBy FROM syncRecord WHERE tableName = 'account' AND localId = ?",
                                          arguments: [memberOwned])
            XCTAssertEqual(record?["modifiedBy"] as String?, h.member.appUserUuid)
            XCTAssertEqual(record?["origin"] as String?, "edit")
            XCTAssertEqual(try SharingLevels.set(.balanceOnly, accountId: memberOwned, actor: h.member, db: db),
                           SharingLevels.Change(from: .categoryTotals, to: .balanceOnly, isLowering: true))
            XCTAssertEqual(try SharingLevels.set(.everything, accountId: adminOwned, actor: h.admin, db: db),
                           SharingLevels.Change(from: .balanceOnly, to: .everything, isLowering: false))
            XCTAssertEqual(try SharingLevels.set(.everything, accountId: adminOwned, actor: h.admin, db: db),
                           SharingLevels.Change(from: .everything, to: .everything, isLowering: false))
        }
    }

    func testHiddenBlockedByPropertyLinkAndPropertyTransactions() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            let linked = try addAccount(db, "Synthetic rent account")
            try link(db, account: linked, property: try property(db, "Synthetic flat"))
            let withPropertyMoney = try addAccount(db, "Synthetic card")
            let named = try addAccount(db, "Synthetic savings")
            let clean = try addAccount(db, "Synthetic spare")
            try confirm(h, db)

            // A property-category transaction with its tax owner, and a not-claimed mark on another transaction: two transactions.
            try db.execute(sql: "INSERT INTO categoryGroup(name) VALUES ('Synthetic flat costs')")
            let groupId = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO propertyCategoryGroup(propertyId, categoryGroupId) VALUES (1, ?)", arguments: [groupId])
            try db.execute(sql: "INSERT INTO category(name, type, groupId) VALUES ('Synthetic flat repairs', 'expense', ?)", arguments: [groupId])
            let propertyCategory = db.lastInsertedRowID
            let repair = try ManualTransactions.add(db: db, accountId: withPropertyMoney, date: Self.day, description: "Synthetic repair",
                                                    amountMinorUnits: -12_000, categoryId: propertyCategory, note: nil)
            let other = try ManualTransactions.add(db: db, accountId: withPropertyMoney, date: Self.day, description: "Synthetic shop",
                                                   amountMinorUnits: -1_000, categoryId: nil, note: nil)
            try db.execute(sql: "INSERT INTO taxTransactionOwner(transactionId, personId) VALUES (?, ?)", arguments: [repair.id!, h.adminPersonId])
            try db.execute(sql: "INSERT INTO taxNotClaimed(startYear, transactionId) VALUES (2026, ?)", arguments: [other.id!])

            // Named by an import rule and by an evidence requirement.
            try ImportRuleStore.learn(db: db, kind: .statementAccount, key: "synthetic-signature", matchLabel: "Synthetic CSV",
                                      action: StatementAccountAction(accountId: named), actionLabel: "Account: Synthetic savings", now: Self.day)
            var requirement = EvidenceRequirement(name: "Synthetic receipts", scope: .transactionsMatching(categoryIds: [], accountIds: [named], descriptionContains: nil),
                                                  kinds: [], createdAt: Self.day)
            try requirement.insert(db)

            XCTAssertEqual(try SharingLevels.blockers(accountId: linked, to: .hidden, db: db), [.propertyLink(propertyName: "Synthetic flat")])
            XCTAssertEqual(try SharingLevels.blockers(accountId: withPropertyMoney, to: .hidden, db: db), [.propertyOrTaxRows(count: 2)])
            XCTAssertEqual(try SharingLevels.blockers(accountId: named, to: .hidden, db: db),
                           [.referencedBy(table: "importRule", count: 1), .referencedBy(table: "evidenceRequirement", count: 1)])
            XCTAssertEqual(try SharingLevels.blockers(accountId: clean, to: .hidden, db: db), [])
            for level in [SharingLevel.balanceOnly, .categoryTotals, .everything] {
                XCTAssertEqual(try SharingLevels.blockers(accountId: linked, to: level, db: db), [], "only Hidden has blockers")
            }

            XCTAssertThrowsError(try SharingLevels.set(.hidden, accountId: linked, actor: h.admin, db: db)) {
                XCTAssertEqual($0 as? SharingError, .blocked([.propertyLink(propertyName: "Synthetic flat")]))
            }
            XCTAssertThrowsError(try SharingLevels.set(.hidden, accountId: withPropertyMoney, actor: h.admin, db: db)) {
                XCTAssertEqual($0 as? SharingError, .blocked([.propertyOrTaxRows(count: 2)]))
            }
            XCTAssertEqual(try account(db, linked).sharingLevel, .everything)
            XCTAssertEqual(try SharingLevels.set(.hidden, accountId: clean, actor: h.admin, db: db).isLowering, true)
            XCTAssertEqual(try account(db, clean).sharingLevel, .hidden)

            XCTAssertEqual(SharingCopy.blocker(.propertyLink(propertyName: "Synthetic flat")), "Linked to the property Synthetic flat")
            XCTAssertEqual(SharingCopy.blocker(.propertyOrTaxRows(count: 3)), "3 property or tax records point at its transactions")
            XCTAssertEqual(SharingCopy.blocker(.propertyOrTaxRows(count: 1)), "1 property or tax record points at its transactions")
            XCTAssertEqual(SharingCopy.blocker(.referencedBy(table: "importRule", count: 1)), "Named by 1 import rule")
            XCTAssertEqual(SharingCopy.blocker(.referencedBy(table: "evidenceRequirement", count: 2)), "Named by 2 evidence requirements")
        }
    }

    func testPropertyOrTaxRowsCountEachTransactionOnce() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            let card = try addAccount(db, "Synthetic card")
            let flat = try property(db, "Synthetic flat")
            try confirm(h, db)
            try db.execute(sql: "INSERT INTO categoryGroup(name) VALUES ('Synthetic flat costs')")
            let groupId = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO propertyCategoryGroup(propertyId, categoryGroupId) VALUES (?, ?)", arguments: [flat, groupId])
            try db.execute(sql: "INSERT INTO category(name, type, groupId) VALUES ('Synthetic flat repairs', 'expense', ?)", arguments: [groupId])
            let propertyCategory = db.lastInsertedRowID
            // One property-category transaction that two tax tables also point at.
            let repair = try ManualTransactions.add(db: db, accountId: card, date: Self.day, description: "Synthetic repair",
                                                    amountMinorUnits: -12_000, categoryId: propertyCategory, note: nil)
            try db.execute(sql: "INSERT INTO taxTransactionOwner(transactionId, personId) VALUES (?, ?)", arguments: [repair.id!, h.adminPersonId])
            try db.execute(sql: "INSERT INTO taxNotClaimed(startYear, transactionId) VALUES (2026, ?)", arguments: [repair.id!])
            try db.execute(sql: "INSERT INTO taxNotClaimed(startYear, transactionId) VALUES (2027, ?)", arguments: [repair.id!])
            XCTAssertEqual(try SharingLevels.blockers(accountId: card, to: .hidden, db: db), [.propertyOrTaxRows(count: 1)])
        }
    }

    func testUnreadableAccountRuleBlocksHidden() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            let accountId = try addAccount(db, "Synthetic savings")
            try confirm(h, db)
            // Rules of kinds that never name an account don't block, whatever their JSON.
            var issuer = ImportRule(kind: .issuer, matchKey: "synthetic-issuer", matchLabel: "Synthetic", actionJSON: "not json",
                                    actionLabel: "Synthetic", createdAt: Self.day)
            try issuer.insert(db)
            XCTAssertEqual(try SharingLevels.blockers(accountId: accountId, to: .hidden, db: db), [])
            // An account-naming rule that can't be read might name it: fail closed.
            var unreadable = ImportRule(kind: .statementAccount, matchKey: "synthetic-signature", matchLabel: "Synthetic CSV",
                                        actionJSON: "{\"accountId\": \"oops\"}", actionLabel: "Account: ?", createdAt: Self.day)
            try unreadable.insert(db)
            XCTAssertEqual(try SharingLevels.blockers(accountId: accountId, to: .hidden, db: db), [.referencedBy(table: "importRule", count: 1)])
            // A link rule naming the account blocks too.
            try unreadable.delete(db)
            try ImportRuleStore.learn(db: db, kind: .link, key: "synthetic-link", matchLabel: "Synthetic", action: LinkAction(entity: .account(accountId)),
                                      actionLabel: "Link", now: Self.day)
            XCTAssertEqual(try SharingLevels.blockers(accountId: accountId, to: .hidden, db: db), [.referencedBy(table: "importRule", count: 1)])
        }
    }

    func testTaxIncomeHiddenIsNotAvailableYet() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            try confirm(h, db)
            XCTAssertThrowsError(try SharingLevels.setTaxIncomeLevel(.hidden, personId: h.memberPersonId, actor: h.member, db: db)) {
                XCTAssertEqual($0 as? SharingError, .notAvailableYet)
            }
            XCTAssertThrowsError(try SharingLevels.setTaxIncomeLevel(.everything, personId: h.memberPersonId, actor: h.admin, db: db)) {
                XCTAssertEqual($0 as? SharingError, .notOwner)
            }
            try SharingLevels.setTaxIncomeLevel(.everything, personId: h.memberPersonId, actor: h.member, db: db)
            XCTAssertEqual(try PersonSharing.filter(Column("personId") == h.memberPersonId).fetchOne(db)?.taxIncomeLevel, .everything)
            XCTAssertEqual(SharingCopy.hiddenNotAvailable, "Hidden (not available yet)")
        }
    }

    // MARK: New accounts

    func testNewAccountAfterConfirmationIsOwnedAndBalanceOnly() throws {
        let queue = try TestDatabase.migrated()
        try queue.write { db in
            let h = try household(db)
            // Before the sheet: unowned at Everything, whoever adds it (the sheet assigns it).
            let early = try addAccount(db, "Synthetic early", owner: h.member)
            XCTAssertNil(try account(db, early).ownerPersonId)
            XCTAssertEqual(try account(db, early).sharingLevel, .everything)
            try confirm(h, db)

            let mine = try addAccount(db, "Synthetic member card", owner: h.member)
            XCTAssertEqual(try account(db, mine).ownerPersonId, h.memberPersonId)
            XCTAssertEqual(try account(db, mine).sharingLevel, .balanceOnly)
            let adminNew = try addAccount(db, "Synthetic admin savings", owner: h.admin)
            XCTAssertEqual(try account(db, adminNew).ownerPersonId, h.adminPersonId)
            XCTAssertEqual(try account(db, adminNew).sharingLevel, .balanceOnly)
            // No actor: joint at Everything (created as joint, and tools).
            let joint = try addAccount(db, "Synthetic new joint")
            XCTAssertNil(try account(db, joint).ownerPersonId)
            XCTAssertEqual(try account(db, joint).sharingLevel, .everything)
        }
    }

    // MARK: Copy

    func testPrivateLineCopy() {
        XCTAssertEqual(SharingCopy.privateLine(account: "Synthetic card", owner: "Member", count: 1),
                       "Synthetic card (Member) · 1 transaction · details private")
        XCTAssertEqual(SharingCopy.privateLine(account: "Synthetic card", owner: "Member", count: 7),
                       "Synthetic card (Member) · 7 transactions · details private")
    }

    func testSharingCopy() {
        XCTAssertEqual(SharingCopy.sheetTitle, "Who owns each account?")
        XCTAssertEqual(SharingCopy.sheetNote, "Every account is yours unless you mark it Joint. Joint accounts are always shared in full.")
        XCTAssertEqual(SharingCopy.ownerChoices(adminName: "Admin"), ["Admin", "Joint"])
        XCTAssertEqual(SharingCopy.ownerChoice(.joint, adminName: "Admin"), "Joint")
        XCTAssertEqual(SharingCopy.ownerChoice(.person(1), adminName: "Admin"), "Admin")
        XCTAssertEqual(SharingCopy.badge(.categoryTotals), "Shared as category totals")
        XCTAssertEqual(SharingCopy.badge(.balanceOnly), "Shared as balance only")
        XCTAssertEqual(SharingCopy.badge(.hidden), "Not shared")
        XCTAssertNil(SharingCopy.badge(.everything))
        XCTAssertEqual(SharingCopy.lowerWarning(otherName: "Member"),
                       "Lowering the level stops sharing from now on. Member may already have a copy of this account's transactions on their devices or in their backups, and Mango can't recall it.")
        XCTAssertEqual(SharingCopy.raiseNote(otherName: "Member"), "Member will see this account's transactions and documents.")
        XCTAssertEqual(SharingCopy.netWorthNote, "Includes everything you can see")
    }
}

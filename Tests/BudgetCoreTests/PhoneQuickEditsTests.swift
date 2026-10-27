import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Step 7b Task 4: the iPhone's quick edits (categorise and note, quick sort with Undo, a manual balance), every one
/// through `DeviceWriter.writeCheckingFiledYears`. Synthetic data only: admin Person A (iCloud "_admin") owns
/// Property A, whose account *Flat* is property money; *Everyday* is not; *Cash jar* is a manual account.
final class PhoneQuickEditsTests: XCTestCase {
    private var queue: DatabaseQueue!
    private var ids: [String: Int64] = [:]
    private var after: Counter!

    private static let admin = "_admin"
    private static let member = "_member"
    /// The pay month the queue tests read.
    private static let payMonth = PayMonthReview.DayRange(start: day(2026, 9, 25), end: day(2026, 10, 24))

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        UKTaxYear.utcCalendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    override func setUpWithError() throws {
        queue = try TestDatabase.migrated()
        after = Counter()
        ids = try queue.write { db in
            var ids: [String: Int64] = [:]
            var a = Person(name: "Person A", shortName: "A")
            try People.save(db: db, &a)
            var b = Person(name: "Person B", shortName: "B")
            try People.save(db: db, &b)
            ids["A"] = a.id!
            var admin = AppUser(personId: a.id!, displayName: "A", cloudKitUserRecordName: Self.admin, isAdmin: true, createdAt: Self.day(2026, 1, 1))
            try admin.insert(db)
            var member = AppUser(personId: b.id!, displayName: "B", cloudKitUserRecordName: Self.member, isAdmin: false, createdAt: Self.day(2026, 1, 1))
            try member.insert(db)
            ids["memberUser"] = member.id!
            var filed = TaxYear(startYear: 2022, personId: a.id!, status: .filed)
            try filed.insert(db)
            var property = Property(name: "Property A", country: "PT", currency: .gbp)
            try Properties.save(db: db, &property)
            _ = try Properties.setOwners(db: db, propertyId: property.id!, [
                PropertyOwner(propertyId: property.id!, personId: a.id!, shareBasisPoints: 10_000)
            ])
            for (key, name, mode) in [("flat", "Flat", AccountTrackingMode.imported), ("everyday", "Everyday", .imported), ("cash", "Cash jar", .manual)] {
                var account = Account(name: name, currency: .gbp, kind: .cash, trackingMode: mode)
                try account.insert(db)
                ids[key] = account.id!
                var batch = ImportBatch(accountId: account.id!, sourceFileName: "\(key).csv", importedAt: Self.day(2025, 1, 1))
                try batch.insert(db)
                ids["\(key)Batch"] = batch.id!
            }
            try Properties.setAccount(db: db, propertyId: property.id!, accountId: ids["flat"]!, role: .current)
            var group = CategoryGroup(name: "Property A")
            try group.insert(db)
            ids["propertyGroup"] = group.id!
            try Properties.addCategoryGroup(db: db, propertyId: property.id!, categoryGroupId: group.id!)
            for (key, name, type) in [("rent", "Rental income", CategoryType.income), ("repairs", "Repairs", .expense)] {
                var category = Category(name: name, type: type, groupId: group.id)
                try category.insert(db)
                ids[key] = category.id!
            }
            var everyday = CategoryGroup(name: "Everyday")
            try everyday.insert(db)
            var groceries = Category(name: "Groceries", type: .expense, groupId: everyday.id)
            try groceries.insert(db)
            ids["groceries"] = groceries.id!
            try TaxExpenseTypeMap.seed(db: db, propertyId: property.id!)
            // Rent the filed 2022/23 return counts.
            var rent = Transaction(importBatchId: ids["flatBatch"]!, accountId: ids["flat"]!, date: Self.day(2022, 6, 1), rawDescription: "TENANT RENT",
                                   amountMinorUnits: 500_000, categoryId: ids["rent"]!, status: .confirmed, categorizedBy: .manual, fingerprint: "rent")
            try rent.insert(db)
            try db.execute(sql: "DELETE FROM syncPending")
            return ids
        }
    }

    // MARK: Helpers

    private func id(_ key: String) -> Int64 { ids[key]! }

    private func writer(_ viewer: PhoneViewer) -> DeviceWriter {
        let after = after!
        return DeviceWriter(db: queue, viewer: { viewer }, afterWrite: { after.bump() })
    }

    private var memberWriter: DeviceWriter { writer(.iCloudUser(recordName: Self.member)) }
    private var adminWriter: DeviceWriter { writer(.iCloudUser(recordName: Self.admin)) }

    @discardableResult
    private func transaction(_ account: String, _ date: Date, _ amount: Int, _ description: String, category: String? = nil,
                             categorizedBy: CategorizedBy = .none) throws -> Int64 {
        try queue.write { db in
            var t = Transaction(importBatchId: id("\(account)Batch"), accountId: id(account), date: date, rawDescription: description,
                                amountMinorUnits: amount, categoryId: category.map(id), status: category == nil ? .pendingReview : .confirmed,
                                categorizedBy: categorizedBy, fingerprint: UUID().uuidString)
            try t.insert(db)
            try db.execute(sql: "DELETE FROM syncPending")
            return t.id!
        }
    }

    private func fetch(_ transactionId: Int64) throws -> Transaction {
        try queue.read { db in try XCTUnwrap(try Transaction.fetchOne(db, key: transactionId)) }
    }

    private func pending() throws -> [PendingChange] {
        try queue.read { db in try SyncChangeTracker.pending(db: db) }
    }

    private func value<T: DatabaseValueConvertible>(_ sql: String, _ arguments: StatementArguments = []) throws -> T? {
        try queue.read { db in try T.fetchOne(db, sql: sql, arguments: arguments) }
    }

    private func thrown(_ body: () async throws -> Void) async -> Error? {
        do {
            try await body()
            return nil
        } catch {
            return error
        }
    }

    private func setMemberLevel(_ level: PermissionLevel, _ area: AccessArea) throws {
        try queue.write { db in
            try MemberPermissions.ensureDefaults(appUserId: id("memberUser"), db: db)
            try db.execute(sql: "UPDATE memberPermission SET level = ? WHERE appUserId = ? AND area = ?",
                           arguments: [level.rawValue, id("memberUser"), area.storageKey])
        }
    }

    private func queueFor(_ viewer: PhoneViewer, _ writer: DeviceWriter) async throws -> [PhoneQuickEdits.QuickSortCard] {
        let property = await writer.canEdit(.property)
        let budget = await writer.canEdit(.budgetAndAccounts)
        return try await queue.read { db in
            try PhoneQuickEdits.quickSortQueue(db: db, viewer: viewer, payMonth: Self.payMonth) { area in
                switch area {
                case .property: return property
                case .budgetAndAccounts: return budget
                default: return false
                }
            }
        }
    }

    // MARK: Areas

    func testAreaForPropertyMoneyIsProperty() throws {
        let onFlat = try transaction("flat", Self.day(2026, 10, 1), -2_000, "PLUMBER")
        let inPropertyCategory = try transaction("everyday", Self.day(2026, 10, 1), -2_000, "PLUMBER", category: "repairs")
        try queue.read { db in
            XCTAssertEqual(try PhoneQuickEdits.area(forTransaction: onFlat, db: db), .property, "a property-linked account at Everything")
            XCTAssertEqual(try PhoneQuickEdits.area(forTransaction: inPropertyCategory, db: db), .property, "a property's category")
        }
    }

    func testAreaForOtherMoneyIsBudgetAndAccounts() async throws {
        let plain = try transaction("everyday", Self.day(2026, 10, 1), -2_000, "SHOP", category: "groceries")
        let uncategorised = try transaction("everyday", Self.day(2026, 10, 1), -2_000, "SHOP")
        try await queue.read { db in
            XCTAssertEqual(try PhoneQuickEdits.area(forTransaction: plain, db: db), .budgetAndAccounts)
            XCTAssertEqual(try PhoneQuickEdits.area(forTransaction: uncategorised, db: db), .budgetAndAccounts)
        }
        let memberCan = await PhoneQuickEdits.canEditTransaction(uncategorised, writer: memberWriter, dbReader: queue)
        let adminCan = await PhoneQuickEdits.canEditTransaction(uncategorised, writer: adminWriter, dbReader: queue)
        let unboundCan = await PhoneQuickEdits.canEditTransaction(uncategorised, writer: writer(.iCloudUser(recordName: nil)), dbReader: queue)
        XCTAssertFalse(memberCan)
        XCTAssertTrue(adminCan)
        XCTAssertFalse(unboundCan, "no actor")
    }

    // MARK: Categorise and note

    func testMemberCategorisePropertyMoneyKept() async throws {
        let plumber = try transaction("flat", Self.day(2026, 10, 1), -2_000, "PLUMBER")
        let memberCan = await PhoneQuickEdits.canEditTransaction(plumber, writer: memberWriter, dbReader: queue)
        XCTAssertTrue(memberCan)
        try await PhoneQuickEdits.categorise(writer: memberWriter, transactionId: plumber, categoryId: id("repairs"), note: "Kitchen tap")
        let saved = try fetch(plumber)
        XCTAssertEqual(saved.categoryId, id("repairs"))
        XCTAssertEqual(saved.note, "Kitchen tap")
        XCTAssertEqual(saved.categorizedBy, .manual)
        XCTAssertEqual(saved.status, .confirmed)
        let memberUuid = try await queue.write { db in try SyncRecordStore.uuid(for: "appUser", localId: self.id("memberUser"), db: db) }
        XCTAssertEqual(try value("SELECT modifiedBy FROM syncRecord WHERE tableName = 'transaction_' AND localId = ?", [plumber]) as String?, memberUuid,
                       "stamped as her")
        XCTAssertEqual(try pending().map(\.localId), [plumber])
        XCTAssertEqual(after.value, 1)
    }

    func testMemberCategoriseNonPropertyDenied() async throws {
        let shop = try transaction("everyday", Self.day(2026, 10, 1), -2_000, "SHOP")
        let error = await thrown {
            try await PhoneQuickEdits.categorise(writer: self.memberWriter, transactionId: shop, categoryId: self.id("groceries"), note: nil)
        }
        XCTAssertEqual(error as? AccessDenied, AccessDenied(area: .budgetAndAccounts))
        XCTAssertNil(try fetch(shop).categoryId)
        XCTAssertEqual(try pending(), [])
        XCTAssertEqual(after.value, 0)
    }

    func testNoteOnlyKeepsHowItWasCategorised() async throws {
        let rent = try transaction("flat", Self.day(2026, 10, 1), 90_000, "TENANT", category: "rent", categorizedBy: .rule)
        try await PhoneQuickEdits.categorise(writer: memberWriter, transactionId: rent, categoryId: id("rent"), note: "  October  ")
        let saved = try fetch(rent)
        XCTAssertEqual(saved.note, "October")
        XCTAssertEqual(saved.categorizedBy, .rule)
        XCTAssertEqual(saved.status, .confirmed)
        try await PhoneQuickEdits.categorise(writer: memberWriter, transactionId: rent, categoryId: id("rent"), note: " ")
        XCTAssertNil(try fetch(rent).note, "blank clears it")
    }

    func testCategoriseFiledYearRefusedNothingPending() async throws {
        let repair = try transaction("flat", Self.day(2022, 11, 1), -40_000, "PLUMBER")
        let before = try fetch(repair)
        let error = await thrown {
            try await PhoneQuickEdits.categorise(writer: self.memberWriter, transactionId: repair, categoryId: self.id("repairs"), note: nil)
        }
        guard case .filedYear(let question)? = error as? DeviceWriteRefusal else {
            return XCTFail("expected a filed-year refusal, got \(String(describing: error))")
        }
        // Its own return, and the payments on account it carries into the next two.
        XCTAssertEqual(question.years.map(\.label), ["2022/23", "2023/24", "2024/25"])
        XCTAssertEqual(try fetch(repair), before, "the row unchanged")
        XCTAssertEqual(try pending(), [])
        XCTAssertEqual(after.value, 0)
    }

    func testQuickEditAfterEditRemovedRefused() async throws {
        let plumber = try transaction("flat", Self.day(2026, 10, 1), -2_000, "PLUMBER")
        try setMemberLevel(.view, .property)
        try await queue.write { db in try db.execute(sql: "DELETE FROM syncPending") }
        let memberCan = await PhoneQuickEdits.canEditTransaction(plumber, writer: memberWriter, dbReader: queue)
        XCTAssertFalse(memberCan)
        let error = await thrown {
            try await PhoneQuickEdits.categorise(writer: self.memberWriter, transactionId: plumber, categoryId: self.id("repairs"), note: nil)
        }
        XCTAssertEqual(error as? AccessDenied, AccessDenied(area: .property))
        XCTAssertNil(try fetch(plumber).categoryId)
        XCTAssertEqual(try pending(), [])
        XCTAssertEqual(after.value, 0)
    }

    /// A suggestion waiting for review: saving its own category confirms it, keeping how it was suggested.
    private func suggested(_ account: String, _ date: Date, _ description: String, category: String) throws -> Int64 {
        let id = try transaction(account, date, -2_000, description, category: category, categorizedBy: .rule)
        try queue.write { db in
            try db.execute(sql: "UPDATE transaction_ SET status = 'pendingReview' WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM syncPending")
        }
        return id
    }

    func testSheetSavingSuggestedCategoryConfirmsIt() async throws {
        let plumber = try suggested("flat", Self.day(2026, 10, 2), "PLUMBER", category: "repairs")
        try await PhoneQuickEdits.categorise(writer: memberWriter, transactionId: plumber, categoryId: id("repairs"), note: nil)
        let saved = try fetch(plumber)
        XCTAssertEqual(saved.categoryId, id("repairs"))
        XCTAssertEqual(saved.status, .confirmed)
        XCTAssertEqual(saved.categorizedBy, .rule, "how it was suggested")
        XCTAssertEqual(after.value, 1)
    }

    func testQuickSortConfirmsSuggestionAndUndoPutsItBackToReview() async throws {
        let plumber = try suggested("flat", Self.day(2026, 10, 2), "PLUMBER", category: "repairs")
        let empty = try transaction("flat", Self.day(2026, 10, 1), -1_000, "LOCKSMITH")
        let queued = try await queueFor(.iCloudUser(recordName: Self.member), memberWriter)
        XCTAssertEqual(queued.map(\.id), [plumber, empty])
        XCTAssertEqual(queued.map(\.suggestedCategoryId), [id("repairs"), nil])
        let before = try fetch(plumber)

        let token = try await PhoneQuickEdits.pick(writer: memberWriter, card: queued[0], categoryId: id("repairs"))
        XCTAssertEqual(try fetch(plumber).status, .confirmed)
        let left = try await queueFor(.iCloudUser(recordName: Self.member), memberWriter)
        XCTAssertEqual(left.map(\.id), [empty])

        try await PhoneQuickEdits.undo(writer: memberWriter, token: token)
        XCTAssertEqual(try fetch(plumber), before)
        XCTAssertEqual(try fetch(plumber).status, .pendingReview)
    }

    // MARK: Quick sort

    func testQuickSortQueueNewestFirstUncategorisedCurrentPayMonthOnly() async throws {
        let older = try transaction("everyday", Self.day(2026, 9, 26), -1_000, "BAKERY")
        let newest = try transaction("flat", Self.day(2026, 10, 20), -3_000, "PLUMBER")
        let middle = try transaction("everyday", Self.day(2026, 10, 5), -2_000, "CAFE")
        try transaction("everyday", Self.day(2026, 10, 6), -2_500, "SHOP", category: "groceries")  // categorised
        try transaction("everyday", Self.day(2026, 9, 24), -500, "LAST MONTH")                      // before the pay month
        try transaction("everyday", Self.day(2026, 10, 25), -500, "NEXT MONTH")                     // after it
        let cards = try await queueFor(.iCloudUser(recordName: Self.admin), adminWriter)
        XCTAssertEqual(cards.map(\.id), [newest, middle, older])
        XCTAssertEqual(cards.first, PhoneQuickEdits.QuickSortCard(id: newest, description: "PLUMBER", accountName: "Flat",
                                                                  date: Self.day(2026, 10, 20), amountMinorUnits: -3_000, currency: .gbp))
    }

    func testQuickSortSkipsPrivateAccountsOfTheOtherPerson() async throws {
        let db = try TestDatabase.migrated()
        let (fixture, range) = try await db.write { db -> (SharingFixture, PayMonthReview.DayRange) in
            let f = try SharingFixture.build(db)
            try db.execute(sql: "UPDATE appUser SET cloudKitUserRecordName = ? WHERE personId = ?", arguments: [Self.member, f.personB])
            try db.execute(sql: "UPDATE appUser SET cloudKitUserRecordName = ? WHERE personId = ?", arguments: [Self.admin, f.personA])
            for transaction in [f.sharedTransaction, f.privateTransaction, f.privatePinnedTransaction, f.totalsTransaction] {
                try db.execute(sql: "UPDATE transaction_ SET categoryId = NULL, status = 'pendingReview', categorizedBy = 'none' WHERE id = ?",
                               arguments: [transaction])
            }
            // She edits Budget & accounts here, so only what she sees decides.
            let memberUser = try Int64.fetchOne(db, sql: "SELECT id FROM appUser WHERE personId = ?", arguments: [f.personB])!
            try MemberPermissions.ensureDefaults(appUserId: memberUser, db: db)
            try db.execute(sql: "UPDATE memberPermission SET level = 'edit' WHERE appUserId = ?", arguments: [memberUser])
            let day = try Date.fetchOne(db, sql: "SELECT date FROM transaction_ WHERE id = ?", arguments: [f.sharedTransaction])!
            return (f, PayMonthReview.DayRange(start: day.addingTimeInterval(-86_400), end: day.addingTimeInterval(86_400)))
        }
        func cards(_ recordName: String) throws -> [Int64] {
            try db.read { db in
                try PhoneQuickEdits.quickSortQueue(db: db, viewer: .iCloudUser(recordName: recordName), payMonth: range) { _ in true }.map(\.id)
            }
        }
        let hers = try cards(Self.member)
        XCTAssertTrue(hers.contains(fixture.sharedTransaction))
        let privateIds: Set<Int64> = [fixture.privateTransaction, fixture.privatePinnedTransaction, fixture.totalsTransaction]
        XCTAssertTrue(privateIds.isDisjoint(with: hers), "none of A's private accounts' transactions")
        XCTAssertTrue(privateIds.isSubset(of: try cards(Self.admin)), "his own, on his queue")
    }

    func testQuickSortSkipsRowsTheActorCannotEdit() async throws {
        let plumber = try transaction("flat", Self.day(2026, 10, 2), -2_000, "PLUMBER")
        try transaction("everyday", Self.day(2026, 10, 3), -1_000, "SHOP")
        let hers = try await queueFor(.iCloudUser(recordName: Self.member), memberWriter)
        XCTAssertEqual(hers.map(\.id), [plumber], "Property only: Budget & accounts is View")
        let unbound = try await queueFor(.iCloudUser(recordName: nil), writer(.iCloudUser(recordName: nil)))
        XCTAssertEqual(unbound, [])
    }

    func testPickThenUndoRestoresTransaction() async throws {
        let plumber = try transaction("flat", Self.day(2026, 10, 2), -2_000, "PLUMBER")
        try await queue.write { db in try db.execute(sql: "UPDATE transaction_ SET note = 'Synthetic' WHERE id = ?", arguments: [plumber]) }
        let before = try fetch(plumber)
        let queued = try await queueFor(.iCloudUser(recordName: Self.member), memberWriter)
        let card = try XCTUnwrap(queued.first)
        let token = try await PhoneQuickEdits.pick(writer: memberWriter, card: card, categoryId: id("repairs"))
        let picked = try fetch(plumber)
        XCTAssertEqual(picked.categoryId, id("repairs"))
        XCTAssertEqual(picked.status, .confirmed)
        XCTAssertEqual(picked.note, "Synthetic", "the note kept")
        let sorted = try await queueFor(.iCloudUser(recordName: Self.member), memberWriter)
        XCTAssertEqual(sorted, [], "sorted")

        try await PhoneQuickEdits.undo(writer: memberWriter, token: token)
        XCTAssertEqual(try fetch(plumber), before)
        let back = try await queueFor(.iCloudUser(recordName: Self.member), memberWriter)
        XCTAssertEqual(back.map(\.id), [plumber], "back in the queue")
        XCTAssertEqual(after.value, 2)
    }

    func testUndoRefusedWhenYearBecameFiled() async throws {
        let repair = try transaction("flat", Self.day(2025, 11, 1), -40_000, "PLUMBER")
        let card = PhoneQuickEdits.QuickSortCard(id: repair, description: "PLUMBER", accountName: "Flat", date: Self.day(2025, 11, 1),
                                                 amountMinorUnits: -40_000, currency: .gbp)
        let token = try await PhoneQuickEdits.pick(writer: memberWriter, card: card, categoryId: id("repairs"))
        try await queue.write { db in
            var filed = TaxYear(startYear: 2025, personId: self.id("A"), status: .filed)
            try filed.insert(db)
            try db.execute(sql: "DELETE FROM syncPending")
        }
        let picked = try fetch(repair)
        let error = await thrown { try await PhoneQuickEdits.undo(writer: self.memberWriter, token: token) }
        guard case .filedYear(let question)? = error as? DeviceWriteRefusal else {
            return XCTFail("expected a filed-year refusal, got \(String(describing: error))")
        }
        XCTAssertEqual(question.years.map(\.label), ["2025/26"])
        XCTAssertEqual(try fetch(repair), picked, "still as picked")
        XCTAssertEqual(try pending(), [])
        XCTAssertEqual(after.value, 1, "the pick only")
    }

    // MARK: Manual balance

    func testManualBalanceWritesAdjustmentAndConfirmsBalance() async throws {
        let asOf = Self.day(2026, 10, 1)
        let can = await PhoneQuickEdits.canUpdateBalance(accountId: id("cash"), writer: adminWriter, dbReader: queue)
        XCTAssertTrue(can)
        let outcome = try await PhoneQuickEdits.updateManualBalance(writer: adminWriter, accountId: id("cash"), enteredMinorUnits: 12_345,
                                                                    asOf: asOf, note: "Counted")
        XCTAssertEqual(outcome.differenceMinorUnits, 12_345)
        XCTAssertEqual(outcome.role, .balanceAdjustment)
        let adjustment = try fetch(try XCTUnwrap(outcome.transactionId))
        XCTAssertEqual(adjustment.amountMinorUnits, 12_345)
        XCTAssertEqual(adjustment.note, "Counted")
        XCTAssertEqual(try value("SELECT balanceConfirmedAt FROM account WHERE id = ?", [id("cash")]) as Date?, asOf)
        XCTAssertEqual(after.value, 1)

        // Unchanged: nothing more to adjust.
        let again = try await PhoneQuickEdits.updateManualBalance(writer: adminWriter, accountId: id("cash"), enteredMinorUnits: 12_345,
                                                                  asOf: asOf, note: nil)
        XCTAssertEqual(again.differenceMinorUnits, 0)

        // She views Budget & accounts by default: no Update balance, and a write is denied.
        let memberCan = await PhoneQuickEdits.canUpdateBalance(accountId: id("cash"), writer: memberWriter, dbReader: queue)
        XCTAssertFalse(memberCan)
        let error = await thrown {
            _ = try await PhoneQuickEdits.updateManualBalance(writer: self.memberWriter, accountId: self.id("cash"), enteredMinorUnits: 1,
                                                              asOf: asOf, note: nil)
        }
        XCTAssertEqual(error as? AccessDenied, AccessDenied(area: .budgetAndAccounts))
    }

    /// Her phone, an account of A's she sees only as category totals (made manual here): no Update balance, and a
    /// write is refused even though she edits Budget & accounts.
    func testManualBalanceOnAccountNotSeenInFullRefused() async throws {
        let db = try TestDatabase.migrated()
        let totals = try await db.write { db -> Int64 in
            let f = try SharingFixture.build(db)
            try db.execute(sql: "UPDATE appUser SET cloudKitUserRecordName = ? WHERE personId = ?", arguments: [Self.member, f.personB])
            try db.execute(sql: "UPDATE account SET trackingMode = 'manual' WHERE id = ?", arguments: [f.totals])
            let memberUser = try Int64.fetchOne(db, sql: "SELECT id FROM appUser WHERE personId = ?", arguments: [f.personB])!
            try MemberPermissions.ensureDefaults(appUserId: memberUser, db: db)
            try db.execute(sql: "UPDATE memberPermission SET level = 'edit' WHERE appUserId = ?", arguments: [memberUser])
            try db.execute(sql: "DELETE FROM syncPending")
            return f.totals
        }
        let counter = after!
        let hers = DeviceWriter(db: db, viewer: { .iCloudUser(recordName: Self.member) }, afterWrite: { counter.bump() })
        let budget = await hers.canEdit(.budgetAndAccounts)
        XCTAssertTrue(budget)
        let can = await PhoneQuickEdits.canUpdateBalance(accountId: totals, writer: hers, dbReader: db)
        XCTAssertFalse(can)
        func count() throws -> Int { try db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transaction_")! } }
        let transactions = try count()
        var outcome: BalanceUpdates.Outcome?
        let error = await thrown {
            outcome = try await PhoneQuickEdits.updateManualBalance(writer: hers, accountId: totals, enteredMinorUnits: 99_999,
                                                                    asOf: Self.day(2026, 10, 1), note: nil)
        }
        XCTAssertEqual(error as? AccessDenied, AccessDenied(area: .budgetAndAccounts))
        XCTAssertNil(outcome, "no difference returned")
        XCTAssertEqual(try count(), transactions)
        let confirmed = try await db.read { db in try Date.fetchOne(db, sql: "SELECT balanceConfirmedAt FROM account WHERE id = ?", arguments: [totals]) }
        XCTAssertNil(confirmed)
        let pending = try await db.read { db in try SyncChangeTracker.pending(db: db) }
        XCTAssertEqual(pending, [])
        XCTAssertEqual(after.value, 0)
    }

    func testImportedAccountBalanceUpdateRefused() async throws {
        let can = await PhoneQuickEdits.canUpdateBalance(accountId: id("everyday"), writer: adminWriter, dbReader: queue)
        XCTAssertFalse(can)
        let count: Int? = try value("SELECT COUNT(*) FROM transaction_")
        let error = await thrown {
            _ = try await PhoneQuickEdits.updateManualBalance(writer: self.adminWriter, accountId: self.id("everyday"), enteredMinorUnits: 1_000,
                                                              asOf: Self.day(2026, 10, 1), note: nil)
        }
        XCTAssertEqual(error as? QuickEditError, .notManual)
        XCTAssertEqual(try value("SELECT COUNT(*) FROM transaction_") as Int?, count)
        XCTAssertNil(try value("SELECT balanceConfirmedAt FROM account WHERE id = ?", [id("everyday")]) as Date?)
        XCTAssertEqual(try pending(), [])
        XCTAssertEqual(after.value, 0)
    }

    func testManualBalanceFiledYearRefusedInline() async throws {
        // A Balance adjustment never reaches a return; contrived so this one does (an expense of the property, counted
        // as its legal fees), to show the balance goes through the filed-year check with its date and category.
        try await queue.write { db in
            let adjustment = try BuiltInCategories.category(db: db, role: .balanceAdjustment)
            try db.execute(sql: "UPDATE category SET groupId = ?, type = 'expense' WHERE id = ?", arguments: [self.id("propertyGroup"), adjustment.id])
            try TaxExpenseTypeMap.set(db: db, categoryId: adjustment.id!, expenseType: .legalFees)
            try db.execute(sql: "DELETE FROM syncPending")
        }
        let count: Int? = try value("SELECT COUNT(*) FROM transaction_")
        let error = await thrown {
            _ = try await PhoneQuickEdits.updateManualBalance(writer: self.adminWriter, accountId: self.id("cash"), enteredMinorUnits: -30_000,
                                                              asOf: Self.day(2024, 12, 1), note: nil)
        }
        guard case .filedYear(let question)? = error as? DeviceWriteRefusal else {
            return XCTFail("expected a filed-year refusal, got \(String(describing: error))")
        }
        XCTAssertEqual(question.years.map(\.label), ["2024/25"])
        XCTAssertEqual((error as? LocalizedError)?.errorDescription,
                       "Not saved: this would change the filed 2024/25 return. To change it anyway, use the Mac.")
        XCTAssertEqual(try value("SELECT COUNT(*) FROM transaction_") as Int?, count)
        XCTAssertNil(try value("SELECT balanceConfirmedAt FROM account WHERE id = ?", [id("cash")]) as Date?)
        XCTAssertEqual(try pending(), [])
        XCTAssertEqual(after.value, 0)
    }

    // MARK: Copy

    func testQuickEditCopy() {
        XCTAssertEqual(DeviceWriteCopy.categorisedToast("Groceries"), "Categorised as Groceries")
        XCTAssertEqual(DeviceWriteCopy.undoneToast, "Category removed")
        XCTAssertEqual(QuickEditError.notManual.errorDescription, "This account is updated from statements. Import one on the Mac.")
    }
}

import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// Step 6 Task 6: the summaries the household zone holds for accounts below Everything, built by the owner's
/// device: balance points at each pay-month end and now (never daily), category totals per pay month without the
/// §10 property transactions (shared on their own), deterministic record names, nothing queued when nothing
/// changed, rebuilt before each push when something they read changed. Synthetic data (`SharingFixture`).
final class AccountSummaryBuilderTests: XCTestCase {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day))!
    }
    private let today = day(2026, 10, 25)

    /// The fixture, with pay months closed by hand on the 25th of July, August and September 2026.
    private func household() throws -> (DatabaseQueue, SharingFixture) {
        let queue = try TestDatabase.migrated()
        let fixture = try queue.write { db -> SharingFixture in
            let fixture = try SharingFixture.build(db)
            for month in 7...9 { try PayCalendar.close(db: db, month: PayMonth(year: 2026, month: month), on: Self.day(2026, month, 25), today: today) }
            return fixture
        }
        return (queue, fixture)
    }

    @discardableResult
    private func addTransaction(_ db: Database, account: Int64, on date: Date, _ amount: Int, category: Int64?) throws -> Int64 {
        let batch = try Int64.fetchOne(db, sql: "SELECT importBatchId FROM transaction_ WHERE accountId = ? LIMIT 1", arguments: [account])!
        try db.execute(sql: """
            INSERT INTO transaction_(importBatchId, accountId, date, rawDescription, amountMinorUnits, categoryId, status, categorizedBy, fingerprint)
            VALUES (?, ?, ?, 'Synthetic', ?, ?, 'confirmed', 'rule', ?)
            """, arguments: [batch, account, date, amount, category, UUID().uuidString])
        return db.lastInsertedRowID
    }

    private func points(_ db: Database, _ account: Int64) throws -> [String: AccountBalancePoint] {
        Dictionary(uniqueKeysWithValues: try AccountBalancePoint.filter(Column("accountId") == account).fetchAll(db).map { ($0.payMonth, $0) })
    }

    private func totals(_ db: Database, _ account: Int64) throws -> [String: AccountSummaryMonth] {
        Dictionary(uniqueKeysWithValues: try AccountSummaryMonth.filter(Column("accountId") == account).fetchAll(db)
            .map { ("\($0.payMonth)/\($0.categoryId.map(String.init) ?? "none")", $0) })
    }

    /// Each summary row's record name and synced fields.
    private func records(_ db: Database) throws -> [String: [String: SyncValue]] {
        var result: [String: [String: SyncValue]] = [:]
        for table in [AccountBalancePoint.databaseTableName, AccountSummaryMonth.databaseTableName] {
            for row in try Row.fetchAll(db, sql: "SELECT localId, uuid FROM syncRecord WHERE tableName = ?", arguments: [table]) {
                let uuid: String = row["uuid"]
                let payload = try XCTUnwrap(SyncTranslator.outgoing(PendingChange(table: table, localId: row["localId"], uuid: uuid, kind: .update), db: db))
                result[uuid] = payload.fields
            }
        }
        return result
    }

    // MARK: Balance only

    func testBalanceOnlyPublishesPayMonthEndsAndCurrentOnly() throws {
        let (queue, f) = try household()
        try queue.write { db in
            try addTransaction(db, account: f.privateAccount, on: Self.day(2026, 7, 10), -1_000, category: f.plainCategory)
            try addTransaction(db, account: f.privateAccount, on: Self.day(2026, 8, 10), 2_000, category: f.plainCategory)
            try addTransaction(db, account: f.privateAccount, on: Self.day(2026, 8, 11), -500, category: f.plainCategory)
            try addTransaction(db, account: f.privateAccount, on: Self.day(2026, 10, 2), -300, category: f.plainCategory)

            try AccountSummaryBuilder.rebuild(ownerPersonId: f.personA, db: db, today: today)

            let calendar = try PayCalendar.load(db: db, today: today)
            let snapshots = try BalanceSnapshot.fetchAll(db)
            let transactions = try Transaction.fetchAll(db)
            let found = try points(db, f.privateAccount)
            // July to September (the last closed month) and now: no daily point, no point for the open month.
            XCTAssertEqual(Set(found.keys), ["2026-07", "2026-08", "2026-09", AccountBalancePoint.currentPayMonth])
            for month in 7...9 {
                let payMonth = PayMonth(year: 2026, month: month)
                let expected = try XCTUnwrap(NetWorthCalculator.balance(accountId: f.privateAccount, at: calendar.range(of: payMonth).end,
                                                                        snapshots: snapshots, transactions: transactions))
                let point = try XCTUnwrap(found[AccountSummaryBuilder.payMonthKey(payMonth)])
                XCTAssertEqual(point.balanceMinorUnits, expected.native)
                XCTAssertEqual(point.date, calendar.closeDate(of: payMonth))
            }
            XCTAssertEqual(found["2026-07"]?.balanceMinorUnits, -1_000)
            XCTAssertEqual(found["2026-08"]?.balanceMinorUnits, 500)
            let now = try XCTUnwrap(NetWorthCalculator.balance(accountId: f.privateAccount, at: nil, snapshots: snapshots, transactions: transactions))
            XCTAssertEqual(found[AccountBalancePoint.currentPayMonth]?.balanceMinorUnits, now.native)
            XCTAssertEqual(found[AccountBalancePoint.currentPayMonth]?.date, Self.day(2026, 10, 2))
            // Balance only: no category totals; the Totals account has both.
            XCTAssertEqual(try totals(db, f.privateAccount), [:])
            XCTAssertFalse(try points(db, f.totals).isEmpty)
            XCTAssertFalse(try totals(db, f.totals).isEmpty)
            // Everything accounts (and the joint one) have none.
            for account in [f.shared, f.joint, f.lisbon] {
                XCTAssertEqual(try points(db, account), [:])
                XCTAssertEqual(try totals(db, account), [:])
            }
            XCTAssertFalse(try AccountSummaryBuilder.isDirty(db: db))
        }
    }

    // MARK: Category totals

    func testCategoryTotalsExcludeSharedPropertyTransactions() throws {
        let (queue, f) = try household()
        try queue.write { db in
            // Private: a plain one, a property one (shared, §10), one pinned by a tax owner (shared) and the transfer in.
            try SharingLevels.set(.categoryTotals, accountId: f.privateAccount, actor: f.admin, db: db)
            let property = try addTransaction(db, account: f.totals, on: Self.day(2026, 9, 10), 70_000, category: f.propertyCategory)
            try addTransaction(db, account: f.totals, on: Self.day(2026, 9, 11), -100, category: nil)

            try AccountSummaryBuilder.rebuild(ownerPersonId: f.personA, db: db, today: today)

            let router = try SyncZoneRouter(db: db)
            for id in [property, f.privatePropertyTransaction, f.privatePinnedTransaction] {
                XCTAssertEqual(try router.assignment(table: "transaction_", localId: id).zone, SyncZones.household, "shared on its own")
            }
            let totalsRows = try totals(db, f.totals)
            XCTAssertEqual(Set(totalsRows.keys), ["2026-09/\(f.plainCategory)", "2026-09/none"])
            XCTAssertEqual(totalsRows["2026-09/\(f.plainCategory)"]?.amountMinorUnits, -3_000)
            XCTAssertEqual(totalsRows["2026-09/\(f.plainCategory)"]?.transactionCount, 1)
            XCTAssertEqual(totalsRows["2026-09/none"]?.amountMinorUnits, -100)

            let privateRows = try totals(db, f.privateAccount)
            XCTAssertEqual(Set(privateRows.keys), ["2026-09/\(f.plainCategory)", "2026-09/none"])
            XCTAssertEqual(privateRows["2026-09/\(f.plainCategory)"]?.amountMinorUnits, -4_000, "the pinned one is shared, not counted")
            XCTAssertEqual(privateRows["2026-09/\(f.plainCategory)"]?.transactionCount, 1)
            XCTAssertEqual(privateRows["2026-09/none"]?.amountMinorUnits, 10_000, "the transfer in stays private: counted")

            // The other person's actuals: the shared transactions plus the summaries count every transaction once.
            for account in [f.totals, f.privateAccount] {
                let shared = try Int64.fetchAll(db, sql: "SELECT id FROM transaction_ WHERE accountId = ?", arguments: [account])
                    .filter { try router.assignment(table: "transaction_", localId: $0).zone == SyncZones.household }
                let sharedTotal = try shared.reduce(0) { sum, id in
                    sum + (try Int.fetchOne(db, sql: "SELECT amountMinorUnits FROM transaction_ WHERE id = ?", arguments: [id]) ?? 0)
                }
                let summarised = try totals(db, account).values.reduce(0) { $0 + $1.amountMinorUnits }
                let all = try Int.fetchOne(db, sql: "SELECT SUM(amountMinorUnits) FROM transaction_ WHERE accountId = ?", arguments: [account]) ?? 0
                XCTAssertEqual(sharedTotal + summarised, all)
            }
        }
    }

    // MARK: Determinism and upkeep

    func testRebuildWithNoChangeQueuesNothing() throws {
        let (queue, f) = try household()
        try queue.write { db in
            let first = try AccountSummaryBuilder.rebuild(ownerPersonId: f.personA, db: db, today: today)
            XCTAssertGreaterThan(first.inserted, 0)
            // New rows are queued as inserts under their derived names.
            let queued = try SyncChangeTracker.pending(db: db).filter { $0.table == "accountBalancePoint" || $0.table == "accountSummaryMonth" }
            XCTAssertEqual(queued.count, first.inserted)
            XCTAssertTrue(queued.allSatisfy { $0.kind == .insert })
            try db.execute(sql: "DELETE FROM syncPending")

            XCTAssertEqual(try AccountSummaryBuilder.rebuild(ownerPersonId: f.personA, db: db, today: today), .init(inserted: 0, updated: 0, deleted: 0))
            XCTAssertEqual(try SyncChangeTracker.pending(db: db), [])
        }
    }

    func testTwoOwnerDevicesProduceIdenticalRecords() throws {
        let (mac, f) = try household()
        let other = try DatabaseQueue()
        try mac.backup(to: other)
        let built = try [mac, other].map { queue in
            try queue.write { db -> [String: [String: SyncValue]] in
                try AccountSummaryBuilder.rebuild(ownerPersonId: f.personA, db: db, today: today)
                return try records(db)
            }
        }
        XCTAssertFalse(built[0].isEmpty)
        XCTAssertEqual(built[0], built[1])
        // The names are the derived ones.
        try mac.read { db in
            let account = try XCTUnwrap(SyncRecordStore.existingUUID(table: "account", localId: f.privateAccount, db: db))
            let current = SyncRecordStore.derivedUUID(AccountSummaryBuilder.identity(table: "accountBalancePoint", accountUuid: account,
                                                                                     payMonth: AccountBalancePoint.currentPayMonth, categoryUuid: nil))
            XCTAssertNotNil(built[0][current])
        }
    }

    func testPayCalendarShiftRebuildsMonths() throws {
        let (queue, f) = try household()
        try queue.write { db in
            try addTransaction(db, account: f.totals, on: Self.day(2026, 8, 10), -1_000, category: f.plainCategory)
            try addTransaction(db, account: f.totals, on: Self.day(2026, 8, 23), -700, category: f.plainCategory)
            try AccountSummaryBuilder.rebuild(ownerPersonId: f.personA, db: db, today: today)
            XCTAssertEqual(try points(db, f.totals)["2026-08"]?.balanceMinorUnits, -1_700)
            XCTAssertEqual(try totals(db, f.totals)["2026-08/\(f.plainCategory)"]?.amountMinorUnits, -1_700)
            let before = try records(db)
            try db.execute(sql: "DELETE FROM syncPending")

            // August now closes on the 20th: the 23rd's spending moves into September.
            try PayCalendar.close(db: db, month: PayMonth(year: 2026, month: 8), on: Self.day(2026, 8, 20), today: today)
            XCTAssertTrue(try AccountSummaryBuilder.isDirty(db: db))
            let outcome = try AccountSummaryBuilder.rebuild(ownerPersonId: f.personA, db: db, today: today)
            XCTAssertEqual(outcome.inserted, 0)
            XCTAssertEqual(outcome.deleted, 0)
            XCTAssertEqual(outcome.updated, 3, "August's balance point and the August and September totals")

            let august = try XCTUnwrap(points(db, f.totals)["2026-08"])
            XCTAssertEqual(august.date, Self.day(2026, 8, 20))
            XCTAssertEqual(august.balanceMinorUnits, -1_000)
            XCTAssertEqual(try totals(db, f.totals)["2026-08/\(f.plainCategory)"]?.amountMinorUnits, -1_000)
            XCTAssertEqual(try totals(db, f.totals)["2026-09/\(f.plainCategory)"]?.amountMinorUnits, -3_700)
            XCTAssertEqual(try totals(db, f.totals)["2026-09/\(f.plainCategory)"]?.transactionCount, 2)
            // Same records, new values; only those are queued.
            let after = try records(db)
            XCTAssertEqual(Set(after.keys), Set(before.keys))
            XCTAssertEqual(try SyncChangeTracker.pending(db: db).filter { $0.table.hasPrefix("account") }.count, 3)
        }
    }

    func testRaisingToEverythingDeletesSummaries() throws {
        let (queue, f) = try household()
        try queue.write { db in
            try AccountSummaryBuilder.rebuild(ownerPersonId: f.personA, db: db, today: today)
            let names = try Set(String.fetchAll(db, sql: """
                SELECT s.uuid FROM syncRecord s JOIN accountSummaryMonth t ON s.tableName = 'accountSummaryMonth' AND s.localId = t.id
                WHERE t.accountId = ?
                UNION SELECT s.uuid FROM syncRecord s JOIN accountBalancePoint t ON s.tableName = 'accountBalancePoint' AND s.localId = t.id
                WHERE t.accountId = ?
                """, arguments: [f.totals, f.totals]))
            XCTAssertFalse(names.isEmpty)
            try db.execute(sql: "DELETE FROM syncPending")

            try SharingLevels.set(.everything, accountId: f.totals, actor: f.admin, db: db)
            let outcome = try AccountSummaryBuilder.rebuild(ownerPersonId: f.personA, db: db, today: today)
            XCTAssertEqual(outcome.deleted, names.count)
            XCTAssertEqual(try points(db, f.totals), [:])
            XCTAssertEqual(try totals(db, f.totals), [:])
            let deletes = try SyncChangeTracker.pending(db: db).filter { $0.kind == .delete }
            XCTAssertEqual(Set(deletes.map(\.uuid)), names)
            // Hidden has none either (written as it is: the fixture's links would block it).
            try db.execute(sql: "UPDATE account SET sharingLevel = 'hidden' WHERE id = ?", arguments: [f.privateAccount])
            try AccountSummaryBuilder.rebuild(ownerPersonId: f.personA, db: db, today: today)
            XCTAssertEqual(try points(db, f.privateAccount), [:])

            // Lowered again: the same records come back as inserts (their tombstones give way).
            try SharingLevels.set(.categoryTotals, accountId: f.totals, actor: f.admin, db: db)
            try AccountSummaryBuilder.rebuild(ownerPersonId: f.personA, db: db, today: today)
            let again = try SyncChangeTracker.pending(db: db).filter { names.contains($0.uuid) }
            XCTAssertEqual(Set(again.map(\.uuid)), names)
            XCTAssertTrue(again.allSatisfy { $0.kind == .insert })
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncTombstone WHERE uuid IN (\(names.map { "'\($0)'" }.joined(separator: ",")))"), 0)
        }
    }

    func testImportsDoNotCaptureSummaries() throws {
        let queue = try TestDatabase.migrated()
        try queue.read { db in
            let tracked = try ImportChangeCapture.trackedTables(db: db)
            XCTAssertFalse(tracked.contains("accountBalancePoint"))
            XCTAssertFalse(tracked.contains("accountSummaryMonth"))
        }
    }

    // MARK: Push

    /// Synchronous access (async tests would otherwise pick GRDB's async overloads).
    private func read<T>(_ queue: DatabaseQueue, _ body: (Database) throws -> T) throws -> T { try queue.read(body) }
    private func write<T>(_ queue: DatabaseQueue, _ body: (Database) throws -> T) throws -> T { try queue.write(body) }

    func testPushRebuildsWhenDirty() async throws {
        let h = try TwoPersonHousehold.make()
        let f = h.fixture
        try await h.syncAll()
        func memberTotal() throws -> Int? {
            let uuid = try read(h.adminMac.db) { db in
                try String.fetchOne(db, sql: """
                    SELECT s.uuid FROM syncRecord s JOIN accountSummaryMonth t ON s.tableName = 'accountSummaryMonth' AND s.localId = t.id
                    WHERE t.accountId = ? AND t.categoryId = ?
                    """, arguments: [f.totals, f.plainCategory])
            }
            guard let uuid else { return nil }
            return try read(h.memberDevice.db) { db in
                try Int.fetchOne(db, sql: """
                    SELECT t.amountMinorUnits FROM accountSummaryMonth t JOIN syncRecord s ON s.tableName = 'accountSummaryMonth' AND s.localId = t.id
                    WHERE s.uuid = ?
                    """, arguments: [uuid])
            }
        }
        XCTAssertEqual(try memberTotal(), -3_000, "the first push built and sent the summaries")
        XCTAssertFalse(try read(h.adminMac.db) { db in try AccountSummaryBuilder.isDirty(db: db) })

        try write(h.adminMac.db) { db in
            try db.execute(sql: "UPDATE transaction_ SET amountMinorUnits = -3500 WHERE id = ?", arguments: [f.totalsTransaction])
        }
        XCTAssertTrue(try read(h.adminMac.db) { db in try AccountSummaryBuilder.isDirty(db: db) })
        try await h.syncAll()
        XCTAssertEqual(try memberTotal(), -3_500)
        XCTAssertEqual(h.audit.householdViolations(router: h.adminRouter()), [])
        // The member's device owns nothing: its push builds nothing and is allowed.
        try await h.memberDevice.engine.pushPending()
        XCTAssertEqual(try read(h.memberDevice.db) { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncPending WHERE tableName LIKE 'account%'") }, 0)
    }

    func testRebuildOnDemoIsFast() throws {
        let queue = try TestDatabase.demo()
        try queue.write { db in
            let person = try Int64.fetchOne(db, sql: "SELECT id FROM person ORDER BY id LIMIT 1")!
            if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM appUser WHERE isAdmin = 1") == 0 {
                var admin = AppUser(personId: person, displayName: "A", isAdmin: true, createdAt: Date(timeIntervalSince1970: 0))
                try admin.insert(db)
            }
            let owner = try Int64.fetchOne(db, sql: "SELECT personId FROM appUser WHERE isAdmin = 1 ORDER BY id LIMIT 1")!
            let linked = Set(try Int64.fetchAll(db, sql: "SELECT accountId FROM propertyAccount"))
            let accounts = try Int64.fetchAll(db, sql: "SELECT id FROM account ORDER BY id")
            let unlinked = accounts.filter { !linked.contains($0) }
            XCTAssertGreaterThanOrEqual(unlinked.count, 2)
            try db.execute(sql: "UPDATE account SET ownerPersonId = ?, sharingLevel = 'everything'", arguments: [owner])
            try db.execute(sql: "UPDATE account SET sharingLevel = 'balanceOnly' WHERE id = ?", arguments: [unlinked[0]])
            try db.execute(sql: "UPDATE account SET sharingLevel = 'categoryTotals' WHERE id = ?", arguments: [unlinked[1]])
            try db.execute(sql: """
                INSERT INTO personSharing(personId, taxIncomeLevel, ownershipConfirmedAt) VALUES (?, 'everything', ?)
                ON CONFLICT(personId) DO UPDATE SET ownershipConfirmedAt = excluded.ownershipConfirmedAt
                """, arguments: [owner, Date(timeIntervalSince1970: 0)])

            let started = Date()
            let outcome = try AccountSummaryBuilder.rebuild(ownerPersonId: owner, db: db, today: today)
            let seconds = Date().timeIntervalSince(started)
            print("AccountSummaryBuilderTests: rebuilt \(outcome.inserted) demo summaries in \(String(format: "%.3f", seconds)) s")
            XCTAssertGreaterThan(outcome.inserted, 0)
            XCTAssertLessThan(seconds, 0.5)
        }
    }
}

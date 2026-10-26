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
            XCTAssertEqual(found[AccountBalancePoint.currentPayMonth]?.date, today, "dated at the publish day, not the latest activity")
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
            XCTAssertEqual(Set(privateRows.keys), ["2026-09/\(f.plainCategory)"], "the linked transfer in is hidden, as the budget hides it")
            XCTAssertEqual(privateRows["2026-09/\(f.plainCategory)"]?.amountMinorUnits, -4_000, "the pinned one is shared, not counted")
            XCTAssertEqual(privateRows["2026-09/\(f.plainCategory)"]?.transactionCount, 1)

            // Without transfers, the shared transactions plus the summaries count every transaction once.
            for account in [f.totals] {
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

            // CPU time of this thread (the write runs here), so a busy machine doesn't make it flake.
            let started = ThreadCPUTime.seconds()
            let outcome = try AccountSummaryBuilder.rebuild(ownerPersonId: owner, db: db, today: today)
            let seconds = ThreadCPUTime.seconds() - started
            print("AccountSummaryBuilderTests: rebuilt \(outcome.inserted) demo summaries in \(String(format: "%.3f", seconds)) s")
            XCTAssertGreaterThan(outcome.inserted, 0)
            XCTAssertLessThan(seconds, 0.5)
        }
    }

    // MARK: Fix round 1

    private struct Figure: Equatable { var amount = 0; var count = 0 }

    /// The owner's budget figures per pay month and category: confirmed, budget-facing transactions of every account.
    private func ownerBudget(_ db: Database) throws -> [String: Figure] {
        let calendar = try PayCalendar.load(db: db, today: today)
        var result: [String: Figure] = [:]
        for t in try Transaction.budgetFacing.fetchAll(db) where t.status == .confirmed {
            let key = "\(AccountSummaryBuilder.payMonthKey(calendar.month(containing: t.date)))/\(t.categoryId.map(String.init) ?? "none")"
            result[key, default: Figure()].amount += t.amountMinorUnits
            result[key, default: Figure()].count += 1
        }
        return result.filter { $0.value != Figure() }
    }

    /// What the other person counts: the household's transactions (less the incoming legs of the household's links)
    /// plus the category totals.
    private func memberBudget(_ db: Database) throws -> [String: Figure] {
        let calendar = try PayCalendar.load(db: db, today: today)
        let router = try SyncZoneRouter(db: db)
        let sharedLinks = try TransferLink.active.fetchAll(db).filter { try !router.assignment(table: "transferLink", localId: $0.id!).isPrivate }
        let hidden = Set(sharedLinks.map(\.inTransactionId))
        var result: [String: Figure] = [:]
        for t in try Transaction.fetchAll(db) where t.status == .confirmed && !hidden.contains(t.id!) {
            guard try !router.assignment(table: "transaction_", localId: t.id!).isPrivate else { continue }
            let key = "\(AccountSummaryBuilder.payMonthKey(calendar.month(containing: t.date)))/\(t.categoryId.map(String.init) ?? "none")"
            result[key, default: Figure()].amount += t.amountMinorUnits
            result[key, default: Figure()].count += 1
        }
        for row in try AccountSummaryMonth.fetchAll(db) {
            let key = "\(row.payMonth)/\(row.categoryId.map(String.init) ?? "none")"
            result[key, default: Figure()].amount += row.amountMinorUnits
            result[key, default: Figure()].count += row.transactionCount
        }
        return result.filter { $0.value != Figure() }
    }

    func testTransfersCountOnceForTheOtherPersonInBothDirections() throws {
        let (queue, f) = try household()
        try queue.write { db in
            try SharingLevels.set(.categoryTotals, accountId: f.privateAccount, actor: f.admin, db: db)
            // Shared → private is the fixture's transfer. Private → shared: sent from the private account, received on
            // the shared one, linked (the link follows the private leg into the private zone).
            let out = try addTransaction(db, account: f.privateAccount, on: Self.day(2026, 9, 12), -2_500, category: f.plainCategory)
            let into = try addTransaction(db, account: f.shared, on: Self.day(2026, 9, 12), 2_500, category: nil)
            var link = TransferLink(outTransactionId: out, inTransactionId: into, origin: .manual)
            try link.insert(db)
            let router = try SyncZoneRouter(db: db)
            XCTAssertTrue(try router.assignment(table: "transferLink", localId: link.id!).isPrivate)
            XCTAssertFalse(try router.assignment(table: "transaction_", localId: into).isPrivate)

            try AccountSummaryBuilder.rebuild(ownerPersonId: f.personA, db: db, today: today)

            let rows = try totals(db, f.privateAccount)
            XCTAssertEqual(rows["2026-09/\(f.plainCategory)"]?.amountMinorUnits, -6_500, "the sent leg counts")
            XCTAssertEqual(rows["2026-09/none"]?.amountMinorUnits, -2_500, "the shared received leg, taken back out")
            XCTAssertEqual(rows["2026-09/none"]?.transactionCount, -1)
            XCTAssertEqual(try memberBudget(db), try ownerBudget(db))

            // Unlinking (dismissing) counts both legs for both people: the summaries follow.
            try db.execute(sql: "UPDATE transferLink SET isDismissed = 1 WHERE id = ?", arguments: [link.id!])
            XCTAssertTrue(try AccountSummaryBuilder.isDirty(db: db))
            try AccountSummaryBuilder.rebuild(ownerPersonId: f.personA, db: db, today: today)
            XCTAssertNil(try totals(db, f.privateAccount)["2026-09/none"])
            XCTAssertEqual(try memberBudget(db), try ownerBudget(db))
        }
    }

    /// A euro account's totals also carry GBP, converted and rounded per transaction; a new rate rebuilds them.
    func testRateChangeRebuildsTheGBPTotals() throws {
        let (queue, f) = try household()
        try queue.write { db in
            try db.execute(sql: "UPDATE account SET currency = 'eur' WHERE id = ?", arguments: [f.totals])
            for amount in [-20, -20, -20] { try addTransaction(db, account: f.totals, on: Self.day(2026, 9, 10), amount, category: f.plainCategory) }
            var rate = ExchangeRateSetting(eurToGbpRate: 0.87, updatedAt: today)
            try rate.insert(db)
            try AccountSummaryBuilder.rebuild(ownerPersonId: f.personA, db: db, today: today)
            func september() throws -> AccountSummaryMonth { try XCTUnwrap(totals(db, f.totals)["2026-09/\(f.plainCategory)"]) }
            func perTransaction(_ rate: Double) -> Int {
                [-3_000, -20, -20, -20].map { Int((Double($0) * rate).rounded()) }.reduce(0, +)
            }
            XCTAssertEqual(try september().amountMinorUnits, -3_060)
            XCTAssertEqual(try september().gbpAmountMinorUnits, perTransaction(0.87))
            XCTAssertNotEqual(perTransaction(0.87), Int((Double(-3_060) * 0.87).rounded()), "the fixture rounds differently per transaction")

            try db.execute(sql: "DELETE FROM syncPending")
            var newer = ExchangeRateSetting(eurToGbpRate: 0.91, updatedAt: today.addingTimeInterval(60))
            try newer.insert(db)
            XCTAssertTrue(try AccountSummaryBuilder.isDirty(db: db))
            let outcome = try AccountSummaryBuilder.rebuild(ownerPersonId: f.personA, db: db, today: today)
            XCTAssertGreaterThan(outcome.updated, 0)
            XCTAssertEqual(try september().amountMinorUnits, -3_060)
            XCTAssertEqual(try september().gbpAmountMinorUnits, perTransaction(0.91))
            XCTAssertGreaterThan(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncPending WHERE tableName = 'accountSummaryMonth'")!, 0, "the new totals go up")
        }
    }

    func testAMemberWhoOwnsAnAccountPublishesItsSummaries() throws {
        let (queue, f) = try household()
        try queue.write { db in
            // The member (View on Budget & accounts) owns a Balance only account.
            try db.execute(sql: "UPDATE account SET ownerPersonId = ?, sharingLevel = 'balanceOnly' WHERE id = ?", arguments: [f.personB, f.totals])
            let outcome = try AccountSummaryBuilder.rebuild(ownerPersonId: f.personB, db: db, today: today)
            XCTAssertGreaterThan(outcome.inserted, 0)
            XCTAssertFalse(try points(db, f.totals).isEmpty)
            let member = try Int64.fetchOne(db, sql: "SELECT id FROM appUser WHERE personId = ?", arguments: [f.personB])!
            let memberUuid = try SyncRecordStore.uuid(for: "appUser", localId: member, db: db)
            let stamps = try Row.fetchAll(db, sql: """
                SELECT s.modifiedBy, s.origin FROM syncRecord s JOIN accountBalancePoint t ON s.tableName = 'accountBalancePoint' AND s.localId = t.id
                WHERE t.accountId = ?
                """, arguments: [f.totals])
            XCTAssertFalse(stamps.isEmpty)
            for stamp in stamps {
                XCTAssertEqual(stamp["modifiedBy"] as String?, memberUuid)
                XCTAssertEqual(stamp["origin"] as String?, WriteOrigin.system.rawValue)
            }
        }
    }

    func testCurrentBalanceIsRepublishedAtMostOnceADay() throws {
        let (queue, f) = try household()
        try queue.write { db in
            try AccountSummaryBuilder.rebuild(ownerPersonId: f.personA, db: db, today: today)
            let before = try XCTUnwrap(points(db, f.privateAccount)[AccountBalancePoint.currentPayMonth])
            try addTransaction(db, account: f.privateAccount, on: Self.day(2026, 10, 24), -900, category: f.plainCategory)

            // Later the same day: not republished; the account stays dirty.
            try AccountSummaryBuilder.rebuild(ownerPersonId: f.personA, db: db, today: today.addingTimeInterval(3_600))
            XCTAssertEqual(try points(db, f.privateAccount)[AccountBalancePoint.currentPayMonth], before)
            XCTAssertTrue(try AccountSummaryBuilder.isDirty(db: db))

            // The next day: published, dated that day.
            let tomorrow = today.addingTimeInterval(86_400 + 3_600)
            try AccountSummaryBuilder.rebuild(ownerPersonId: f.personA, db: db, today: tomorrow)
            let after = try XCTUnwrap(points(db, f.privateAccount)[AccountBalancePoint.currentPayMonth])
            XCTAssertEqual(after.balanceMinorUnits, before.balanceMinorUnits - 900)
            XCTAssertEqual(after.date, Self.day(2026, 10, 26))
            XCTAssertFalse(try AccountSummaryBuilder.isDirty(db: db))

            // An unchanged balance keeps its day.
            try db.execute(sql: "UPDATE account SET name = 'Synthetic private renamed' WHERE id = ?", arguments: [f.privateAccount])
            try AccountSummaryBuilder.rebuild(ownerPersonId: f.personA, db: db, today: tomorrow.addingTimeInterval(86_400))
            XCTAssertEqual(try points(db, f.privateAccount)[AccountBalancePoint.currentPayMonth]?.date, Self.day(2026, 10, 26))
        }
    }

    func testOnlyAccountsWhoseDataChangedAreRebuilt() throws {
        let (queue, f) = try household()
        try queue.write { db in
            try AccountSummaryBuilder.rebuild(ownerPersonId: f.personA, db: db, today: today)
            // A stand-in for a stale value: the summary tables mark nothing dirty.
            try db.execute(sql: "UPDATE accountBalancePoint SET balanceMinorUnits = 999 WHERE accountId = ? AND payMonth = '2026-09'",
                           arguments: [f.privateAccount])
            XCTAssertFalse(try AccountSummaryBuilder.isDirty(db: db))

            try db.execute(sql: "UPDATE transaction_ SET amountMinorUnits = -3500 WHERE id = ?", arguments: [f.totalsTransaction])
            let keys = try String.fetchAll(db, sql: "SELECT key FROM syncState WHERE key LIKE 'summaries.dirty%'")
            XCTAssertEqual(keys, ["summaries.dirty.\(f.totals)"])
            try AccountSummaryBuilder.rebuild(ownerPersonId: f.personA, db: db, today: today)
            XCTAssertEqual(try totals(db, f.totals)["2026-09/\(f.plainCategory)"]?.amountMinorUnits, -3_500)
            XCTAssertEqual(try points(db, f.privateAccount)["2026-09"]?.balanceMinorUnits, 999, "the private account wasn't rebuilt")

            // A transfer link marks both legs' accounts.
            try db.execute(sql: "UPDATE transferLink SET isDismissed = 1 WHERE id = ?", arguments: [f.transferLink])
            // (Totals is still dirty: its changed current balance waits for tomorrow.)
            XCTAssertEqual(Set(try String.fetchAll(db, sql: "SELECT key FROM syncState WHERE key LIKE 'summaries.dirty%'")),
                           ["summaries.dirty.\(f.shared)", "summaries.dirty.\(f.privateAccount)", "summaries.dirty.\(f.totals)"])
            try AccountSummaryBuilder.rebuild(ownerPersonId: f.personA, db: db, today: today)
            XCTAssertNotEqual(try points(db, f.privateAccount)["2026-09"]?.balanceMinorUnits, 999)

            // A category change rebuilds every account.
            try db.execute(sql: "UPDATE accountBalancePoint SET balanceMinorUnits = 999 WHERE accountId = ? AND payMonth = '2026-09'", arguments: [f.totals])
            try db.execute(sql: "UPDATE category SET name = 'Synthetic food' WHERE id = ?", arguments: [f.plainCategory])
            try AccountSummaryBuilder.rebuild(ownerPersonId: f.personA, db: db, today: today)
            XCTAssertNotEqual(try points(db, f.totals)["2026-09"]?.balanceMinorUnits, 999)
        }
    }

    func testTenYearsOfSixAccountsRebuildsInUnderASecond() throws {
        let queue = try TestDatabase.migrated()
        let (owner, accounts) = try queue.write { db -> (Int64, [Int64]) in
            let f = try SharingFixture.build(db)
            var accounts: [Int64] = []
            for index in 0..<6 {
                let account = try AccountEditing.add(db: db, name: "Synthetic ten-year \(index)", currency: .gbp, kind: .cash,
                                                     openingBalanceEntered: 1_000_00, asOf: Self.day(2016, 10, 1), owner: f.admin).id!
                try db.execute(sql: "UPDATE account SET sharingLevel = ? WHERE id = ?",
                               arguments: [index % 2 == 0 ? "categoryTotals" : "balanceOnly", account])
                accounts.append(account)
            }
            var batches: [Int64] = []
            for account in accounts {
                try db.execute(sql: "INSERT INTO importBatch(accountId, sourceFileName, importedAt) VALUES (?, 'synthetic.csv', ?)",
                               arguments: [account, Self.day(2026, 10, 1)])
                batches.append(db.lastInsertedRowID)
            }
            var year = 2016, month = 10
            var serial = 0
            let insert = try db.makeStatement(sql: """
                INSERT INTO transaction_(importBatchId, accountId, date, rawDescription, amountMinorUnits, categoryId, status, categorizedBy, fingerprint)
                VALUES (?, ?, ?, 'Synthetic', ?, ?, 'confirmed', 'rule', ?)
                """)
            for _ in 0..<120 {
                try db.execute(sql: "INSERT INTO payMonthClose(year, month, closeDate) VALUES (?, ?, ?)", arguments: [year, month, Self.day(year, month, 25)])
                for n in 0..<400 {
                    serial += 1
                    let index = n % 6
                    try insert.execute(arguments: [batches[index], accounts[index], Self.day(year, month, 1 + n % 28), -(100 + n),
                                                   n % 5 == 0 ? nil : f.plainCategory, "ten-\(serial)"])
                }
                month += 1
                if month > 12 { month = 1; year += 1 }
            }
            return (f.personA, accounts)
        }
        try queue.write { db in
            // The thread's CPU time, not the wall clock: other work on the machine (`--parallel`) never makes it flake.
            let started = ThreadCPUTime.seconds()
            let outcome = try AccountSummaryBuilder.rebuild(ownerPersonId: owner, db: db, today: today)
            let seconds = ThreadCPUTime.seconds() - started
            print("AccountSummaryBuilderTests: ten years, 48,000 transactions, \(outcome.inserted) summaries in \(String(format: "%.3f", seconds)) s of CPU")
            XCTAssertGreaterThan(try AccountBalancePoint.filter(accounts.contains(Column("accountId"))).fetchCount(db), 6 * 119)
            XCTAssertLessThan(seconds, 1)
        }
    }

    func testRebuildErrorsNameTheSummaries() throws {
        let (queue, f) = try household()
        try queue.write { db in
            try db.execute(sql: "CREATE TEMP TRIGGER refuse BEFORE INSERT ON accountBalancePoint BEGIN SELECT RAISE(ABORT, 'refused'); END")
            XCTAssertThrowsError(try AccountSummaryBuilder.rebuild(ownerPersonId: f.personA, db: db, today: today)) { error in
                XCTAssertTrue(error is AccountSummaryBuilder.BuildError)
                XCTAssertTrue((error as? LocalizedError)?.errorDescription?.contains("account summaries") == true)
            }
        }
    }

    // MARK: Two owner devices

    /// Both owner devices' and the member's summary records: record name → synced fields.
    private func summaryRecords(_ queue: DatabaseQueue) throws -> [String: [String: SyncValue]] {
        try queue.read { db in try records(db) }
    }

    func testTwoOwnerDevicesConvergeAfterRaisingAndLoweringAgain() async throws {
        for rebuildBeforePull in [false, true] {
            let h = try TwoPersonHousehold.make()
            let f = h.fixture
            try await h.syncAll()
            try await h.adminMac2.engine.pull()
            let first = try summaryRecords(h.adminMac.db)
            XCTAssertFalse(first.isEmpty)

            // Raised to Everything on the Mac: its summaries are deleted everywhere.
            try write(h.adminMac.db) { db in try SharingLevels.set(.everything, accountId: f.totals, actor: f.admin, db: db) }
            try await h.adminMac.engine.pushPending()
            try await h.adminMac2.engine.syncNow()
            try await h.memberDevice.engine.pull()
            let totalsUuid = try h.uuid("account", f.totals)
            for device in [h.adminMac.db, h.adminMac2.db, h.memberDevice.db] {
                let left = try read(device) { db -> Int in
                    guard let id = try SyncRecordStore.localId(table: "account", uuid: totalsUuid, db: db) else { return -1 }
                    return try Int.fetchOne(db, sql: "SELECT (SELECT COUNT(*) FROM accountBalancePoint WHERE accountId = ?) + (SELECT COUNT(*) FROM accountSummaryMonth WHERE accountId = ?)",
                                            arguments: [id, id]) ?? -1
                }
                XCTAssertEqual(left, 0)
            }

            // Lowered again.
            if rebuildBeforePull {
                // On both owner devices before either hears of the other: the second rebuilds before it pulls.
                for device in [h.adminMac, h.adminMac2] {
                    try write(device.db) { db in
                        try SharingLevels.set(.categoryTotals, accountId: try XCTUnwrap(SyncRecordStore.localId(table: "account", uuid: totalsUuid, db: db)),
                                              actor: try AccessActor.admin(db: db), db: db)
                    }
                }
                try await h.adminMac.engine.pushPending()
                try await h.adminMac2.engine.pushPending()
                try await h.adminMac2.engine.pull()
            } else {
                // On the Mac; the second Mac pulls first (its tombstones discard the records), then rebuilds.
                try write(h.adminMac.db) { db in try SharingLevels.set(.categoryTotals, accountId: f.totals, actor: f.admin, db: db) }
                try await h.adminMac.engine.pushPending()
                try await h.adminMac2.engine.syncNow()
            }
            for _ in 0..<2 {
                try await h.adminMac.engine.syncNow()
                try await h.adminMac2.engine.syncNow()
            }
            try await h.memberDevice.engine.pull()

            let label = rebuildBeforePull ? "rebuild before pull" : "pull before rebuild"
            let mac = try summaryRecords(h.adminMac.db)
            XCTAssertEqual(mac, first, label)
            XCTAssertEqual(try summaryRecords(h.adminMac2.db), mac, label)
            XCTAssertEqual(try summaryRecords(h.memberDevice.db), mac, label)
            for device in [h.adminMac.db, h.adminMac2.db, h.memberDevice.db] {
                XCTAssertEqual(try read(device) { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncStaging") }, 0, label)
            }
            for device in [h.adminMac.db, h.adminMac2.db] {
                XCTAssertEqual(try read(device) { db in try SyncChangeTracker.pending(db: db) }, [], label)
            }
            XCTAssertEqual(h.audit.householdViolations(router: h.adminRouter()), [], label)
            XCTAssertEqual(h.audit2.householdViolations(router: TwoPersonHousehold.router(h.adminMac2.db)), [], label)
        }
    }
}

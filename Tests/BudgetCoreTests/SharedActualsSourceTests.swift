import XCTest
import GRDB
@testable import BudgetCore
import TestSupport

/// The other person's actuals (sync spec §6.1 "How totals count", sharing spec §3 goal 6): the transactions they
/// hold plus the summaries of accounts they can't see in full, read through `SharedActualsSource`, give the same
/// budget figures and balances as the owner's full data, for everything each level allows.
final class SharedActualsSourceTests: XCTestCase {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    /// The engine's rebuild runs on the real clock, so the readers do too.
    private static let today = Date()

    private struct Extras {
        var hidden: Int64
        var income: Int64
    }

    @discardableResult
    private static func addTransaction(_ db: Database, account: Int64, on date: Date, _ amount: Int, category: Int64?) throws -> Int64 {
        let batch = try Int64.fetchOne(db, sql: "SELECT importBatchId FROM transaction_ WHERE accountId = ? LIMIT 1", arguments: [account])!
        try db.execute(sql: """
            INSERT INTO transaction_(importBatchId, accountId, date, rawDescription, amountMinorUnits, categoryId, status, categorizedBy, fingerprint)
            VALUES (?, ?, ?, 'Synthetic', ?, ?, 'confirmed', 'rule', ?)
            """, arguments: [batch, account, date, amount, category, UUID().uuidString])
        return db.lastInsertedRowID
    }

    private static func link(_ db: Database, out: Int64, into: Int64) throws {
        var link = TransferLink(outTransactionId: out, inTransactionId: into, origin: .manual)
        try link.insert(db)
    }

    /// `SharingFixture` plus: salaries into the Category totals account (so the pay months are paydays only the
    /// owner's data holds), its spending around the paydays and in the open month, a property-category payment
    /// (shared, §10), transfers both ways between it and a shared account, an opening balance on the Balance only
    /// account, and a Hidden account of A's. Synced: the Mac rebuilds the summaries and pushes, the member pulls.
    private static func household() async throws -> (TwoPersonHousehold, Extras) {
        let h = try TwoPersonHousehold.make()
        let f = h.fixture
        let extras = try await h.adminMac.db.write { db -> Extras in
            try db.execute(sql: "INSERT INTO category(name, type) VALUES ('Income', 'income')")
            let income = db.lastInsertedRowID
            for month in 7...10 {
                try Self.addTransaction(db, account: f.totals, on: Self.day(2026, month, month == 10 ? 23 : 25, hour: 0), 300_000, category: income)
            }
            for (month, dayOfMonth, amount) in [(8, 2, -1_200), (8, 25, -800), (8, 26, -650), (9, 10, -2_300), (9, 25, -410), (10, 23, -90), (10, 24, -333)] {
                try Self.addTransaction(db, account: f.totals, on: Self.day(2026, month, dayOfMonth), amount, category: f.plainCategory)
            }
            try Self.addTransaction(db, account: f.totals, on: Self.day(2026, 9, 3), 12_000, category: f.propertyCategory)
            // Private → shared: sent from Totals, received (categorised) on Shared.
            try Self.link(db, out: try Self.addTransaction(db, account: f.totals, on: Self.day(2026, 9, 12), -2_500, category: f.plainCategory),
                     into: try Self.addTransaction(db, account: f.shared, on: Self.day(2026, 9, 12), 2_500, category: f.plainCategory))
            // Shared → private: sent from Shared, received (categorised) on Totals.
            try Self.link(db, out: try Self.addTransaction(db, account: f.shared, on: Self.day(2026, 8, 14), -1_500, category: f.plainCategory),
                     into: try Self.addTransaction(db, account: f.totals, on: Self.day(2026, 8, 14), 1_500, category: f.plainCategory))
            try db.execute(sql: "INSERT INTO balanceSnapshot(accountId, date, balanceMinorUnits) VALUES (?, ?, 50000)",
                           arguments: [f.privateAccount, Self.day(2026, 7, 1, hour: 0)])
            try Self.addTransaction(db, account: f.privateAccount, on: Self.day(2026, 8, 3), -700, category: f.plainCategory)

            let hidden = try AccountEditing.add(db: db, name: "Synthetic hidden", currency: .gbp, kind: .cash, openingBalanceEntered: 77_700,
                                                asOf: Self.day(2026, 7, 1, hour: 0)).id!
            try db.execute(sql: "UPDATE account SET ownerPersonId = ?, sharingLevel = 'hidden' WHERE id = ?", arguments: [f.personA, hidden])
            try db.execute(sql: "INSERT INTO importBatch(accountId, sourceFileName, importedAt) VALUES (?, 'synthetic.csv', ?)",
                           arguments: [hidden, Self.day(2026, 7, 1)])
            try db.execute(sql: """
                INSERT INTO transaction_(importBatchId, accountId, date, rawDescription, amountMinorUnits, categoryId, status, categorizedBy, fingerprint)
                VALUES (?, ?, ?, 'Synthetic', -6100, ?, 'confirmed', 'rule', 'fp-hidden')
                """, arguments: [db.lastInsertedRowID, hidden, Self.day(2026, 9, 2), f.plainCategory])
            return Extras(hidden: hidden, income: income)
        }
        try await h.syncAll()
        return (h, extras)
    }

    private static func viewer(_ device: TwoPersonHousehold.Device, admin: Bool) throws -> SharingViewer {
        try device.db.read { db in
            let user = try XCTUnwrap(AppUser.filter(Column("isAdmin") == admin).fetchOne(db))
            return try SharingViewer.load(appUserId: user.id, db: db)
        }
    }

    // MARK: Budget figures

    /// The Budget grid's figures from `source`: its pay calendar (paydays from the transactions it loads), the
    /// transfer rule, GBP and `PayMonthTotals`, keyed by category name then "year-month", zeros left out.
    private static func gridTotals(_ db: Database, _ source: any ActualsSource, leavingOut: Set<Int64> = []) throws -> [String: [String: Int]] {
        let transactions = try source.transactions(db)
        let categories = try Category.fetchAll(db)
        let calendar = PayCalendar(salaryDates: PaydaySource.paydayDates(transactions: transactions, categories: categories),
                                   manualCloses: try PayMonthClose.fetchAll(db), today: Self.today)
        let facing = TransferLinks.budgetFacing(transactions, links: try TransferLink.fetchAll(db)).filter { !leavingOut.contains($0.id!) }
        let gbp = CurrencyConversion(accounts: try Account.fetchAll(db), rate: try ExchangeRateSetting.currentOrDefault(db: db)).toGBP(facing)
        let names = Dictionary(uniqueKeysWithValues: categories.map { ($0.id!, $0.name) })
        var result: [String: [String: Int]] = [:]
        for (category, years) in PayMonthTotals.lookup(transactions: gbp, calendar: calendar) {
            for (year, months) in years {
                for (month, amount) in months where amount != 0 {
                    result[names[category]!, default: [:]][String(format: "%04d-%02d", year, month)] = amount
                }
            }
        }
        return result
    }

    private static func closeDates(_ db: Database, _ source: any ActualsSource) throws -> [Date] {
        let transactions = try source.transactions(db)
        let calendar = PayCalendar(salaryDates: PaydaySource.paydayDates(transactions: transactions, categories: try Category.fetchAll(db)),
                                   manualCloses: try PayMonthClose.fetchAll(db), today: Self.today)
        return (6...11).map { calendar.closeDate(of: PayMonth(year: 2026, month: $0)) }
    }

    func testGridTotalsWithSummariesEqualFullData() async throws {
        let (h, extras) = try await Self.household()
        let f = h.fixture
        let admin = try Self.viewer(h.adminMac, admin: true)
        let member = try Self.viewer(h.memberDevice, admin: false)

        let (owner, ownerCloses) = try await h.adminMac.db.read { db -> ([String: [String: Int]], [Date]) in
            // Balance only shares no categories: its transactions the router keeps private are what the member can't
            // count. Hidden shares nothing.
            let router = try SyncZoneRouter(db: db)
            let balanceOnlyPrivate = try Set(Int64.fetchAll(db, sql: "SELECT id FROM transaction_ WHERE accountId = ?", arguments: [f.privateAccount])
                .filter { try router.assignment(table: "transaction_", localId: $0).isPrivate })
            XCTAssertFalse(balanceOnlyPrivate.isEmpty)
            let hidden = try Set(Int64.fetchAll(db, sql: "SELECT id FROM transaction_ WHERE accountId = ?", arguments: [extras.hidden]))
            XCTAssertFalse(hidden.isEmpty)
            return (try Self.gridTotals(db, SharedActualsSource(viewer: admin), leavingOut: balanceOnlyPrivate.union(hidden)), try Self.closeDates(db, SharedActualsSource(viewer: admin)))
        }
        let (others, memberCloses) = try await h.memberDevice.db.read { db in
            (try Self.gridTotals(db, SharedActualsSource(viewer: member)), try Self.closeDates(db, SharedActualsSource(viewer: member)))
        }
        XCTAssertEqual(memberCloses, ownerCloses, "the member's pay months end on the owner's paydays")
        XCTAssertEqual(ownerCloses[2], Self.day(2026, 8, 25, hour: 0))
        XCTAssertEqual(others, owner)
        XCTAssertEqual(owner["Income"]?["2026-09"], 300_000)
        XCTAssertNotNil(owner["Synthetic flat rent"]?["2026-09"], "property money of private accounts counts (§10)")

        // Without the summaries the member's figures would differ.
        let withoutSummaries = try await h.memberDevice.db.read { db in try Self.gridTotals(db, LocalActualsSource()) }
        XCTAssertNotEqual(withoutSummaries, owner)
    }

    // MARK: Drill-down

    func testDrillDownListsSharedThenOneLinePerPrivateAccount() async throws {
        let h = try TwoPersonHousehold.make()
        let f = h.fixture
        try await h.adminMac.db.write { db in
            try db.execute(sql: "UPDATE account SET alias = 'Private' WHERE id = ?", arguments: [f.totals])
            for dayOfMonth in 1...6 { try Self.addTransaction(db, account: f.totals, on: Self.day(2026, 9, dayOfMonth), -100 * dayOfMonth, category: f.plainCategory) }
            try Self.addTransaction(db, account: f.totals, on: Self.day(2026, 9, 7), -999, category: f.propertyCategory)
        }
        try await h.syncAll()
        let member = try Self.viewer(h.memberDevice, admin: false)
        let expectedShared = try Set([f.sharedTransaction, f.jointTransaction, f.privatePinnedTransaction].map { try h.uuid("transaction_", $0) })

        try await h.memberDevice.db.read { db in
            let plain = try XCTUnwrap(SyncRecordStore.localId(table: "category", uuid: try h.uuid("category", f.plainCategory), db: db))
            let totals = try XCTUnwrap(SyncRecordStore.localId(table: "account", uuid: try h.uuid("account", f.totals), db: db))
            let transactions = try SharedActualsSource(viewer: member).transactions(db)
            let calendar = PayCalendar(salaryDates: PaydaySource.paydayDates(transactions: transactions, categories: try Category.fetchAll(db)),
                                       manualCloses: try PayMonthClose.fetchAll(db), today: Self.today)
            let september = calendar.range(of: PayMonth(year: 2026, month: 9))

            // The cell's shared transactions: the summaries aren't among them.
            let shared = transactions.filter { !SharedActuals.isSummary($0) && $0.categoryId == plain && $0.date >= september.start && $0.date <= september.end }
            XCTAssertEqual(Set(try shared.map { try XCTUnwrap(SyncRecordStore.existingUUID(table: "transaction_", localId: $0.id!, db: db)) }), expectedShared)
            XCTAssertTrue(transactions.contains { SharedActuals.isSummary($0) && $0.categoryId == plain })

            // Then one line per private account.
            let lines = try SharedActuals.privateLines(categoryIds: [plain], from: september.start, to: september.end, viewer: member, db: db)
            XCTAssertEqual(lines, [SharedActuals.PrivateLine(id: totals, text: "Private (A) · 7 transactions · details private", amountMinorUnits: -3_000 - 2_100)])
            // The cell's figure is the shared transactions plus the lines.
            let cell = transactions.filter { $0.categoryId == plain && $0.date >= september.start && $0.date <= september.end }.map(\.amountMinorUnits).reduce(0, +)
            XCTAssertEqual(cell, shared.map(\.amountMinorUnits).reduce(0, +) + lines.map(\.amountMinorUnits).reduce(0, +))
            // Another month or category: no line.
            XCTAssertEqual(try SharedActuals.privateLines(categoryIds: [plain], from: september.end.addingTimeInterval(1), to: september.end.addingTimeInterval(86_400 * 20),
                                                          viewer: member, db: db), [])
        }
        // The owner's own accounts have no private lines on the owner's Mac.
        let admin = try Self.viewer(h.adminMac, admin: true)
        try await h.adminMac.db.read { db in
            XCTAssertEqual(try SharedActuals.privateLines(categoryIds: [f.plainCategory], from: .distantPast, to: .distantFuture, viewer: admin, db: db), [])
        }
    }

    // MARK: Net worth

    func testNetWorthCountsBalanceOnlyAndTotalsButNotHidden() async throws {
        let (h, extras) = try await Self.household()
        let f = h.fixture
        let member = try Self.viewer(h.memberDevice, admin: false)
        let hiddenUuid = try h.uuid("account", extras.hidden)
        let owner = try await h.adminMac.db.read { db in try DashboardInput.load(db: db, today: Self.today) }
        let others = try await h.memberDevice.db.read { db in try DashboardInput.load(db: db, today: Self.today, actuals: SharedActualsSource(viewer: member)) }

        // Each account the member can see, its balance now and at the end of every closed pay month, as the owner has it.
        let ownerCalendar = try await h.adminMac.db.read { db in try PayCalendar.load(db: db, today: Self.today) }
        let ends = (7...10).map { ownerCalendar.range(of: PayMonth(year: 2026, month: $0)).end }
        for account in [f.privateAccount, f.totals, f.shared, f.joint, f.lisbon] {
            let uuid = try h.uuid("account", account)
            let found = try await h.memberDevice.db.read { db in try SyncRecordStore.localId(table: "account", uuid: uuid, db: db) }
            let local = try XCTUnwrap(found)
            for end in ends + [nil] as [Date?] {
                let expected = NetWorthCalculator.balance(accountId: account, at: end, snapshots: owner.snapshots, transactions: owner.transactions)?.native
                let seen = NetWorthCalculator.balance(accountId: local, at: end, snapshots: others.snapshots, transactions: others.transactions)?.native
                XCTAssertEqual(seen, expected, "account \(account) at \(String(describing: end))")
            }
        }

        // Hidden: absent, so the member's net worth is the owner's without it.
        try await h.memberDevice.db.read { db in
            XCTAssertNil(try SyncRecordStore.localId(table: "account", uuid: hiddenUuid, db: db))
        }
        func netWorth(_ input: DashboardInput) -> Int {
            NetWorthCalculator.accountBalances(accounts: input.accounts.filter(\.includeInNetWorth), snapshots: input.snapshots,
                                               transactions: input.transactions, rate: input.rate).map(\.gbpBalanceMinorUnits).reduce(0, +)
        }
        let hiddenBalance = NetWorthCalculator.balance(accountId: extras.hidden, at: nil, snapshots: owner.snapshots, transactions: owner.transactions)!.native
        XCTAssertEqual(hiddenBalance, 77_700 - 6_100)
        XCTAssertEqual(netWorth(others), netWorth(owner) - hiddenBalance)

        // The same accounts on the member's device without summaries: the totals and balance only accounts are missing.
        let local = try await h.memberDevice.db.read { db in try DashboardInput.load(db: db, today: Self.today) }
        XCTAssertNotEqual(netWorth(local), netWorth(others))

        // A Hidden account of the other person's that a device holds anyway contributes nothing.
        try await h.adminMac.db.read { db in
            let asMember = SharingViewer(personId: f.personB)
            XCTAssertFalse(try SharedActualsSource(viewer: asMember).transactions(db).contains { $0.accountId == extras.hidden })
            XCTAssertFalse(try SharedActualsSource(viewer: asMember).balanceSnapshots(db).contains { $0.accountId == extras.hidden })
        }
    }

    // MARK: The owner and tools

    func testOwnerSeesOwnAccountsInFull() async throws {
        let (h, _) = try await Self.household()
        let admin = try Self.viewer(h.adminMac, admin: true)
        try await h.adminMac.db.read { db in
            XCTAssertGreaterThan(try AccountSummaryMonth.fetchCount(db), 0, "the Mac holds its own summaries")
            let source = SharedActualsSource(viewer: admin)
            let transactions = try source.transactions(db)
            XCTAssertFalse(transactions.contains(where: SharedActuals.isSummary))
            XCTAssertEqual(transactions, try LocalActualsSource().transactions(db))
            XCTAssertEqual(try source.balanceSnapshots(db), try BalanceSnapshot.fetchAll(db))
            let viaSource = try DashboardInput.load(db: db, today: Self.today, actuals: source), local = try DashboardInput.load(db: db, today: Self.today)
            XCTAssertEqual(viaSource.transactions, local.transactions)
            XCTAssertEqual(viaSource.snapshots, local.snapshots)
            for account in try Account.fetchAll(db) where account.ownerPersonId == admin.personId || account.ownerPersonId == nil {
                XCTAssertTrue(admin.seesInFull(account))
            }
        }
        // The member, too, sees her own (none here), joint and Everything accounts in full, and A's others not.
        let member = try Self.viewer(h.memberDevice, admin: false)
        try await h.memberDevice.db.read { db in
            let levels = try Account.fetchAll(db).map { ($0.sharingLevel, member.seesInFull($0)) }
            XCTAssertTrue(levels.allSatisfy { $0.0 == .everything ? $0.1 : !$0.1 })
            XCTAssertTrue(levels.contains { !$0.1 })
        }
    }

    func testNilViewerIsToday() async throws {
        let (h, _) = try await Self.household()
        let anyone = try await h.memberDevice.db.read { db in try SharingViewer.load(appUserId: nil, db: db) }
        XCTAssertNil(anyone.personId)
        for device in [h.adminMac, h.memberDevice] {
            try await device.db.read { db in
                let source = SharedActualsSource(viewer: anyone)
                XCTAssertEqual(try source.transactions(db), try LocalActualsSource().transactions(db))
                XCTAssertEqual(try source.balanceSnapshots(db), try LocalActualsSource().balanceSnapshots(db))
                XCTAssertTrue(try Account.fetchAll(db).allSatisfy(anyone.seesInFull))
            }
        }
    }

    /// The owner reads through the shared source at no extra cost: on the demo, the same rows as the local source,
    /// in about the same time.
    func testOwnerReadOnDemoIsAsFastAsLocal() throws {
        let queue = try TestDatabase.demo()
        try queue.read { db in
            let viewer = try SharingViewer.load(appUserId: try AppUser.filter(Column("isAdmin") == true).fetchOne(db)?.id, db: db)
            let shared = SharedActualsSource(viewer: viewer)
            XCTAssertEqual(try shared.transactions(db), try LocalActualsSource().transactions(db))
            func time(_ body: () throws -> Void) rethrows -> TimeInterval {
                var best = TimeInterval.infinity
                for _ in 0..<5 {
                    let start = Date()
                    try body()
                    best = min(best, Date().timeIntervalSince(start))
                }
                return best
            }
            let local = try time { _ = try DashboardInput.load(db: db, today: Self.today) }
            let viaShared = try time { _ = try DashboardInput.load(db: db, today: Self.today, actuals: shared) }
            print("SharedActualsSourceTests: demo dashboard load local \(local)s, shared (owner) \(viaShared)s")
            XCTAssertLessThan(viaShared, local * 1.5 + 0.02)
        }
    }
}

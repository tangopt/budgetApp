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
        /// A's card at Category totals with plain spending only: the member holds nothing of it but its summaries.
        var card: Int64
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
    /// `salaryInBalanceOnly`: the salaries go into the Balance only account instead, so no summary carries them.
    /// `totalsInEuros`: the Category totals account holds euros. `levels`: as `TwoPersonHousehold.make`.
    private static func household(salaryInBalanceOnly: Bool = false, totalsInEuros: Bool = false,
                                  levels: [Int64: SharingLevel] = [:]) async throws -> (TwoPersonHousehold, Extras) {
        let h = try TwoPersonHousehold.make(levels: levels)
        let f = h.fixture
        let extras = try await h.adminMac.db.write { db -> Extras in
            if totalsInEuros {
                try db.execute(sql: "UPDATE account SET currency = 'eur' WHERE id = ?", arguments: [f.totals])
            }
            // The latest activity anywhere: a shared payment just now.
            try Self.addTransaction(db, account: f.shared, on: Self.today.addingTimeInterval(-1), -42, category: f.plainCategory)
            try db.execute(sql: "INSERT INTO category(name, type) VALUES ('Income', 'income')")
            let income = db.lastInsertedRowID
            for month in 7...10 {
                try Self.addTransaction(db, account: salaryInBalanceOnly ? f.privateAccount : f.totals, on: Self.day(2026, month, month == 10 ? 23 : 25, hour: 0),
                                        300_000, category: income)
            }
            // A small Income credit in the open month (after the 23 October payday): no payday for the owner.
            try Self.addTransaction(db, account: f.totals, on: Self.day(2026, 10, 25), 700, category: income)
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
            let card = try AccountEditing.add(db: db, name: "Synthetic card", currency: .gbp, kind: .cash, openingBalanceEntered: nil,
                                              asOf: Self.day(2026, 7, 1, hour: 0)).id!
            try db.execute(sql: "UPDATE account SET ownerPersonId = ?, sharingLevel = 'categoryTotals' WHERE id = ?", arguments: [f.personA, card])
            try db.execute(sql: "INSERT INTO importBatch(accountId, sourceFileName, importedAt) VALUES (?, 'synthetic.csv', ?)",
                           arguments: [card, Self.day(2026, 8, 1)])
            let cardBatch = db.lastInsertedRowID
            for (index, day) in [Self.day(2026, 8, 4), Self.day(2026, 9, 14)].enumerated() {
                try db.execute(sql: """
                    INSERT INTO transaction_(importBatchId, accountId, date, rawDescription, amountMinorUnits, categoryId, status, categorizedBy, fingerprint)
                    VALUES (?, ?, ?, 'Synthetic', -880, ?, 'confirmed', 'rule', ?)
                    """, arguments: [cardBatch, card, day, f.plainCategory, "fp-card-\(index)"])
            }
            return Extras(hidden: hidden, income: income, card: card)
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
        let calendar = PayCalendar(salaryDates: PaydaySource.paydayDates(transactions: transactions, categories: categories,
                                                                         publishedCloses: try source.publishedCloses(db)),
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

    /// June to December 2026: each pay month's close date and whether it is closed.
    private static func payMonths(_ db: Database, _ source: any ActualsSource) throws -> [PayMonthState] {
        let transactions = try source.transactions(db)
        let calendar = PayCalendar(salaryDates: PaydaySource.paydayDates(transactions: transactions, categories: try Category.fetchAll(db),
                                                                         publishedCloses: try source.publishedCloses(db)),
                                   manualCloses: try PayMonthClose.fetchAll(db), today: Self.today)
        return (6...12).map { month in
            let month = PayMonth(year: 2026, month: month)
            return PayMonthState(close: calendar.closeDate(of: month), isClosed: calendar.isClosed(month))
        }
    }

    private struct PayMonthState: Equatable {
        var close: Date
        var isClosed: Bool
    }

    func testGridTotalsWithSummariesEqualFullData() async throws {
        let (owner, others) = try await gridTotalsOnBothSides(salaryInBalanceOnly: false)
        XCTAssertEqual(others, owner)
        XCTAssertEqual(owner["Income"]?["2026-09"], 300_000)
        XCTAssertNotNil(owner["Synthetic flat rent"]?["2026-09"], "property money of private accounts counts (§10)")
    }

    /// The salary in a Balance only account: no summary carries it, but its balance points publish the closes.
    func testPayMonthsFollowTheOwnersPublishedCloses() async throws {
        let (owner, others) = try await gridTotalsOnBothSides(salaryInBalanceOnly: true)
        XCTAssertEqual(others, owner)
        XCTAssertNil(owner["Income"]?["2026-09"], "the salary itself is private")
        XCTAssertEqual(owner["Income"]?["2026-11"], 700)
    }

    /// The owner's figures (less what the levels don't share) and the member's, after checking their pay months match.
    private func gridTotalsOnBothSides(salaryInBalanceOnly: Bool, totalsInEuros: Bool = false) async throws
        -> (owner: [String: [String: Int]], member: [String: [String: Int]]) {
        let (h, extras) = try await Self.household(salaryInBalanceOnly: salaryInBalanceOnly, totalsInEuros: totalsInEuros)
        let f = h.fixture
        let admin = try Self.viewer(h.adminMac, admin: true)
        let member = try Self.viewer(h.memberDevice, admin: false)

        let (owner, ownerMonths) = try await h.adminMac.db.read { db -> ([String: [String: Int]], [PayMonthState]) in
            // Balance only shares no categories: its transactions the router keeps private are what the member can't
            // count. Hidden shares nothing.
            let router = try SyncZoneRouter(db: db)
            let balanceOnlyPrivate = try Set(Int64.fetchAll(db, sql: "SELECT id FROM transaction_ WHERE accountId = ?", arguments: [f.privateAccount])
                .filter { try router.assignment(table: "transaction_", localId: $0).isPrivate })
            XCTAssertFalse(balanceOnlyPrivate.isEmpty)
            let hidden = try Set(Int64.fetchAll(db, sql: "SELECT id FROM transaction_ WHERE accountId = ?", arguments: [extras.hidden]))
            XCTAssertFalse(hidden.isEmpty)
            return (try Self.gridTotals(db, SharedActualsSource(viewer: admin, today: Self.today), leavingOut: balanceOnlyPrivate.union(hidden)), try Self.payMonths(db, SharedActualsSource(viewer: admin, today: Self.today)))
        }
        let (others, memberMonths) = try await h.memberDevice.db.read { db in
            (try Self.gridTotals(db, SharedActualsSource(viewer: member, today: Self.today)), try Self.payMonths(db, SharedActualsSource(viewer: member, today: Self.today)))
        }
        XCTAssertEqual(memberMonths, ownerMonths, "the member's pay months end on the owner's paydays")
        XCTAssertEqual(ownerMonths[2].close, Self.day(2026, 8, 25, hour: 0))
        XCTAssertEqual(ownerMonths[4].close, Self.day(2026, 10, 23, hour: 0))
        XCTAssertFalse(ownerMonths[5].isClosed, "November is open: its Income credit doesn't close it")

        // Without the summaries the member's figures would differ.
        let withoutSummaries = try await h.memberDevice.db.read { db in try Self.gridTotals(db, LocalActualsSource()) }
        XCTAssertNotEqual(withoutSummaries, owner)
        return (owner, others)
    }

    /// A summarised account in euros, with transfers to and from a pound account: the summaries' GBP totals (converted
    /// and rounded per transaction on the owner's device, corrections in their own leg's currency) give the owner's
    /// figures to the penny.
    func testEuroTotalsAccountMatchesTheOwner() async throws {
        let (owner, others) = try await gridTotalsOnBothSides(salaryInBalanceOnly: false, totalsInEuros: true)
        XCTAssertEqual(others, owner)
    }

    /// The pay months are the admin's: a member-owned account's closes (her own calendar) never move them.
    func testAMemberOwnedAccountNeverMovesTheAdminsPayMonths() async throws {
        let (h, _) = try await Self.household()
        let f = h.fixture
        let admin = try Self.viewer(h.adminMac, admin: true)
        try await h.adminMac.db.write { db in
            let hers = try AccountEditing.add(db: db, name: "Synthetic member account", currency: .gbp, kind: .cash, openingBalanceEntered: nil,
                                              asOf: Self.day(2026, 7, 1, hour: 0)).id!
            try db.execute(sql: "UPDATE account SET ownerPersonId = ?, sharingLevel = 'balanceOnly' WHERE id = ?", arguments: [f.personB, hers])
            // Her device's points, closed on the 10th of each month, as they arrive from the household zone.
            for month in 7...10 {
                try db.execute(sql: "INSERT INTO accountBalancePoint(accountId, payMonth, date, balanceMinorUnits) VALUES (?, ?, ?, ?)",
                               arguments: [hers, String(format: "2026-%02d", month), Self.day(2026, month, 10, hour: 0), 1_000 * month])
            }
            try db.execute(sql: "INSERT INTO accountBalancePoint(accountId, payMonth, date, balanceMinorUnits) VALUES (?, 'current', ?, 10000)",
                           arguments: [hers, Self.day(2026, 10, 20, hour: 0)])
        }
        try await h.adminMac.db.read { db in
            let source = SharedActualsSource(viewer: admin, today: Self.today)
            XCTAssertEqual(try source.publishedCloses(db), [])
            XCTAssertEqual(try Self.payMonths(db, source), try Self.payMonths(db, LocalActualsSource()))
            XCTAssertEqual(try Self.gridTotals(db, source), try Self.gridTotals(db, LocalActualsSource()))
            XCTAssertTrue(try source.balanceSnapshots(db).contains(where: SharedActuals.isSummary), "her balance still counts in net worth")
        }
    }

    /// Lowering a level leaves the member's old copy of a row until its move lands (Task 8: here one marker keeps
    /// failing); the summaries arrive at once. Each transaction still counts once.
    func testRowsLeftFromBeforeALowerCountOnce() async throws {
        let h = try TwoPersonHousehold.make()
        let f = h.fixture
        try await h.adminMac.db.write { db in
            try db.execute(sql: "UPDATE account SET sharingLevel = 'everything' WHERE id = ?", arguments: [f.totals])
            for dayOfMonth in [2, 9, 16] { try Self.addTransaction(db, account: f.totals, on: Self.day(2026, 9, dayOfMonth), -111 * dayOfMonth, category: f.plainCategory) }
        }
        try await h.syncAll()
        let totalsUuid = try h.uuid("account", f.totals)
        func memberHoldsTotalsRows() async throws -> Int {
            try await h.memberDevice.db.read { db in
                let account = try XCTUnwrap(SyncRecordStore.localId(table: "account", uuid: totalsUuid, db: db))
                return try Transaction.filter(Column("accountId") == account).fetchCount(db)
            }
        }
        let held = try await memberHoldsTotalsRows()
        XCTAssertEqual(held, 4)

        try await h.adminMac.db.write { db in _ = try SharingLevels.set(.categoryTotals, accountId: f.totals, actor: f.admin, db: db) }
        let lagging = try await h.adminMac.db.read { db in
            try String.fetchOne(db, sql: """
                SELECT s.uuid FROM transaction_ t JOIN syncRecord s ON s.tableName = 'transaction_' AND s.localId = t.id
                WHERE t.accountId = ? ORDER BY t.id LIMIT 1
                """, arguments: [f.totals])
        }
        h.macTransport.failSaves(of: try XCTUnwrap(lagging), in: SyncZones.household)
        try await h.syncAll()
        let member = try Self.viewer(h.memberDevice, admin: false)
        let admin = try Self.viewer(h.adminMac, admin: true)
        let stillHeld = try await memberHoldsTotalsRows()
        XCTAssertEqual(stillHeld, 1, "the old copy whose marker hasn't landed is still on the member's device")
        let owner = try await h.adminMac.db.read { db -> [String: [String: Int]] in
            let router = try SyncZoneRouter(db: db)
            let balanceOnlyPrivate = try Set(Int64.fetchAll(db, sql: "SELECT id FROM transaction_ WHERE accountId = ?", arguments: [f.privateAccount])
                .filter { try router.assignment(table: "transaction_", localId: $0).isPrivate })
            return try Self.gridTotals(db, SharedActualsSource(viewer: admin, today: Self.today), leavingOut: balanceOnlyPrivate)
        }
        let others = try await h.memberDevice.db.read { db in
            XCTAssertGreaterThan(try AccountSummaryMonth.fetchCount(db), 0, "the summaries arrived")
            return try Self.gridTotals(db, SharedActualsSource(viewer: member, today: Self.today))
        }
        XCTAssertEqual(others, owner)
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
            let transactions = try SharedActualsSource(viewer: member, today: Self.today).transactions(db)
            let calendar = PayCalendar(salaryDates: PaydaySource.paydayDates(transactions: transactions, categories: try Category.fetchAll(db),
                                                                             publishedCloses: try SharedActualsSource(viewer: member, today: Self.today).publishedCloses(db)),
                                       manualCloses: try PayMonthClose.fetchAll(db), today: Self.today)
            let september = calendar.range(of: PayMonth(year: 2026, month: 9))

            // The cell's shared transactions: the summaries aren't among them.
            let shared = transactions.filter { !SharedActuals.isSummary($0) && $0.categoryId == plain && $0.date >= september.start && $0.date <= september.end }
            XCTAssertEqual(Set(try shared.map { try XCTUnwrap(SyncRecordStore.existingUUID(table: "transaction_", localId: $0.id!, db: db)) }), expectedShared)
            XCTAssertTrue(transactions.contains { SharedActuals.isSummary($0) && $0.categoryId == plain })

            // Then one line per private account.
            let lines = try SharedActuals.privateLines(categoryIds: [plain], from: september.start, to: september.end, viewer: member, today: Self.today, db: db)
            XCTAssertEqual(lines, [SharedActuals.PrivateLine(id: totals, text: "Private (A) · 7 transactions · details private", amountMinorUnits: -3_000 - 2_100)])
            // The cell's figure is the shared transactions plus the lines.
            let cell = transactions.filter { $0.categoryId == plain && $0.date >= september.start && $0.date <= september.end }.map(\.amountMinorUnits).reduce(0, +)
            XCTAssertEqual(cell, shared.map(\.amountMinorUnits).reduce(0, +) + lines.map(\.amountMinorUnits).reduce(0, +))
            // Another month or category: no line.
            XCTAssertEqual(try SharedActuals.privateLines(categoryIds: [plain], from: september.end.addingTimeInterval(1), to: september.end.addingTimeInterval(86_400 * 20),
                                                          viewer: member, today: Self.today, db: db), [])
        }
        // The owner's own accounts have no private lines on the owner's Mac.
        let admin = try Self.viewer(h.adminMac, admin: true)
        try await h.adminMac.db.read { db in
            XCTAssertEqual(try SharedActuals.privateLines(categoryIds: [f.plainCategory], from: .distantPast, to: .distantFuture, viewer: admin, today: Self.today, db: db), [])
        }
    }

    // MARK: Net worth

    func testNetWorthCountsBalanceOnlyAndTotalsButNotHidden() async throws {
        let (h, extras) = try await Self.household()
        let f = h.fixture
        let member = try Self.viewer(h.memberDevice, admin: false)
        let hiddenUuid = try h.uuid("account", extras.hidden)
        let owner = try await h.adminMac.db.read { db in try DashboardInput.load(db: db, today: Self.today) }
        let others = try await h.memberDevice.db.read { db in try DashboardInput.load(db: db, today: Self.today, actuals: SharedActualsSource(viewer: member, today: Self.today)) }

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

        // Nothing synthetic is dated after today, and "As of" is the owner's.
        XCTAssertTrue(others.snapshots.filter(SharedActuals.isSummary).allSatisfy { $0.date <= Self.today })
        XCTAssertTrue(others.transactions.filter(SharedActuals.isSummary).allSatisfy { $0.date <= Self.today })
        XCTAssertNotNil(DashboardCalculator.netWorthSeries(owner).asOf)
        XCTAssertEqual(DashboardCalculator.netWorthSeries(others).asOf, DashboardCalculator.netWorthSeries(owner).asOf)

        // Accounts read through summaries need updates (and go stale) exactly when the owner's do.
        for account in [f.privateAccount, f.totals, f.shared, extras.card] {
            let uuid = try h.uuid("account", account)
            let ownerAccount = try XCTUnwrap(owner.accounts.first { $0.id == account })
            let found = try await h.memberDevice.db.read { db in try SyncRecordStore.localId(table: "account", uuid: uuid, db: db) }
            let memberAccount = try XCTUnwrap(others.accounts.first { $0.id == found })
            XCTAssertEqual(BalanceStaleness.needsUpdates(account: memberAccount, transactions: others.transactions, snapshots: others.snapshots),
                           BalanceStaleness.needsUpdates(account: ownerAccount, transactions: owner.transactions, snapshots: owner.snapshots), "account \(account)")
            XCTAssertEqual(BalanceStaleness.isStale(account: memberAccount, snapshots: others.snapshots, transactions: others.transactions, today: Self.today),
                           BalanceStaleness.isStale(account: ownerAccount, snapshots: owner.snapshots, transactions: owner.transactions, today: Self.today))
        }

        // A Hidden account of the other person's that a device holds anyway contributes nothing.
        try await h.adminMac.db.read { db in
            let asMember = SharingViewer(personId: f.personB)
            XCTAssertFalse(try SharedActualsSource(viewer: asMember, today: Self.today).transactions(db).contains { $0.accountId == extras.hidden })
            XCTAssertFalse(try SharedActualsSource(viewer: asMember, today: Self.today).balanceSnapshots(db).contains { $0.accountId == extras.hidden })
        }
    }

    // MARK: The owner and tools

    func testOwnerSeesOwnAccountsInFull() async throws {
        let (h, _) = try await Self.household()
        let admin = try Self.viewer(h.adminMac, admin: true)
        try await h.adminMac.db.read { db in
            XCTAssertGreaterThan(try AccountSummaryMonth.fetchCount(db), 0, "the Mac holds its own summaries")
            let source = SharedActualsSource(viewer: admin, today: Self.today)
            let transactions = try source.transactions(db)
            XCTAssertFalse(transactions.contains(where: SharedActuals.isSummary))
            XCTAssertEqual(transactions, try LocalActualsSource().transactions(db))
            XCTAssertEqual(try source.balanceSnapshots(db), try BalanceSnapshot.fetchAll(db))
            XCTAssertEqual(try source.publishedCloses(db), [], "the owner's calendar is its own")
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
                let source = SharedActualsSource(viewer: anyone, today: Self.today)
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
            let shared = SharedActualsSource(viewer: viewer, today: Self.today)
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

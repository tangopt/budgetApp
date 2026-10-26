import Foundation
import GRDB

/// Rebuilds the summaries the household zone holds for one person's accounts below Everything (sharing spec
/// §3, §10): `accountBalancePoint` (Balance only and Category totals) and `accountSummaryMonth` (Category
/// totals only). Derived data, rebuilt by the owner's devices before each push (`SyncEngineCore`), never on a
/// device that doesn't own the account.
///
/// - **Balance points:** the balance at the end of every pay month (`PayCalendar`) from the account's first
///   activity to the last closed month, dated at the month's close, plus `payMonth = "current"`, dated at its
///   latest activity. Never a daily balance. Values are `NetWorthCalculator.balance`, the Accounts screen's rule.
/// - **Category totals:** per pay month and category (one uncategorised row), the confirmed transactions the
///   account keeps private. Its §10 property-money transactions, which the household gets as rows of their own,
///   are left out, so the other person's actuals (shared transactions plus summaries) count each once.
/// - Accounts at Everything or Hidden have none: their rows are deleted.
///
/// Deterministic: two owner devices with the same data make the same rows under the same record names (a new
/// row's UUID is `derivedUUID(identity(...))`). An unchanged value writes nothing, so nothing is queued.
public enum AccountSummaryBuilder {
    public struct Outcome: Equatable, Sendable {
        public var inserted: Int
        public var updated: Int
        public var deleted: Int

        public init(inserted: Int = 0, updated: Int = 0, deleted: Int = 0) {
            self.inserted = inserted
            self.updated = updated
            self.deleted = deleted
        }
    }

    /// The `syncState` key the summary triggers set when something a summary reads changes
    /// (`SharingMigration.summaryDirtyTriggers`); a rebuild clears it.
    static let dirtyKey = "summaries.dirty"

    /// What a summary reads: a write to any of these marks the summaries dirty. The pinning tables and the
    /// property groups decide which transactions are shared individually (§10).
    static let sourceTables: [String] = ["transaction_", "balanceSnapshot", "category", "payMonthClose", "account",
                                         "propertyCategoryGroup"] + SyncZoneRouter.pinningTables

    /// "2026-10".
    public static func payMonthKey(_ month: PayMonth) -> String {
        String(format: "%04d-%02d", month.year, month.month)
    }

    /// The name a summary row's record UUID is derived from: the same on every owner device.
    public static func identity(table: String, accountUuid: String, payMonth: String, categoryUuid: String?) -> String {
        "mango.\(table).\(accountUuid).\(payMonth).\(categoryUuid ?? "uncategorised")"
    }

    /// Whether something a summary reads changed since the last rebuild.
    public static func isDirty(db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM syncState WHERE key = ?)", arguments: [dirtyKey]) ?? false
    }

    /// Rebuilds the summaries of every account `ownerPersonId` owns, as that person's app user with origin
    /// `.system`, and clears the dirty mark. Before ownership is confirmed there is nothing to summarise (every
    /// record is still household), nor for a person who owns no account: nothing is written.
    @discardableResult
    public static func rebuild(ownerPersonId: Int64, db: Database, today: Date) throws -> Outcome {
        // Nothing of theirs to summarise (a member's device today): nothing to write, so no write is checked.
        guard try SharingSetup.isConfirmed(db: db),
              try Account.filter(Column("ownerPersonId") == ownerPersonId).fetchCount(db) > 0,
              let appUserId = try Int64.fetchOne(db, sql: "SELECT id FROM appUser WHERE personId = ? ORDER BY isAdmin DESC, id LIMIT 1",
                                                 arguments: [ownerPersonId]) else {
            try db.execute(sql: "DELETE FROM syncState WHERE key = ?", arguments: [dirtyKey])
            return Outcome()
        }
        let owner = try AccessActor.load(appUserId: appUserId, db: db)
        let outcome = try ActorWrite.perform(owner, area: .budgetAndAccounts, origin: .system, db: db) {
            try build(ownerPersonId: ownerPersonId, db: db, today: today)
        }
        try db.execute(sql: "DELETE FROM syncState WHERE key = ?", arguments: [dirtyKey])
        return outcome
    }

    // MARK: Building

    private struct TotalKey: Hashable {
        var payMonth: String
        var categoryId: Int64?
    }

    private static func build(ownerPersonId: Int64, db: Database, today: Date) throws -> Outcome {
        var outcome = Outcome()
        let accounts = try Account.filter(Column("ownerPersonId") == ownerPersonId).order(Column("id")).fetchAll(db)
        let summarised = accounts.filter { $0.sharingLevel == .balanceOnly || $0.sharingLevel == .categoryTotals }
        let stale = accounts.filter { $0.sharingLevel == .everything || $0.sharingLevel == .hidden }.compactMap(\.id)
        if !stale.isEmpty {
            for table in [AccountBalancePoint.databaseTableName, AccountSummaryMonth.databaseTableName] {
                try db.execute(sql: "DELETE FROM \(table) WHERE accountId IN (\(stale.map { _ in "?" }.joined(separator: ", ")))",
                               arguments: StatementArguments(stale))
                outcome.deleted += db.changesCount
            }
        }
        guard !summarised.isEmpty else { return outcome }

        let calendar = try PayCalendar.load(db: db, today: today)
        let router = try SyncZoneRouter(db: db)
        let propertyMoney = try propertyMoneyCandidates(db: db)
        for account in summarised {
            guard let accountId = account.id else { continue }
            let accountUuid = try SyncRecordStore.uuid(for: "account", localId: accountId, db: db)
            let snapshots = try BalanceSnapshot.filter(Column("accountId") == accountId).fetchAll(db)
            let transactions = try Transaction.filter(Column("accountId") == accountId).fetchAll(db)

            let points = balancePoints(accountId: accountId, snapshots: snapshots, transactions: transactions, calendar: calendar)
            try upsertPoints(points, accountId: accountId, accountUuid: accountUuid, db: db, outcome: &outcome)

            if account.sharingLevel == .categoryTotals {
                var totals: [TotalKey: (amount: Int, count: Int)] = [:]
                for transaction in transactions where transaction.status == .confirmed {
                    // §10: shared as a row of its own, so not counted again here.
                    if let id = transaction.id, propertyMoney.contains(id),
                       try !router.assignment(table: "transaction_", localId: id).isPrivate { continue }
                    let key = TotalKey(payMonth: payMonthKey(calendar.month(containing: transaction.date)), categoryId: transaction.categoryId)
                    totals[key, default: (0, 0)].amount += transaction.amountMinorUnits
                    totals[key, default: (0, 0)].count += 1
                }
                try upsertTotals(totals, accountId: accountId, accountUuid: accountUuid, db: db, outcome: &outcome)
            } else {
                try db.execute(sql: "DELETE FROM accountSummaryMonth WHERE accountId = ?", arguments: [accountId])
                outcome.deleted += db.changesCount
            }
        }
        return outcome
    }

    /// Transactions that may be shared individually (§10): in a property category or pinned by a property/tax
    /// row. The router has the last word on each.
    private static func propertyMoneyCandidates(db: Database) throws -> Set<Int64> {
        let pinned = SyncZoneRouter.pinningTables
            .filter { (try? db.tableExists($0)) == true }
            .map { "SELECT transactionId FROM \(SyncChangeTracker.quoted($0)) WHERE transactionId IS NOT NULL" }
        let property = "SELECT id FROM transaction_ WHERE categoryId IN (SELECT id FROM category WHERE groupId IN (SELECT categoryGroupId FROM propertyCategoryGroup))"
        return Set(try Int64.fetchAll(db, sql: ([property] + pinned).joined(separator: " UNION ")))
    }

    /// The balance at each pay month's end (first activity to the last closed month) and now.
    private static func balancePoints(accountId: Int64, snapshots: [BalanceSnapshot], transactions: [Transaction],
                                      calendar: PayCalendar) -> [String: (date: Date, balance: Int)] {
        var points: [String: (date: Date, balance: Int)] = [:]
        guard let firstActivity = (snapshots.map(\.date) + transactions.map(\.date)).min() else { return points }
        let first = calendar.month(containing: firstActivity)
        var lastClosed: PayMonth?
        var month = calendar.current
        while month >= first {
            if calendar.isClosed(month) { lastClosed = month; break }
            month = month.previous
        }
        if let lastClosed {
            month = first
            while month <= lastClosed {
                // At the end of the close day, as the Accounts screen counts a day's transactions.
                if let balance = NetWorthCalculator.balance(accountId: accountId, at: calendar.range(of: month).end,
                                                            snapshots: snapshots, transactions: transactions) {
                    points[payMonthKey(month)] = (calendar.closeDate(of: month), balance.native)
                }
                month = month.next
            }
        }
        if let now = NetWorthCalculator.balance(accountId: accountId, at: nil, snapshots: snapshots, transactions: transactions) {
            points[AccountBalancePoint.currentPayMonth] = (now.latestActivity, now.native)
        }
        return points
    }

    private static func upsertPoints(_ points: [String: (date: Date, balance: Int)], accountId: Int64, accountUuid: String,
                                     db: Database, outcome: inout Outcome) throws {
        var existing = Dictionary(uniqueKeysWithValues: try AccountBalancePoint.filter(Column("accountId") == accountId).fetchAll(db)
            .map { ($0.payMonth, $0) })
        for (payMonth, point) in points.sorted(by: { $0.key < $1.key }) {
            if let row = existing.removeValue(forKey: payMonth) {
                guard row.date != point.date || row.balanceMinorUnits != point.balance else { continue }
                try db.execute(sql: "UPDATE accountBalancePoint SET date = ?, balanceMinorUnits = ? WHERE id = ?",
                               arguments: [point.date, point.balance, row.id])
                outcome.updated += 1
            } else {
                let uuid = SyncRecordStore.derivedUUID(identity(table: AccountBalancePoint.databaseTableName, accountUuid: accountUuid,
                                                                payMonth: payMonth, categoryUuid: nil))
                try insertIdentified(table: AccountBalancePoint.databaseTableName, uuid: uuid, db: db) { id in
                    var row = AccountBalancePoint(id: id, accountId: accountId, payMonth: payMonth, date: point.date, balanceMinorUnits: point.balance)
                    try row.insert(db)
                }
                outcome.inserted += 1
            }
        }
        for row in existing.values {
            try db.execute(sql: "DELETE FROM accountBalancePoint WHERE id = ?", arguments: [row.id])
            outcome.deleted += 1
        }
    }

    private static func upsertTotals(_ totals: [TotalKey: (amount: Int, count: Int)], accountId: Int64, accountUuid: String,
                                     db: Database, outcome: inout Outcome) throws {
        var existing = Dictionary(uniqueKeysWithValues: try AccountSummaryMonth.filter(Column("accountId") == accountId).fetchAll(db)
            .map { (TotalKey(payMonth: $0.payMonth, categoryId: $0.categoryId), $0) })
        let ordered = totals.sorted { ($0.key.payMonth, $0.key.categoryId ?? 0) < ($1.key.payMonth, $1.key.categoryId ?? 0) }
        for (key, total) in ordered {
            if let row = existing.removeValue(forKey: key) {
                guard row.amountMinorUnits != total.amount || row.transactionCount != total.count else { continue }
                try db.execute(sql: "UPDATE accountSummaryMonth SET amountMinorUnits = ?, transactionCount = ? WHERE id = ?",
                               arguments: [total.amount, total.count, row.id])
                outcome.updated += 1
            } else {
                let categoryUuid = try key.categoryId.map { try SyncRecordStore.uuid(for: "category", localId: $0, db: db) }
                let uuid = SyncRecordStore.derivedUUID(identity(table: AccountSummaryMonth.databaseTableName, accountUuid: accountUuid,
                                                                payMonth: key.payMonth, categoryUuid: categoryUuid))
                try insertIdentified(table: AccountSummaryMonth.databaseTableName, uuid: uuid, db: db) { id in
                    var row = AccountSummaryMonth(id: id, accountId: accountId, payMonth: key.payMonth, categoryId: key.categoryId,
                                                  amountMinorUnits: total.amount, transactionCount: total.count)
                    try row.insert(db)
                }
                outcome.inserted += 1
            }
        }
        for row in existing.values {
            try db.execute(sql: "DELETE FROM accountSummaryMonth WHERE id = ?", arguments: [row.id])
            outcome.deleted += 1
        }
    }

    /// Inserts a row (through `insert`, given its local id) whose record is named `uuid`: the identity goes in
    /// first, so the tracking trigger queues the row under it instead of a random one. A summary deleted earlier
    /// (its account raised to Everything) and made again comes back under the same name: its tombstone and
    /// queued delete give way to the insert.
    private static func insertIdentified(table: String, uuid: String, db: Database, _ insert: (Int64) throws -> Void) throws {
        let quoted = SyncChangeTracker.quoted(table)
        let maxId = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(id), 0) FROM \(quoted)") ?? 0
        let sequence = try Int64.fetchOne(db, sql: "SELECT seq FROM sqlite_sequence WHERE name = ?", arguments: [table]) ?? 0
        let id = max(maxId, sequence) + 1
        try db.execute(sql: "DELETE FROM syncTombstone WHERE uuid = ?", arguments: [uuid])
        try db.execute(sql: "DELETE FROM syncRecord WHERE uuid = ?", arguments: [uuid])
        try db.execute(sql: "INSERT INTO syncRecord(tableName, localId, uuid, zone) VALUES (?, ?, ?, ?)",
                       arguments: [table, id, uuid, SyncRecordStore.householdZone])
        try db.execute(sql: """
            INSERT INTO syncPending(uuid, tableName, localId, kind, revision)
            VALUES (?, ?, ?, 'insert', (SELECT COALESCE(MAX(revision), 0) + 1 FROM syncPending))
            ON CONFLICT(uuid) DO UPDATE SET tableName = excluded.tableName, localId = excluded.localId, kind = 'insert',
                revision = excluded.revision
            """, arguments: [uuid, table, id])
        try insert(id)
    }
}

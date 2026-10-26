import Foundation
import GRDB

/// Rebuilds the summaries the household zone holds for one person's accounts below Everything (sharing spec
/// §3, §10): `accountBalancePoint` (Balance only and Category totals) and `accountSummaryMonth` (Category
/// totals only). Derived data, rebuilt by the owner's devices before each push (`SyncEngineCore`), never on a
/// device that doesn't own the account.
///
/// - **Balance points:** the balance at the end of every pay month (`PayCalendar`) from the account's first
///   activity to the last closed month, dated at the month's close, plus `payMonth = "current"`, dated at the day
///   it was published (UTC) and republished at most once a day. Never a daily balance. Values follow
///   `NetWorthCalculator.balance`, the Accounts screen's rule.
/// - **Category totals:** per pay month and category (one uncategorised row), what the owner's budget counts of
///   the account (`Transaction.budgetFacing`, confirmed) less what the household gets as rows of its own: the §10
///   property-money transactions. A transfer counts once, as sent: an incoming leg of a linked transfer is left
///   out; and when this account sent it to a shared leg whose link the other person can't see (it stays private),
///   a correction row takes that leg back out of their figures. So the other person's actuals (shared transactions
///   plus summaries) are the owner's budget figures.
/// - Accounts at Everything or Hidden have none: their rows are deleted.
///
/// Only the accounts whose data changed are rebuilt (`SharingMigration.summaryDirtyTriggers` marks each), all of
/// them when the categories or the pay calendar changed. Deterministic: two owner devices with the same data make
/// the same rows under the same record names (a new row's UUID is `derivedUUID(identity(...))`). An unchanged
/// value writes nothing, so nothing is queued.
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

    /// A rebuild that failed: what the push reports, naming the summaries.
    public struct BuildError: Error, Equatable, LocalizedError {
        public var underlying: String

        public init(underlying: String) { self.underlying = underlying }

        public var errorDescription: String? { "Mango couldn't update the account summaries it shares: \(underlying)" }
    }

    /// The `syncState` key that marks every account's summaries dirty (categories, pay months, a new database).
    static let dirtyKey = "summaries.dirty"
    /// The prefix of the key that marks one account's summaries dirty (`summaries.dirty.<account id>`).
    static let accountDirtyPrefix = "summaries.dirty."
    /// The pay calendar the summaries were last built with: when it changes, every account is rebuilt.
    static let calendarKey = "summaries.calendar"

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
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM syncState WHERE key = ? OR substr(key, 1, ?) = ?)",
                          arguments: [dirtyKey, accountDirtyPrefix.count, accountDirtyPrefix]) ?? false
    }

    /// Rebuilds the summaries of the accounts `ownerPersonId` owns whose data changed, writing as that person's app
    /// user (summaries are the owner's alone, whatever their area permissions) with origin `.system`, and clears the
    /// dirty marks. Before ownership is confirmed there is nothing to summarise (every record is still household),
    /// nor for a person who owns no account: nothing is written. Fails with `BuildError`.
    @discardableResult
    public static func rebuild(ownerPersonId: Int64, db: Database, today: Date) throws -> Outcome {
        guard try SharingSetup.isConfirmed(db: db),
              try Account.filter(Column("ownerPersonId") == ownerPersonId).fetchCount(db) > 0,
              let appUserId = try Int64.fetchOne(db, sql: "SELECT id FROM appUser WHERE personId = ? ORDER BY isAdmin DESC, id LIMIT 1",
                                                 arguments: [ownerPersonId]) else {
            try clearDirty(keeping: [], db: db)
            return Outcome()
        }
        do {
            let owner = try AccessActor.load(appUserId: appUserId, db: db)
            // Owner-only rows (`AccessAreaMap`): the owner writes them, not an area permission.
            return try ActorWrite.stamped(owner, origin: .system, db: db) {
                try build(ownerPersonId: ownerPersonId, db: db, today: today)
            }
        } catch let error as BuildError {
            throw error
        } catch {
            throw BuildError(underlying: String(describing: error))
        }
    }

    private static func clearDirty(keeping accounts: [Int64], db: Database) throws {
        try db.execute(sql: "DELETE FROM syncState WHERE key = ? OR substr(key, 1, ?) = ?",
                       arguments: [dirtyKey, accountDirtyPrefix.count, accountDirtyPrefix])
        for account in accounts {
            try db.execute(sql: "INSERT INTO syncState(key, value, updatedAt) VALUES (?, X'31', ?)",
                           arguments: [accountDirtyPrefix + String(account), Date()])
        }
    }

    // MARK: Building

    private struct TotalKey: Hashable {
        var month: PayMonth
        var categoryId: Int64?
    }

    /// What a summary reads of a transaction.
    struct Entry {
        var id: Int64
        var date: Date
        var amount: Int
        var categoryId: Int64?
        var isConfirmed: Bool
    }

    private static func build(ownerPersonId: Int64, db: Database, today: Date) throws -> Outcome {
        var outcome = Outcome()
        let calendar = try PayCalendar.load(db: db, today: today)
        let fingerprint = try calendarFingerprint(calendar, db: db)
        let everyAccount = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM syncState WHERE key = ?)", arguments: [dirtyKey]) ?? false
            || (try Data.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [calendarKey])) != fingerprint
        let dirtyAccounts = Set(try String.fetchAll(db, sql: "SELECT key FROM syncState WHERE substr(key, 1, ?) = ?",
                                                    arguments: [accountDirtyPrefix.count, accountDirtyPrefix])
            .compactMap { Int64($0.dropFirst(accountDirtyPrefix.count)) })
        let accounts = try Account.filter(Column("ownerPersonId") == ownerPersonId).order(Column("id")).fetchAll(db)
            .filter { account in account.id.map { everyAccount || dirtyAccounts.contains($0) } ?? false }

        var stillDirty: [Int64] = []
        if !accounts.isEmpty {
            var context = try Context(db: db, calendar: calendar, today: today)
            for account in accounts {
                guard let accountId = account.id else { continue }
                if account.sharingLevel == .everything || account.sharingLevel == .hidden {
                    for table in [AccountBalancePoint.databaseTableName, AccountSummaryMonth.databaseTableName] {
                        try db.execute(sql: "DELETE FROM \(table) WHERE accountId = ?", arguments: [accountId])
                        outcome.deleted += db.changesCount
                    }
                    continue
                }
                if try !build(account: account, context: &context, outcome: &outcome) { stillDirty.append(accountId) }
            }
        }
        try clearDirty(keeping: stillDirty, db: db)
        try db.execute(sql: "INSERT INTO syncState(key, value, updatedAt) VALUES (?, ?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value, updatedAt = excluded.updatedAt",
                       arguments: [calendarKey, fingerprint, Date()])
        return outcome
    }

    /// What a rebuild reads beyond one account, loaded once.
    private struct Context {
        let db: Database
        let calendar: PayCalendar
        /// The publish day (UTC) of the current balance.
        let publishDay: Date
        let propertyMoney: Set<Int64>
        let links: [TransferLink]
        let hiddenLegs: Set<Int64>
        private var loadedRouter: SyncZoneRouter?

        init(db: Database, calendar: PayCalendar, today: Date) throws {
            self.db = db
            self.calendar = calendar
            publishDay = PayCalendar.calendar.startOfDay(for: today)
            propertyMoney = try AccountSummaryBuilder.propertyMoneyCandidates(db: db)
            links = try TransferLink.active.fetchAll(db)
            hiddenLegs = Set(links.map(\.inTransactionId))
        }

        /// Whether the household gets the record as a row of its own.
        mutating func isShared(_ table: String, _ id: Int64) throws -> Bool {
            if loadedRouter == nil { loadedRouter = try SyncZoneRouter(db: db) }
            return try !loadedRouter!.assignment(table: table, localId: id).isPrivate
        }
    }

    /// Rebuilds one Balance only or Category totals account. False when the current balance changed but was already
    /// published today: it goes tomorrow, the account staying dirty until then.
    private static func build(account: Account, context: inout Context, outcome: inout Outcome) throws -> Bool {
        let db = context.db
        let accountId = account.id!
        let accountUuid = try SyncRecordStore.uuid(for: "account", localId: accountId, db: db)
        let snapshots = try BalanceSnapshot.filter(Column("accountId") == accountId).fetchAll(db)
        let transactions = try Array(Row.fetchCursor(db, sql: """
            SELECT id, date, amountMinorUnits, categoryId, status FROM transaction_ WHERE accountId = ? ORDER BY date, id
            """, arguments: [accountId]).map { row in
                Entry(id: row["id"], date: row["date"], amount: row["amountMinorUnits"], categoryId: row["categoryId"],
                      isConfirmed: (row["status"] as String) == TransactionStatus.confirmed.rawValue)
            })
        let ledger = Ledger(snapshots: snapshots, transactions: transactions)

        let (points, current) = balancePoints(ledger: ledger, calendar: context.calendar)
        let published = try upsertPoints(points, current: current, publishDay: context.publishDay, accountId: accountId,
                                         accountUuid: accountUuid, db: db, outcome: &outcome)

        guard account.sharingLevel == .categoryTotals else {
            try db.execute(sql: "DELETE FROM accountSummaryMonth WHERE accountId = ?", arguments: [accountId])
            outcome.deleted += db.changesCount
            return published
        }
        var months = MonthIndex(calendar: context.calendar)
        var totals: [TotalKey: (amount: Int, count: Int)] = [:]
        for transaction in transactions where transaction.isConfirmed {
            let id = transaction.id
            guard !context.hiddenLegs.contains(id) else { continue }
            // §10: shared as a row of its own, so not counted again here.
            if context.propertyMoney.contains(id), try context.isShared("transaction_", id) { continue }
            let key = TotalKey(month: months.month(containing: transaction.date), categoryId: transaction.categoryId)
            totals[key, default: (0, 0)].amount += transaction.amount
            totals[key, default: (0, 0)].count += 1
        }
        // Sent from here to a shared leg whose link stays private: the other person counts that leg, which the owner's
        // budget hides; taken back out here, in its month and category.
        let sent = Set(transactions.map(\.id))
        for link in context.links where sent.contains(link.outTransactionId) {
            guard let leg = try Transaction.fetchOne(db, key: link.inTransactionId), leg.status == .confirmed,
                  try context.isShared("transaction_", link.inTransactionId),
                  let linkId = link.id, try !context.isShared("transferLink", linkId) else { continue }
            let key = TotalKey(month: months.month(containing: leg.date), categoryId: leg.categoryId)
            totals[key, default: (0, 0)].amount -= leg.amountMinorUnits
            totals[key, default: (0, 0)].count -= 1
        }
        try upsertTotals(totals, accountId: accountId, accountUuid: accountUuid, db: db, outcome: &outcome)
        return published
    }

    /// The pay calendar's inputs and the current month: when they change, every month's edges may have moved.
    private static func calendarFingerprint(_ calendar: PayCalendar, db: Database) throws -> Data {
        let paydays = try PaydaySource.paydayDates(db: db).map(\.timeIntervalSince1970).sorted()
        let closes = try PayMonthClose.order(Column("year"), Column("month")).fetchAll(db)
            .map { "\($0.year)-\($0.month)@\($0.closeDate.timeIntervalSince1970)" }
        let text = "\(payMonthKey(calendar.current))|\(paydays.map { String($0) }.joined(separator: ","))|\(closes.joined(separator: ","))"
        return try JSONEncoder().encode(text)
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

    /// `NetWorthCalculator.balance` for one account, answered from running sums (one pass, not one per month).
    struct Ledger {
        private let dates: [Date]
        private let sums: [Int]
        /// Newest first (`NetWorthCalculator.isNewer`).
        private let snapshots: [BalanceSnapshot]

        init(snapshots: [BalanceSnapshot], transactions: [Entry]) {
            let sorted = transactions.sorted { $0.date < $1.date }
            dates = sorted.map(\.date)
            var sums = [0]
            sums.reserveCapacity(sorted.count + 1)
            for transaction in sorted { sums.append(sums.last! + transaction.amount) }
            self.sums = sums
            self.snapshots = snapshots.sorted(by: NetWorthCalculator.isNewer)
        }

        var firstActivity: Date? { [dates.first, snapshots.map(\.date).min()].compactMap { $0 }.min() }

        /// How many transactions are dated at or before `date`.
        private func count(through date: Date) -> Int {
            var low = 0, high = dates.count
            while low < high {
                let mid = (low + high) / 2
                if dates[mid] <= date { low = mid + 1 } else { high = mid }
            }
            return low
        }

        func balance(at date: Date?) -> (native: Int, latestActivity: Date)? {
            let snapshot = snapshots.first { date == nil || $0.date <= date! }
            if snapshot == nil && !snapshots.isEmpty { return nil }
            let upper = date.map(count(through:)) ?? dates.count
            let lower = snapshot.map { count(through: $0.date) } ?? 0
            let counted = max(0, upper - lower)
            let latest = [snapshot?.date, counted > 0 ? dates[upper - 1] : nil].compactMap { $0 }.max()
            guard let latest else { return nil }
            return ((snapshot?.balanceMinorUnits ?? 0) + (counted > 0 ? sums[upper] - sums[lower] : 0), latest)
        }
    }

    /// Pay months by their start, for many lookups.
    private struct MonthIndex {
        let calendar: PayCalendar
        private var starts: [Date] = []
        private var months: [PayMonth] = []
        private var end: Date = .distantPast

        init(calendar: PayCalendar) { self.calendar = calendar }

        mutating func month(containing date: Date) -> PayMonth {
            if let first = starts.first, date >= first, date <= end {
                var low = 0, high = starts.count
                while low < high {
                    let mid = (low + high) / 2
                    if starts[mid] <= date { low = mid + 1 } else { high = mid }
                }
                return months[low - 1]
            }
            let found = calendar.month(containing: date)
            // Widen the index to cover it (forwards by appending: transactions mostly come in date order).
            if let last = months.last, found > last {
                var month = last.next
                while month <= found {
                    starts.append(calendar.range(of: month).start)
                    months.append(month)
                    month = month.next
                }
            } else {
                var month = found
                let to = months.last ?? found
                starts = []
                months = []
                while month <= to {
                    starts.append(calendar.range(of: month).start)
                    months.append(month)
                    month = month.next
                }
            }
            end = calendar.range(of: months.last!).end
            return found
        }
    }

    /// The balance at each pay month's end (first activity to the last closed month), and now.
    private static func balancePoints(ledger: Ledger, calendar: PayCalendar) -> (months: [String: (date: Date, balance: Int)], current: Int?) {
        var points: [String: (date: Date, balance: Int)] = [:]
        guard let firstActivity = ledger.firstActivity else { return (points, nil) }
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
                if let balance = ledger.balance(at: calendar.range(of: month).end) {
                    points[payMonthKey(month)] = (calendar.closeDate(of: month), balance.native)
                }
                month = month.next
            }
        }
        return (points, ledger.balance(at: nil)?.native)
    }

    /// Upserts the month points and the current one. False when the current balance changed but was published today.
    private static func upsertPoints(_ points: [String: (date: Date, balance: Int)], current: Int?, publishDay: Date, accountId: Int64,
                                     accountUuid: String, db: Database, outcome: inout Outcome) throws -> Bool {
        var existing = Dictionary(uniqueKeysWithValues: try AccountBalancePoint.filter(Column("accountId") == accountId).fetchAll(db)
            .map { ($0.payMonth, $0) })
        var published = true
        var wanted = points
        if let current {
            if let row = existing[AccountBalancePoint.currentPayMonth], row.balanceMinorUnits != current, row.date >= publishDay {
                // At most once a day: today's stays until tomorrow's push.
                existing[AccountBalancePoint.currentPayMonth] = nil
                published = false
            } else if let row = existing[AccountBalancePoint.currentPayMonth], row.balanceMinorUnits == current {
                wanted[AccountBalancePoint.currentPayMonth] = (row.date, current)
            } else {
                wanted[AccountBalancePoint.currentPayMonth] = (publishDay, current)
            }
        }
        for (payMonth, point) in wanted.sorted(by: { $0.key < $1.key }) {
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
        return published
    }

    private static func upsertTotals(_ totals: [TotalKey: (amount: Int, count: Int)], accountId: Int64, accountUuid: String,
                                     db: Database, outcome: inout Outcome) throws {
        var existing = Dictionary(uniqueKeysWithValues: try AccountSummaryMonth.filter(Column("accountId") == accountId).fetchAll(db)
            .map { ($0.payMonth + "/" + ($0.categoryId.map(String.init) ?? ""), $0) })
        let ordered = totals.filter { $0.value != (0, 0) }
            .sorted { ($0.key.month, $0.key.categoryId ?? 0) < ($1.key.month, $1.key.categoryId ?? 0) }
        for (key, total) in ordered {
            let payMonth = payMonthKey(key.month)
            if let row = existing.removeValue(forKey: payMonth + "/" + (key.categoryId.map(String.init) ?? "")) {
                guard row.amountMinorUnits != total.amount || row.transactionCount != total.count else { continue }
                try db.execute(sql: "UPDATE accountSummaryMonth SET amountMinorUnits = ?, transactionCount = ? WHERE id = ?",
                               arguments: [total.amount, total.count, row.id])
                outcome.updated += 1
            } else {
                let categoryUuid = try key.categoryId.map { try SyncRecordStore.uuid(for: "category", localId: $0, db: db) }
                let uuid = SyncRecordStore.derivedUUID(identity(table: AccountSummaryMonth.databaseTableName, accountUuid: accountUuid,
                                                                payMonth: payMonth, categoryUuid: categoryUuid))
                try insertIdentified(table: AccountSummaryMonth.databaseTableName, uuid: uuid, db: db) { id in
                    var row = AccountSummaryMonth(id: id, accountId: accountId, payMonth: payMonth, categoryId: key.categoryId,
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
        let maxId = try Int64.fetchOne(db.cachedStatement(sql: "SELECT COALESCE(MAX(id), 0) FROM \(quoted)")) ?? 0
        let sequence = try Int64.fetchOne(db.cachedStatement(sql: "SELECT seq FROM sqlite_sequence WHERE name = ?"), arguments: [table]) ?? 0
        let id = max(maxId, sequence) + 1
        try db.cachedStatement(sql: "DELETE FROM syncTombstone WHERE uuid = ?").execute(arguments: [uuid])
        try db.cachedStatement(sql: "DELETE FROM syncRecord WHERE uuid = ?").execute(arguments: [uuid])
        try db.cachedStatement(sql: "INSERT INTO syncRecord(tableName, localId, uuid, zone) VALUES (?, ?, ?, ?)")
            .execute(arguments: [table, id, uuid, SyncRecordStore.householdZone])
        try db.cachedStatement(sql: """
            INSERT INTO syncPending(uuid, tableName, localId, kind, revision)
            VALUES (?, ?, ?, 'insert', (SELECT COALESCE(MAX(revision), 0) + 1 FROM syncPending))
            ON CONFLICT(uuid) DO UPDATE SET tableName = excluded.tableName, localId = excluded.localId, kind = 'insert',
                revision = excluded.revision
            """).execute(arguments: [uuid, table, id])
        try insert(id)
    }
}

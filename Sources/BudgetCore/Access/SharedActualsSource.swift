import Foundation
import GRDB

/// Whose figures a screen shows (sharing spec 2026-10-25 §3 goal 6): the person signed in on this device. They see
/// in full their own accounts, joint accounts and accounts at Everything; the other person's accounts below
/// Everything only through their summaries, and Hidden ones not at all.
public struct SharingViewer: Equatable, Sendable {
    /// The viewer's local `person` id; nil sees everything (tools, tests, a device with no one signed in).
    public var personId: Int64?

    public init(personId: Int64?) {
        self.personId = personId
    }

    /// The viewer signed in as the `appUser` with this local id; nil (or an unknown user) sees everything.
    public static func load(appUserId: Int64?, db: Database) throws -> SharingViewer {
        guard let appUserId else { return SharingViewer(personId: nil) }
        return SharingViewer(personId: try AppUser.fetchOne(db, key: appUserId)?.personId)
    }

    public func seesInFull(_ account: Account) -> Bool {
        guard let personId else { return true }
        return account.sharingLevel == .everything || account.ownerPersonId == nil || account.ownerPersonId == personId
    }
}

/// The viewer's actuals (sync spec §6.1 "How totals count"). For accounts seen in full: their transactions and
/// balance snapshots, as the local ledger holds them. For the other person's accounts below Everything: the
/// transactions this device holds of them (only what the household shares: property money, §10, and the shared
/// legs of transfers), plus one synthetic transaction per `accountSummaryMonth` row and one synthetic snapshot per
/// `accountBalancePoint`. Hidden accounts of the other person contribute nothing.
///
/// - Synthetic transactions (`SharedActuals.isSummary`): id `-summaryRow.id`, the row's account, category and
///   signed amount, status confirmed, no description, counted as a manual entry (so it never moves "data
///   through"). Dated at the end of the pay month as the owner's calendar has it: the end of the day of the
///   account's owner's balance point for that month (its close date), or, for a month with no point (the open
///   month), the end of that month in this device's calendar with the published closes. Never a payday.
/// - Published closes (`publishedCloses`): the dates of the summarised accounts' balance points of closed pay
///   months, which are the owners' close dates, Balance only included. With them the reader's pay calendar ends
///   each month where the owner's does; its own paydays count only in months with none.
/// - Synthetic snapshots: id `-point.id`, dated at the end of the point's day, so the month's synthetic
///   transactions (dated the same second) are inside it, not added on top. The `current` point is dated no
///   earlier than the account's latest transaction here, so balances now are the owner's.
public struct SharedActualsSource: ActualsSource {
    public let viewer: SharingViewer

    public init(viewer: SharingViewer) {
        self.viewer = viewer
    }

    public func transactions(_ db: Database) throws -> [Transaction] {
        let split = try AccountSplit(viewer: viewer, db: db)
        let all = try Transaction.fetchAll(db)
        guard !split.isEverythingInFull else { return all }
        let kept = all.filter { !split.hidden.contains($0.accountId) }
        return kept + (try SummaryTransactions(split: split, kept: kept, db: db).transactions)
    }

    public func publishedCloses(_ db: Database) throws -> [Date] {
        let split = try AccountSplit(viewer: viewer, db: db)
        guard !split.summarised.isEmpty else { return [] }
        return try Self.publishedCloses(summarised: split.summarised, db: db)
    }

    static func publishedCloses(summarised: Set<Int64>, db: Database) throws -> [Date] {
        Array(Set(try AccountBalancePoint
            .filter(summarised.contains(Column("accountId")) && Column("payMonth") != AccountBalancePoint.currentPayMonth)
            .fetchAll(db).map(\.date))).sorted()
    }

    public func balanceSnapshots(_ db: Database) throws -> [BalanceSnapshot] {
        let split = try AccountSplit(viewer: viewer, db: db)
        let all = try BalanceSnapshot.fetchAll(db)
        guard !split.isEverythingInFull else { return all }
        let inFull = all.filter { !split.hidden.contains($0.accountId) && !split.summarised.contains($0.accountId) }
        guard !split.summarised.isEmpty else { return inFull }
        let kept = try Transaction.fetchAll(db).filter { !split.hidden.contains($0.accountId) }
        let summaries = try SummaryTransactions(split: split, kept: kept, db: db)
        var latest: [Int64: Date] = [:]
        for transaction in kept + summaries.transactions where split.summarised.contains(transaction.accountId) {
            latest[transaction.accountId] = max(latest[transaction.accountId] ?? transaction.date, transaction.date)
        }
        let points = summaries.points.map { point -> BalanceSnapshot in
            var date = SummaryTransactions.endOfDay(point.date)
            if point.payMonth == AccountBalancePoint.currentPayMonth, let last = latest[point.accountId] { date = max(date, last) }
            return BalanceSnapshot(id: -(point.id ?? 0), accountId: point.accountId, date: date, balanceMinorUnits: point.balanceMinorUnits, note: nil)
        }
        return inFull + points
    }
}

/// The budget drill-down's lines for the other person's private accounts (sync spec §6.1): after a cell's shared
/// transactions, one line per account the viewer sees only as category totals.
public enum SharedActuals {
    public struct PrivateLine: Equatable, Identifiable, Sendable {
        /// The account's local id.
        public var id: Int64
        /// `SharingCopy.privateLine`: "Card (Name) · 7 transactions · details private".
        public var text: String
        public var amountMinorUnits: Int

        public init(id: Int64, text: String, amountMinorUnits: Int) {
            self.id = id
            self.text = text
            self.amountMinorUnits = amountMinorUnits
        }
    }

    /// One line per summarised account with totals in `categoryIds` dated (as `SharedActualsSource` dates them)
    /// from `from` to `to`, both included: the signed sums of its rows (a transfer's correction rows count
    /// negative; the count shown never goes below zero). In the accounts' display order; none when both sums are zero.
    public static func privateLines(categoryIds: Set<Int64>, from: Date, to: Date, viewer: SharingViewer, db: Database) throws -> [PrivateLine] {
        let split = try AccountSplit(viewer: viewer, db: db)
        guard !split.summarised.isEmpty else { return [] }
        let kept = try Transaction.fetchAll(db).filter { !split.hidden.contains($0.accountId) }
        let summaries = try SummaryTransactions(split: split, kept: kept, db: db)
        var sums: [Int64: (amount: Int, count: Int)] = [:]
        for (transaction, count) in zip(summaries.transactions, summaries.counts) {
            guard let category = transaction.categoryId, categoryIds.contains(category), transaction.date >= from, transaction.date <= to else { continue }
            sums[transaction.accountId, default: (0, 0)].amount += transaction.amountMinorUnits
            sums[transaction.accountId, default: (0, 0)].count += count
        }
        let owners = try ownerNames(db: db)
        return split.accounts.sortedForDisplay().compactMap { account -> PrivateLine? in
            guard let id = account.id, let sum = sums[id], sum.amount != 0 || sum.count != 0 else { return nil }
            let owner = account.ownerPersonId.flatMap { owners[$0] } ?? ""
            return PrivateLine(id: id, text: SharingCopy.privateLine(account: account.displayName, owner: owner, count: max(sum.count, 0)),
                               amountMinorUnits: sum.amount)
        }
    }

    /// A synthetic transaction standing for a summary row (`SharedActualsSource`), not a real one.
    public static func isSummary(_ t: Transaction) -> Bool {
        (t.id ?? 0) < 0
    }

    /// Each person's name as the app shows it: their app user's display name, else the person's name.
    private static func ownerNames(db: Database) throws -> [Int64: String] {
        var names: [Int64: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, name FROM person") { names[row["id"]] = row["name"] }
        for user in try AppUser.fetchAll(db) { names[user.personId] = user.displayName }
        return names
    }
}

/// The local accounts by what the viewer sees of them.
private struct AccountSplit {
    var accounts: [Account] = []
    /// Accounts of the other person below Everything but not Hidden: read through their summaries.
    var summarised: Set<Int64> = []
    /// Accounts of the other person at Hidden: left out.
    var hidden: Set<Int64> = []

    init(viewer: SharingViewer, db: Database) throws {
        guard viewer.personId != nil else { return }
        accounts = try Account.fetchAll(db)
        for account in accounts where !viewer.seesInFull(account) {
            if account.sharingLevel == .hidden { hidden.insert(account.id!) } else { summarised.insert(account.id!) }
        }
    }

    var isEverythingInFull: Bool { summarised.isEmpty && hidden.isEmpty }
}

/// The synthetic transactions for the summarised accounts' `accountSummaryMonth` rows, dated as
/// `SharedActualsSource` describes.
private struct SummaryTransactions {
    var transactions: [Transaction] = []
    /// Each synthetic transaction's `transactionCount`, in the same order.
    var counts: [Int] = []
    /// The summarised accounts' balance points.
    var points: [AccountBalancePoint] = []

    static func endOfDay(_ date: Date) -> Date {
        PayCalendar.calendar.startOfDay(for: date).addingTimeInterval(86_400 - 1)
    }

    init(split: AccountSplit, kept: [Transaction], db: Database) throws {
        guard !split.summarised.isEmpty else { return }
        let ids = Array(split.summarised)
        points = try AccountBalancePoint.filter(ids.contains(Column("accountId"))).order(Column("id")).fetchAll(db)
        let rows = try AccountSummaryMonth.filter(ids.contains(Column("accountId"))).order(Column("id")).fetchAll(db)
        guard !rows.isEmpty else { return }

        // The owner's close dates: every balance point of a closed month of any of that owner's accounts.
        let owners = Dictionary(uniqueKeysWithValues: split.accounts.compactMap { account in account.id.map { ($0, account.ownerPersonId) } })
        var closes: [Int64?: [String: Date]] = [:]
        for point in points where point.payMonth != AccountBalancePoint.currentPayMonth {
            let owner = owners[point.accountId] ?? nil
            closes[owner, default: [:]][point.payMonth] = max(closes[owner]?[point.payMonth] ?? point.date, point.date)
        }

        var dated: [(row: AccountSummaryMonth, date: Date)] = []
        var undated: [(row: AccountSummaryMonth, month: PayMonth)] = []
        for row in rows {
            if let close = closes[owners[row.accountId] ?? nil]?[row.payMonth] {
                dated.append((row, Self.endOfDay(close)))
            } else if let month = Self.payMonth(row.payMonth) {
                undated.append((row, month))
            }
        }
        if !undated.isEmpty {
            // This device's calendar as the grid builds it: its own paydays and the published closes.
            let published = try SharedActualsSource.publishedCloses(summarised: split.summarised, db: db)
            let calendar = PayCalendar(salaryDates: PaydaySource.paydayDates(transactions: kept, categories: try Category.fetchAll(db),
                                                                             publishedCloses: published),
                                       manualCloses: try PayMonthClose.fetchAll(db), today: Date())
            dated += undated.map { ($0.row, calendar.range(of: $0.month).end) }
        }
        transactions = dated.map { Self.transaction($0.row, date: $0.date) }
        counts = dated.map(\.row.transactionCount)
    }

    private static func payMonth(_ key: String) -> PayMonth? {
        let parts = key.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]), (1...12).contains(month) else { return nil }
        return PayMonth(year: year, month: month)
    }

    private static func transaction(_ row: AccountSummaryMonth, date: Date) -> Transaction {
        Transaction(id: -(row.id ?? 0), importBatchId: 0, accountId: row.accountId, date: date, rawDescription: "",
                    amountMinorUnits: row.amountMinorUnits, categoryId: row.categoryId, status: .confirmed, categorizedBy: .manual,
                    fingerprint: "summary-\(row.id ?? 0)", isManual: true)
    }
}

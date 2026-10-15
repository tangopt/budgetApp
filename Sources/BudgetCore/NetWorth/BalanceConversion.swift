import Foundation
import GRDB

/// A recorded balance moved out of `balanceSnapshot` by `BalanceConversion` (spec 2026-10-14 §3):
/// the snapshot's own columns (its original id kept) plus when it was archived. Read by nothing
/// in the app; kept so the conversion can be audited.
public struct BalanceSnapshotArchive: Codable, Equatable, FetchableRecord, PersistableRecord, Sendable {
    public var id: Int64
    public var accountId: Int64
    public var date: Date
    public var balanceMinorUnits: Int
    public var note: String?
    public var archivedAt: Date

    public init(snapshot: BalanceSnapshot, archivedAt: Date) {
        self.id = snapshot.id ?? 0
        self.accountId = snapshot.accountId
        self.date = snapshot.date
        self.balanceMinorUnits = snapshot.balanceMinorUnits
        self.note = snapshot.note
        self.archivedAt = archivedAt
    }

    public static let databaseTableName = "balanceSnapshotArchive"
}

func registerBalanceSnapshotArchiveMigration(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("createBalanceSnapshotArchive") { db in
        try db.create(table: "balanceSnapshotArchive") { t in
            t.column("id", .integer).primaryKey()
            t.column("accountId", .integer).notNull().references("account", onDelete: .cascade)
            t.column("date", .datetime).notNull()
            t.column("balanceMinorUnits", .integer).notNull()
            t.column("note", .text)
            t.column("archivedAt", .datetime).notNull()
        }
    }
}

/// The one-off conversion of recorded balances into an opening balance plus adjustments
/// (spec 2026-10-14 §3). Per account: the earliest snapshot stays as the opening balance; for
/// each later one, in date order, the difference between it and the balance computed at the end
/// of its day (opening + transactions + the adjustments already added) becomes a manual
/// adjustment dated that day (00:00 UTC) — Market movement for investment accounts, Balance
/// adjustment otherwise. The later snapshots then move to `balanceSnapshotArchive`.
///
/// Several snapshots on one day: only the one the balance rule picks (`NetWorthCalculator.isNewer`)
/// counts; the others are "superseded" — archived without an adjustment or a check.
///
/// Verification, in the same write: every archived (non-superseded) snapshot equals the
/// computed balance at the end of its day; every account's balance at the end of today and at
/// every month end from its opening month to today's month is unchanged. Any violation throws
/// `BalanceConversionError.invariantViolated` — the caller's transaction then rolls back.
/// Running it again finds no later snapshots and does nothing.
public enum BalanceConversion {
    public static let adjustmentNote = "Converted from a recorded balance"

    public static func adjustmentDescription(_ role: CategoryBuiltInRole) -> String {
        "\(role.defaultName) (converted)"
    }

    public struct AccountReport: Equatable, Sendable {
        public let accountId: Int64
        public let accountName: String
        public let currency: Currency
        /// The opening balance kept (nil: the account has no recorded balance).
        public let opening: BalanceSnapshot?
        public let adjustmentCount: Int
        public let adjustmentSumMinorUnits: Int
        /// Snapshots moved to the archive (superseded ones included).
        public let archivedCount: Int
        /// Snapshots archived without an adjustment because a later one on the same day wins.
        public let supersededCount: Int
    }

    public struct Report: Equatable, Sendable {
        public let accounts: [AccountReport]
        public let violations: [String]

        /// Nothing to convert (e.g. a second run).
        public var isNoOp: Bool { accounts.allSatisfy { $0.archivedCount == 0 } }

        /// Plain-text summary, one line per account, then any violations.
        public var text: String {
            var lines: [String] = []
            for account in accounts {
                guard let opening = account.opening else {
                    lines.append("\(account.accountName): no recorded balance — nothing to convert.")
                    continue
                }
                var line = "\(account.accountName): opening \(Money.format(opening.balanceMinorUnits, currency: account.currency)) on \(dayString(opening.date))"
                line += "; \(account.adjustmentCount) adjustment\(account.adjustmentCount == 1 ? "" : "s") totalling \(Money.format(account.adjustmentSumMinorUnits, currency: account.currency))"
                line += "; \(account.archivedCount) archived"
                if account.supersededCount > 0 { line += " (\(account.supersededCount) superseded)" }
                lines.append(line + ".")
            }
            if violations.isEmpty {
                lines.append("Invariants: OK.")
            } else {
                lines.append("INVARIANT VIOLATIONS (\(violations.count)):")
                lines.append(contentsOf: violations.map { "  " + $0 })
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Converts every account in the caller's write transaction and returns the report; throws
    /// `BalanceConversionError.invariantViolated` (with the report) when verification fails.
    /// `now` sets "today" for the current-balance and month-end checks.
    @discardableResult
    public static func convert(db: Database, now: Date = Date()) throws -> Report {
        try convert(db: db, now: now, beforeVerification: nil)
    }

    /// `convert`; tests use `beforeVerification` to break the result and see the check abort.
    static func convert(db: Database, now: Date, beforeVerification: ((Database) throws -> Void)?) throws -> Report {
        let calendar = MonthRange.calendar
        let accounts = try Account.order(Column("id")).fetchAll(db)
        var reports: [AccountReport] = []
        var checks: [(account: Account, before: Expectations, archived: [BalanceSnapshot])] = []
        let archivedAt = Date()

        for account in accounts {
            guard let accountId = account.id else { continue }
            let snapshots = try BalanceSnapshot.filter(Column("accountId") == accountId).fetchAll(db)
                .sorted { $0.date != $1.date ? $0.date < $1.date : ($0.id ?? 0) < ($1.id ?? 0) }
            var transactions = try Transaction.filter(Column("accountId") == accountId).fetchAll(db)
            // Per day, the snapshot the balance rule picks (the last in this order); the rest are superseded.
            var winners: [BalanceSnapshot] = []
            var superseded: [BalanceSnapshot] = []
            for snapshot in snapshots {
                if let last = winners.last, calendar.isDate(last.date, inSameDayAs: snapshot.date) {
                    superseded.append(winners.removeLast())
                }
                winners.append(snapshot)
            }
            guard let opening = winners.first else {
                reports.append(AccountReport(accountId: accountId, accountName: account.displayName, currency: account.currency, opening: nil,
                                             adjustmentCount: 0, adjustmentSumMinorUnits: 0, archivedCount: 0, supersededCount: 0))
                continue
            }
            let later = Array(winners.dropFirst())
            let before = expectations(accountId: accountId, opening: opening, snapshots: snapshots, transactions: transactions, now: now)

            var count = 0
            var sum = 0
            if !later.isEmpty {
                let role = CategoryBuiltInRole.forAccount(kind: account.kind)
                let category = try BuiltInCategories.category(db: db, role: role)
                for snapshot in later {
                    let computed = NetWorthCalculator.balance(accountId: accountId, at: BalanceUpdates.endOfDay(snapshot.date),
                                                              snapshots: [opening], transactions: transactions)?.native ?? opening.balanceMinorUnits
                    let difference = snapshot.balanceMinorUnits - computed
                    guard difference != 0 else { continue }
                    let adjustment = try ManualTransactions.add(db: db, accountId: accountId, date: calendar.startOfDay(for: snapshot.date),
                                                                description: adjustmentDescription(role), amountMinorUnits: difference,
                                                                categoryId: category.id, note: adjustmentNote, allowBuiltIn: true)
                    transactions.append(adjustment)
                    count += 1
                    sum += difference
                }
            }
            let toArchive = later + superseded
            for snapshot in toArchive {
                try BalanceSnapshotArchive(snapshot: snapshot, archivedAt: archivedAt).insert(db)
                _ = try BalanceSnapshot.deleteOne(db, key: snapshot.id)
            }
            reports.append(AccountReport(accountId: accountId, accountName: account.displayName, currency: account.currency, opening: opening,
                                         adjustmentCount: count, adjustmentSumMinorUnits: sum, archivedCount: toArchive.count, supersededCount: superseded.count))
            checks.append((account, before, later))
        }

        try beforeVerification?(db)

        var violations: [String] = []
        for check in checks {
            guard let accountId = check.account.id else { continue }
            let name = check.account.displayName
            let currency = check.account.currency
            let snapshots = try BalanceSnapshot.filter(Column("accountId") == accountId).fetchAll(db)
            let transactions = try Transaction.filter(Column("accountId") == accountId).fetchAll(db)
            func balance(at date: Date) -> Int? {
                NetWorthCalculator.balance(accountId: accountId, at: date, snapshots: snapshots, transactions: transactions)?.native
            }
            for snapshot in check.archived {
                let computed = balance(at: BalanceUpdates.endOfDay(snapshot.date))
                if computed != snapshot.balanceMinorUnits {
                    violations.append("\(name): recorded balance \(Money.format(snapshot.balanceMinorUnits, currency: currency)) on \(dayString(snapshot.date)) but computed \(computed.map { Money.format($0, currency: currency) } ?? "nothing").")
                }
            }
            for (date, expected) in check.before.points {
                let actual = balance(at: date)
                if actual != expected {
                    violations.append("\(name): balance at \(dayString(date)) was \(expected.map { Money.format($0, currency: currency) } ?? "nothing"), now \(actual.map { Money.format($0, currency: currency) } ?? "nothing").")
                }
            }
        }
        let report = Report(accounts: reports, violations: violations)
        guard violations.isEmpty else { throw BalanceConversionError.invariantViolated(report) }
        return report
    }

    /// The balances that must not change: every month end from the opening month to `now`'s
    /// month, then the end of `now`'s day.
    struct Expectations {
        var points: [(date: Date, balance: Int?)]
    }

    private static func expectations(accountId: Int64, opening: BalanceSnapshot, snapshots: [BalanceSnapshot], transactions: [Transaction], now: Date) -> Expectations {
        var dates: [Date] = []
        var (year, month) = MonthRange.components(of: opening.date)
        let last = MonthRange.components(of: now)
        while MonthRange.index(year: year, month: month) <= MonthRange.index(year: last.year, month: last.month) {
            dates.append(MonthRange.of(year: year, month: month).end)
            month += 1
            if month > 12 { month = 1; year += 1 }
        }
        dates.append(BalanceUpdates.endOfDay(now))
        return Expectations(points: dates.map { date in
            (date, NetWorthCalculator.balance(accountId: accountId, at: date, snapshots: snapshots, transactions: transactions)?.native)
        })
    }

    static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = MonthRange.calendar
        formatter.timeZone = MonthRange.calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }
}

public enum BalanceConversionError: Error, LocalizedError {
    case invariantViolated(BalanceConversion.Report)

    public var errorDescription: String? {
        switch self {
        case .invariantViolated(let report):
            return "Balance conversion aborted: \(report.violations.count) invariant violation(s).\n" + report.violations.joined(separator: "\n")
        }
    }
}

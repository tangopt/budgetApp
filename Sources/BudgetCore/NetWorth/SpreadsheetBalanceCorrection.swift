import Foundation
import GRDB

/// The one-off correction of the spreadsheet balances (spec 2026-10-15): MigrateAccountBalances
/// dated month column M on the 1st of M, but it is the balance at the END of M; the EUR account
/// took the GBP-converted row; and the last column was a partial reading plus forecasts.
///
/// `apply`, in the caller's write transaction:
/// 1. deletes every adjustment `BalanceConversion` created (note `BalanceConversion.adjustmentNote`,
///    manual, described "Balance adjustment (converted)" / "Market movement (converted)");
/// 2. restores the archived recorded balances: every non-spreadsheet one (statement balances)
///    unchanged with its id; the spreadsheet ones ("Numbers import", archived or still the
///    opening) are replaced by `Input.snapshots` (values re-read from the spreadsheet, already
///    corrected and dated the 1st of M+1), noted `correctedNote`, except where a restored
///    recorded balance already exists on the same day;
/// 3. deletes `Input.deleteTransactions` (each must match exactly one unlinked transaction);
/// 4. runs `BalanceConversion.convert` (opening + adjustments + archive, with its verification).
///
/// Refuses (`alreadyCorrected`) when any recorded balance, live or archived, has `correctedNote`.
/// Any error leaves the rollback to the caller.
public enum SpreadsheetBalanceCorrection {
    public static let numbersNote = "Numbers import"
    public static let correctedNote = "Numbers import (corrected 2026-10-15)"

    public struct CorrectedSnapshot: Codable, Equatable, Sendable {
        /// `Account.name`.
        public var account: String
        /// "yyyy-MM-dd" (UTC).
        public var date: String
        public var valueMinorUnits: Int
        /// `Currency.rawValue`; must be the account's.
        public var currency: String
        /// The spreadsheet column ("yyyy-MM"), for the report.
        public var column: String?

        public init(account: String, date: String, valueMinorUnits: Int, currency: String, column: String? = nil) {
            self.account = account
            self.date = date
            self.valueMinorUnits = valueMinorUnits
            self.currency = currency
            self.column = column
        }
    }

    public struct TransactionToDelete: Codable, Equatable, Sendable {
        public var account: String
        public var date: String
        public var description: String
        public var amountMinorUnits: Int
        /// The import batch's file name, when it must match too.
        public var sourceFileName: String?
        public var evidence: String?

        public init(account: String, date: String, description: String, amountMinorUnits: Int, sourceFileName: String? = nil, evidence: String? = nil) {
            self.account = account
            self.date = date
            self.description = description
            self.amountMinorUnits = amountMinorUnits
            self.sourceFileName = sourceFileName
            self.evidence = evidence
        }
    }

    public struct UnprovenTransaction: Codable, Equatable, Sendable {
        public var account: String
        public var date: String
        public var description: String
        public var amountMinorUnits: Int
    }

    /// What `scripts/spreadsheet-balance-values.py` writes.
    public struct Input: Codable, Equatable, Sendable {
        public var snapshots: [CorrectedSnapshot]
        public var deleteTransactions: [TransactionToDelete]
        public var unproven: [UnprovenTransaction]?

        public init(snapshots: [CorrectedSnapshot], deleteTransactions: [TransactionToDelete], unproven: [UnprovenTransaction]? = nil) {
            self.snapshots = snapshots
            self.deleteTransactions = deleteTransactions
            self.unproven = unproven
        }
    }

    public struct AccountChanges: Equatable, Sendable {
        public let accountId: Int64
        public let accountName: String
        public let currency: Currency
        public var removedAdjustmentCount = 0
        public var removedAdjustmentSumMinorUnits = 0
        public var restoredOtherCount = 0
        public var replacedSpreadsheetCount = 0
        public var insertedCount = 0
        /// Corrected snapshots not inserted because a restored recorded balance has their day.
        public var droppedDates: [Date] = []
        /// Corrected values that differ from the old spreadsheet value of the same column (dated the 1st of M).
        public var changedValueCount = 0
    }

    public struct Adjustment: Equatable, Sendable {
        public let accountName: String
        public let currency: Currency
        public let date: Date
        public let amountMinorUnits: Int
    }

    public struct Payday: Equatable, Sendable {
        public let month: PayMonth
        public let closeDate: Date
        public let source: PayCloseSource
    }

    /// Balances and pay calendar at one moment (before or after).
    public struct State: Equatable, Sendable {
        /// Per account id: the unbounded balance ("today", future-dated entries included).
        public var today: [Int64: Int] = [:]
        /// Per account id, per "yyyy-MM": the month-end balance (nil: no data).
        public var monthEnds: [Int64: [String: Int?]] = [:]
        public var paydays: [Payday] = []
        /// Per "yyyy-MM-dd": the pay month containing that day.
        public var payMonthOf: [String: PayMonth] = [:]
    }

    public struct Report: Equatable, Sendable {
        public let accounts: [AccountChanges]
        public let deletedTransactions: [TransactionToDelete]
        public let unproven: [UnprovenTransaction]
        public let conversion: BalanceConversion.Report
        public let adjustments: [Adjustment]
        public let reportMonths: [String]
        public let before: State
        public let after: State

        /// Accounts whose today balance changed: (name, currency, before, after).
        public var todayChanges: [(name: String, currency: Currency, before: Int?, after: Int?)] {
            accounts.compactMap { account in
                let b = before.today[account.accountId], a = after.today[account.accountId]
                return b == a ? nil : (account.accountName, account.currency, b, a)
            }
        }

        public var text: String {
            var lines: [String] = []
            func money(_ value: Int?, _ currency: Currency) -> String { value.map { Money.format($0, currency: currency) } ?? "—" }
            lines.append("Undo and restore:")
            for a in accounts {
                var line = "  \(a.accountName): removed \(a.removedAdjustmentCount) converted adjustment(s) (\(money(a.removedAdjustmentSumMinorUnits, a.currency)))"
                line += "; restored \(a.restoredOtherCount) statement balance(s); replaced \(a.replacedSpreadsheetCount) spreadsheet balance(s) by \(a.insertedCount) corrected"
                line += " (\(a.changedValueCount) value(s) differ from the old column value)"
                if !a.droppedDates.isEmpty { line += "; dropped for a statement balance: \(a.droppedDates.map(BalanceConversion.dayString).joined(separator: ", "))" }
                lines.append(line + ".")
            }
            lines.append("Deleted transactions:")
            for t in deletedTransactions {
                lines.append("  \(t.date) \(t.description) \(Money.format(t.amountMinorUnits, currency: .gbp)) — \(t.evidence ?? "")")
            }
            for u in unproven {
                lines.append("  NOT deleted (unproven): \(u.date) \(u.description) \(Money.format(u.amountMinorUnits, currency: .gbp))")
            }
            lines.append("Conversion:")
            lines.append(contentsOf: conversion.text.split(separator: "\n").map { "  " + $0 })
            lines.append("Adjustments of 100 or more:")
            for a in adjustments where abs(a.amountMinorUnits) >= 10_000 {
                lines.append("  \(a.accountName) \(BalanceConversion.dayString(a.date)): \(Money.format(a.amountMinorUnits, currency: a.currency))")
            }
            lines.append("Paydays (before → after):")
            let afterByMonth = Dictionary(after.paydays.map { ($0.month, $0) }, uniquingKeysWith: { a, _ in a })
            for p in before.paydays {
                let a = afterByMonth[p.month]
                lines.append("  \(p.month.year)-\(String(format: "%02d", p.month.month)): \(BalanceConversion.dayString(p.closeDate)) (\(p.source)) → \(a.map { "\(BalanceConversion.dayString($0.closeDate)) (\($0.source))" } ?? "—")")
            }
            for day in before.payMonthOf.keys.sorted() {
                let b = before.payMonthOf[day]!, a = after.payMonthOf[day]
                lines.append("  \(day) is in pay month \(b.year)-\(String(format: "%02d", b.month)) → \(a.map { "\($0.year)-\(String(format: "%02d", $0.month))" } ?? "—")")
            }
            lines.append("Month-end balances (before → after):")
            for a in accounts {
                let cells = reportMonths.map { month -> String in
                    let b = before.monthEnds[a.accountId]?[month] ?? nil, x = after.monthEnds[a.accountId]?[month] ?? nil
                    return b == x ? "\(month) \(money(b, a.currency))" : "\(month) \(money(b, a.currency)) → \(money(x, a.currency))"
                }
                lines.append("  \(a.accountName): " + cells.joined(separator: "; "))
            }
            let changes = todayChanges
            if changes.isEmpty {
                lines.append("Today's balances: all unchanged.")
            } else {
                lines.append("Today's balances: unchanged except")
                for c in changes { lines.append("  \(c.name): \(money(c.before, c.currency)) → \(money(c.after, c.currency))") }
            }
            return lines.joined(separator: "\n")
        }
    }

    public enum CorrectionError: Error, LocalizedError, Equatable {
        case alreadyCorrected
        case emptyInput
        case unknownAccount(String)
        case currencyMismatch(account: String, expected: String, got: String)
        case badDate(String)
        case missingSpreadsheetValues(account: String)
        case transactionNotFound(String, matches: Int)
        case linkedTransaction(Int64)

        public var errorDescription: String? {
            switch self {
            case .alreadyCorrected: return "Already corrected: recorded balances noted \"\(SpreadsheetBalanceCorrection.correctedNote)\" exist. Nothing done."
            case .emptyInput: return "No corrected snapshots in the input."
            case .unknownAccount(let name): return "No account named \"\(name)\"."
            case .currencyMismatch(let account, let expected, let got): return "\(account) is \(expected), the input says \(got)."
            case .badDate(let text): return "Bad date \"\(text)\" (expected yyyy-MM-dd)."
            case .missingSpreadsheetValues(let account): return "\(account) has spreadsheet balances but no corrected values in the input."
            case .transactionNotFound(let what, let matches): return "Transaction to delete \(what): \(matches) matches (expected exactly 1)."
            case .linkedTransaction(let id): return "Transaction #\(id) is part of a transfer link; not deleting it."
            }
        }
    }

    public static let reportPayDays = ["2026-02-16", "2026-02-20"]

    /// See the type comment. `now` is "today" for the conversion's checks and the report.
    public static func apply(db: Database, input: Input, now: Date = Date(),
                             reportMonths: [String] = ["2025-11", "2025-12", "2026-01", "2026-02", "2026-03", "2026-04"],
                             reportPaydays: (from: PayMonth, to: PayMonth) = (PayMonth(year: 2025, month: 12), PayMonth(year: 2026, month: 4))) throws -> Report {
        let calendar = MonthRange.calendar
        guard !input.snapshots.isEmpty else { throw CorrectionError.emptyInput }
        let marked = try BalanceSnapshot.filter(Column("note") == correctedNote).fetchCount(db)
            + BalanceSnapshotArchive.filter(Column("note") == correctedNote).fetchCount(db)
        guard marked == 0 else { throw CorrectionError.alreadyCorrected }

        let accounts = try Account.order(Column("id")).fetchAll(db)
        func account(named name: String) throws -> Account {
            guard let account = accounts.first(where: { $0.name == name }) else { throw CorrectionError.unknownAccount(name) }
            return account
        }
        let before = try state(db: db, accounts: accounts, now: now, months: reportMonths, paydays: reportPaydays)
        var changes: [Int64: AccountChanges] = [:]
        for a in accounts { if let id = a.id { changes[id] = AccountChanges(accountId: id, accountName: a.displayName, currency: a.currency) } }

        // Validate the input before touching anything.
        var corrected: [(accountId: Int64, date: Date, value: Int)] = []
        for s in input.snapshots {
            let a = try account(named: s.account)
            guard s.currency == a.currency.rawValue else {
                throw CorrectionError.currencyMismatch(account: s.account, expected: a.currency.rawValue, got: s.currency)
            }
            corrected.append((a.id!, try day(s.date), s.valueMinorUnits))
        }
        let correctedAccounts = Set(corrected.map(\.accountId))

        // 1. Remove the converted adjustments.
        let descriptions = CategoryBuiltInRole.allCases.map(BalanceConversion.adjustmentDescription)
        let converted = try Transaction
            .filter(Column("note") == BalanceConversion.adjustmentNote && Column("isManual") == true && descriptions.contains(Column("rawDescription")))
            .fetchAll(db)
        try checkUnlinked(db: db, ids: converted.compactMap(\.id))
        for t in converted {
            changes[t.accountId]?.removedAdjustmentCount += 1
            changes[t.accountId]?.removedAdjustmentSumMinorUnits += t.amountMinorUnits
            _ = try Transaction.deleteOne(db, key: t.id)
        }

        // 2. Restore the archive: statement (non-spreadsheet) balances unchanged; spreadsheet ones replaced.
        var oldSpreadsheet: [Int64: [Date: Int]] = [:]
        for archived in try BalanceSnapshotArchive.fetchAll(db) {
            if archived.note == numbersNote {
                oldSpreadsheet[archived.accountId, default: [:]][archived.date] = archived.balanceMinorUnits
                changes[archived.accountId]?.replacedSpreadsheetCount += 1
            } else {
                var restored = BalanceSnapshot(id: archived.id, accountId: archived.accountId, date: archived.date,
                                               balanceMinorUnits: archived.balanceMinorUnits, note: archived.note)
                try restored.insert(db)
                changes[archived.accountId]?.restoredOtherCount += 1
            }
            _ = try BalanceSnapshotArchive.deleteOne(db, key: archived.id)
        }
        for live in try BalanceSnapshot.filter(Column("note") == numbersNote).fetchAll(db) {
            oldSpreadsheet[live.accountId, default: [:]][live.date] = live.balanceMinorUnits
            changes[live.accountId]?.replacedSpreadsheetCount += 1
            _ = try BalanceSnapshot.deleteOne(db, key: live.id)
        }
        for accountId in oldSpreadsheet.keys where !correctedAccounts.contains(accountId) {
            throw CorrectionError.missingSpreadsheetValues(account: accounts.first { $0.id == accountId }?.name ?? "#\(accountId)")
        }
        let remaining = try BalanceSnapshot.fetchAll(db)
        for c in corrected {
            if remaining.contains(where: { $0.accountId == c.accountId && calendar.isDate($0.date, inSameDayAs: c.date) }) {
                changes[c.accountId]?.droppedDates.append(c.date)
                continue
            }
            var snapshot = BalanceSnapshot(accountId: c.accountId, date: c.date, balanceMinorUnits: c.value, note: correctedNote)
            try snapshot.insert(db)
            changes[c.accountId]?.insertedCount += 1
            let oldColumnDate = calendar.date(byAdding: .month, value: -1, to: c.date)!
            if let old = oldSpreadsheet[c.accountId]?[oldColumnDate], old != c.value { changes[c.accountId]?.changedValueCount += 1 }
        }

        // 3. Delete the transactions the spreadsheet already counts.
        for d in input.deleteTransactions {
            let a = try account(named: d.account)
            let start = try day(d.date)
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            var request = Transaction.filter(Column("accountId") == a.id! && Column("date") >= start && Column("date") < end
                                             && Column("rawDescription") == d.description && Column("amountMinorUnits") == d.amountMinorUnits)
            if let file = d.sourceFileName {
                let batchIds = try ImportBatch.filter(Column("sourceFileName") == file).fetchAll(db).compactMap(\.id)
                request = request.filter(batchIds.contains(Column("importBatchId")))
            }
            let matches = try request.fetchAll(db)
            guard matches.count == 1, let id = matches[0].id else {
                throw CorrectionError.transactionNotFound("\(d.date) \(d.description) \(d.amountMinorUnits)", matches: matches.count)
            }
            try checkUnlinked(db: db, ids: [id])
            _ = try Transaction.deleteOne(db, key: id)
        }

        // 4. Convert again, verified.
        let conversion = try BalanceConversion.convert(db: db, now: now)

        let adjustments = try Transaction.filter(Column("note") == BalanceConversion.adjustmentNote).order(Column("accountId"), Column("date")).fetchAll(db)
            .map { t -> Adjustment in
                let a = accounts.first { $0.id == t.accountId }
                return Adjustment(accountName: a?.displayName ?? "#\(t.accountId)", currency: a?.currency ?? .gbp, date: t.date, amountMinorUnits: t.amountMinorUnits)
            }
        let after = try state(db: db, accounts: accounts, now: now, months: reportMonths, paydays: reportPaydays)
        let touched = accounts.compactMap { a in a.id.flatMap { changes[$0] } }
        return Report(accounts: touched, deletedTransactions: input.deleteTransactions, unproven: input.unproven ?? [],
                      conversion: conversion, adjustments: adjustments, reportMonths: reportMonths, before: before, after: after)
    }

    private static func checkUnlinked(db: Database, ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        if let link = try TransferLink.filter(ids.contains(Column("outTransactionId")) || ids.contains(Column("inTransactionId"))).fetchOne(db) {
            throw CorrectionError.linkedTransaction(ids.contains(link.outTransactionId) ? link.outTransactionId : link.inTransactionId)
        }
    }

    static func day(_ text: String) throws -> Date {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = MonthRange.calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              MonthRange.calendar.component(.day, from: date) == parts[2] else { throw CorrectionError.badDate(text) }
        return date
    }

    static func state(db: Database, accounts: [Account], now: Date, months: [String], paydays: (from: PayMonth, to: PayMonth)) throws -> State {
        let snapshots = try BalanceSnapshot.fetchAll(db)
        let transactions = try Transaction.fetchAll(db)
        var state = State()
        for account in accounts {
            guard let id = account.id else { continue }
            state.today[id] = NetWorthCalculator.balance(accountId: id, at: nil, snapshots: snapshots, transactions: transactions)?.native
            var ends: [String: Int?] = [:]
            for month in months {
                let parts = month.split(separator: "-").compactMap { Int($0) }
                guard parts.count == 2 else { continue }
                let end = MonthRange.of(year: parts[0], month: parts[1]).end
                ends[month] = NetWorthCalculator.balance(accountId: id, at: end, snapshots: snapshots, transactions: transactions)?.native
            }
            state.monthEnds[id] = ends
        }
        let payCalendar = try PayCalendar.load(db: db, today: now)
        var month = paydays.from
        while month <= paydays.to {
            state.paydays.append(Payday(month: month, closeDate: payCalendar.closeDate(of: month), source: payCalendar.closeSource(of: month)))
            month = month.next
        }
        for text in reportPayDays {
            state.payMonthOf[text] = payCalendar.month(containing: try day(text))
        }
        return state
    }
}

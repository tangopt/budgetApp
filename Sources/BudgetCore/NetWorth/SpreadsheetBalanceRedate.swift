import Foundation
import GRDB

/// The second one-off step after `SpreadsheetBalanceCorrection` (2026-10-15): the corrected
/// spreadsheet value of month column M (the balance at the END of M) was dated 00:00 on the 1st
/// of M+1, after the month-end cut-off `NetWorthCalculator.monthEndNetWorth` uses, so an account
/// carried by those values showed the previous month's value at every month end.
///
/// `apply`, in the caller's write transaction:
/// 1. every converted adjustment (`BalanceConversion.adjustmentNote`, "… (converted)") dated on
///    the day of one of its account's corrected recorded balances (`correctedNote`, archived or
///    the live opening) moves one day earlier — from the 1st of M+1 to the last day of M — and
///    so do those recorded balances. Adjustments made from statement balances (other days) stay.
/// 2. each account in `openings` gets a new opening balance at 00:00 on 31 Dec 2019 (`openingNote`):
///    the given value, or (nil) the old opening's value minus the account's transactions after
///    31 Dec 2019 00:00 up to the end of the old opening's (re-dated) day. The old opening (the
///    January 2020 column, now dated 31 Jan 2020) moves to the archive and, when the computed
///    balance at the end of its day differs, the difference becomes an adjustment dated that day.
///
/// Verification, in the same write (any failure throws `RedateError.invariantViolated`; the
/// caller rolls back): every corrected recorded balance is dated on the last day of a month and
/// equals the account's balance at that month end; every month end without a corrected value
/// (from the account's first data to today's month), every day end from `unchangedFrom` to today
/// and the unbounded balance are unchanged; so is every account's last activity.
///
/// Refuses (`alreadyApplied`) when any recorded balance, live or archived, has `openingNote`.
public enum SpreadsheetBalanceRedate {
    public static let openingNote = "Numbers import 2019 opening (2026-10-15)"
    public static let openingDate = MonthRange.calendar.date(from: DateComponents(year: 2019, month: 12, day: 31))!
    public static let unchangedFrom = MonthRange.calendar.date(from: DateComponents(year: 2026, month: 3, day: 1))!

    public struct Opening: Equatable, Sendable {
        /// `Account.name`.
        public var account: String
        /// Native minor units; nil: the old opening's value minus the transactions up to its day.
        public var valueMinorUnits: Int?

        public init(account: String, valueMinorUnits: Int?) {
            self.account = account
            self.valueMinorUnits = valueMinorUnits
        }
    }

    /// The 1 January 2020 openings: Current derived from its January 2020 column; the others are
    /// the spreadsheet's hand-typed column D "Value" (EUR from "Balance EUR International"),
    /// read by `scripts/spreadsheet-balance-values.py` (its `column2019`). Revolut is untouched.
    public static let defaultOpenings: [Opening] = [
        Opening(account: "Lloyds Classic", valueMinorUnits: nil),
        Opening(account: "Lloyds International Premier GBP", valueMinorUnits: 208_359),
        Opening(account: "Lloyds Club Joint", valueMinorUnits: 0),
        Opening(account: "Lloyds Advantage ISA Saver", valueMinorUnits: 0),
        Opening(account: "Lloyds Investment ISA", valueMinorUnits: 0),
        Opening(account: "Lloyds International Account (EUR)", valueMinorUnits: 261_340),
    ]

    public struct AccountReport: Equatable, Sendable {
        public let accountId: Int64
        public let accountName: String
        public let currency: Currency
        public var movedAdjustmentCount = 0
        public var movedRecordedCount = 0
        /// Converted adjustments not on a corrected day (statement balances): not moved.
        public var keptAdjustmentCount = 0
        public var oldOpening: (date: Date, value: Int)?
        public var newOpening: (date: Date, value: Int)?
        public var newAdjustments: [(date: Date, amount: Int)] = []

        public static func == (lhs: AccountReport, rhs: AccountReport) -> Bool {
            lhs.accountId == rhs.accountId && lhs.movedAdjustmentCount == rhs.movedAdjustmentCount
                && lhs.movedRecordedCount == rhs.movedRecordedCount && lhs.keptAdjustmentCount == rhs.keptAdjustmentCount
                && lhs.oldOpening?.date == rhs.oldOpening?.date && lhs.oldOpening?.value == rhs.oldOpening?.value
                && lhs.newOpening?.date == rhs.newOpening?.date && lhs.newOpening?.value == rhs.newOpening?.value
                && lhs.newAdjustments.map(\.date) == rhs.newAdjustments.map(\.date) && lhs.newAdjustments.map(\.amount) == rhs.newAdjustments.map(\.amount)
        }
    }

    /// Balances at one moment (before or after).
    public struct State: Equatable, Sendable {
        /// Per account id, per "yyyy-MM": the month-end balance (nil: no data).
        public var monthEnds: [Int64: [String: Int?]] = [:]
        /// Per account id, per day end from `unchangedFrom` to today.
        public var dayEnds: [Int64: [Date: Int?]] = [:]
        public var unbounded: [Int64: Int?] = [:]
        public var lastActivity: [Int64: Date?] = [:]
        /// Per year: `NetWorthCalculator.monthEndNetWorth` for December (the year cards' rule).
        public var yearEnds: [Int: Int?] = [:]
    }

    public struct Report: Equatable, Sendable {
        public let accounts: [AccountReport]
        public let before: State
        public let after: State
        public let checkedRecordedCount: Int
        public let checkedUnchangedCount: Int
        public let reportMonths: [String]
        public let years: [Int]

        public var text: String {
            var lines: [String] = []
            func money(_ value: Int?, _ currency: Currency) -> String { value.map { Money.format($0, currency: currency) } ?? "—" }
            for a in accounts {
                var line = "\(a.accountName):"
                if let o = a.newOpening {
                    line += " opening \(money(o.value, a.currency)) on \(BalanceConversion.dayString(o.date))"
                    if let old = a.oldOpening { line += " (was \(money(old.value, a.currency)) on \(BalanceConversion.dayString(old.date)), now archived)" }
                    line += ";"
                } else {
                    line += " opening untouched;"
                }
                line += " moved \(a.movedAdjustmentCount) adjustment(s) and \(a.movedRecordedCount) recorded balance(s) back a day"
                line += "; kept \(a.keptAdjustmentCount) statement adjustment(s)"
                if a.newAdjustments.isEmpty {
                    line += "; no new adjustment."
                } else {
                    line += "; new adjustment(s): " + a.newAdjustments.map { "\(BalanceConversion.dayString($0.date)) \(money($0.amount, a.currency))" }.joined(separator: ", ") + "."
                }
                lines.append(line)
            }
            lines.append("Month-end balances (before → after):")
            for a in accounts {
                let cells = reportMonths.map { month -> String in
                    let b = before.monthEnds[a.accountId]?[month] ?? nil, x = after.monthEnds[a.accountId]?[month] ?? nil
                    return b == x ? "\(month) \(money(b, a.currency))" : "\(month) \(money(b, a.currency)) → \(money(x, a.currency))"
                }
                lines.append("  \(a.accountName): " + cells.joined(separator: "; "))
            }
            lines.append("Year-end net worth (before → after):")
            for year in years {
                let b = before.yearEnds[year] ?? nil, x = after.yearEnds[year] ?? nil
                lines.append("  \(year): \(money(b, .gbp))\(b == x ? " (unchanged)" : " → \(money(x, .gbp))")")
            }
            lines.append("Verified: \(checkedRecordedCount) corrected balances equal their month end; \(checkedUnchangedCount) other balances unchanged.")
            return lines.joined(separator: "\n")
        }
    }

    public enum RedateError: Error, LocalizedError, Equatable {
        case alreadyApplied
        case nothingToRedate
        case unknownAccount(String)
        case notOnTheFirst(account: String, date: Date)
        case noCorrectedOpening(String)
        case missingOpening(String)
        case linkedTransaction(Int64)
        case invariantViolated([String])

        public var errorDescription: String? {
            switch self {
            case .alreadyApplied: return "Already re-dated: recorded balances noted \"\(SpreadsheetBalanceRedate.openingNote)\" exist. Nothing done."
            case .nothingToRedate: return "No corrected spreadsheet balances (\"\(SpreadsheetBalanceCorrection.correctedNote)\") found."
            case .unknownAccount(let name): return "No account named \"\(name)\"."
            case .notOnTheFirst(let account, let date): return "\(account): corrected balance on \(BalanceConversion.dayString(date)) is not at 00:00 on the 1st of a month."
            case .noCorrectedOpening(let name): return "\(name) has no single live corrected opening balance after 31 Dec 2019."
            case .missingOpening(let name): return "\(name) has a corrected opening balance but no 2019 opening was given."
            case .linkedTransaction(let id): return "Transaction #\(id) is part of a transfer link; not moving it."
            case .invariantViolated(let violations): return "Re-dating aborted: \(violations.count) invariant violation(s).\n" + violations.joined(separator: "\n")
            }
        }
    }

    public static let reportMonths = ["2019-12", "2020-01", "2020-02", "2020-03", "2025-11", "2025-12", "2026-01", "2026-02", "2026-03"]
    public static let reportYears = Array(2019...2025)

    public static func apply(db: Database, openings: [Opening] = defaultOpenings, now: Date = Date()) throws -> Report {
        let calendar = MonthRange.calendar
        let marked = try BalanceSnapshot.filter(Column("note") == openingNote).fetchCount(db)
            + BalanceSnapshotArchive.filter(Column("note") == openingNote).fetchCount(db)
        guard marked == 0 else { throw RedateError.alreadyApplied }

        let accounts = try Account.order(Column("id")).fetchAll(db)
        let rate = try ExchangeRateSetting.currentOrDefault(db: db)
        for o in openings where !accounts.contains(where: { $0.name == o.account }) { throw RedateError.unknownAccount(o.account) }

        let liveCorrected = try BalanceSnapshot.filter(Column("note") == SpreadsheetBalanceCorrection.correctedNote).fetchAll(db)
        let archivedCorrected = try BalanceSnapshotArchive.filter(Column("note") == SpreadsheetBalanceCorrection.correctedNote).fetchAll(db)
        guard !liveCorrected.isEmpty || !archivedCorrected.isEmpty else { throw RedateError.nothingToRedate }
        func name(_ id: Int64) -> String { accounts.first { $0.id == id }?.displayName ?? "#\(id)" }
        var correctedDays: [Int64: Set<Date>] = [:]
        for (accountId, date) in liveCorrected.map({ ($0.accountId, $0.date) }) + archivedCorrected.map({ ($0.accountId, $0.date) }) {
            guard calendar.component(.day, from: date) == 1, calendar.startOfDay(for: date) == date else {
                throw RedateError.notOnTheFirst(account: name(accountId), date: date)
            }
            correctedDays[accountId, default: []].insert(date)
        }
        let monthsTo = MonthRange.components(of: now)
        let before = try state(db: db, accounts: accounts, rate: rate, now: now, through: monthsTo)

        var reports: [Int64: AccountReport] = [:]
        for a in accounts { if let id = a.id { reports[id] = AccountReport(accountId: id, accountName: a.displayName, currency: a.currency) } }

        // 1. Move the adjustments made from corrected balances, and those balances, back a day.
        func dayBefore(_ date: Date) -> Date { calendar.date(byAdding: .day, value: -1, to: date)! }
        let descriptions = CategoryBuiltInRole.allCases.map(BalanceConversion.adjustmentDescription)
        let converted = try Transaction
            .filter(Column("note") == BalanceConversion.adjustmentNote && Column("isManual") == true && descriptions.contains(Column("rawDescription")))
            .fetchAll(db)
        let toMove = converted.filter { correctedDays[$0.accountId]?.contains($0.date) ?? false }
        let ids = toMove.compactMap(\.id)
        if !ids.isEmpty, let link = try TransferLink.filter(ids.contains(Column("outTransactionId")) || ids.contains(Column("inTransactionId"))).fetchOne(db) {
            throw RedateError.linkedTransaction(ids.contains(link.outTransactionId) ? link.outTransactionId : link.inTransactionId)
        }
        for var t in converted {
            if correctedDays[t.accountId]?.contains(t.date) ?? false {
                t.date = dayBefore(t.date)
                try t.update(db)
                reports[t.accountId]?.movedAdjustmentCount += 1
            } else {
                reports[t.accountId]?.keptAdjustmentCount += 1
            }
        }
        for var archived in archivedCorrected {
            archived.date = dayBefore(archived.date)
            try archived.update(db)
            reports[archived.accountId]?.movedRecordedCount += 1
        }
        var movedOpenings: [Int64: BalanceSnapshot] = [:]
        for var live in liveCorrected {
            live.date = dayBefore(live.date)
            try live.update(db)
            reports[live.accountId]?.movedRecordedCount += 1
            movedOpenings[live.accountId] = live
        }

        // 2. The 31 Dec 2019 openings; the old opening becomes an archived balance (+ adjustment).
        for (accountId, _) in movedOpenings where !openings.contains(where: { o in accounts.first { $0.id == accountId }?.name == o.account }) {
            throw RedateError.missingOpening(name(accountId))
        }
        for o in openings {
            let account = accounts.first { $0.name == o.account }!
            let accountId = account.id!
            let liveSnapshots = try BalanceSnapshot.filter(Column("accountId") == accountId).fetchAll(db)
            guard let old = movedOpenings[accountId], liveSnapshots.count == 1, old.date > openingDate else {
                throw RedateError.noCorrectedOpening(account.displayName)
            }
            let transactions = try Transaction.filter(Column("accountId") == accountId).fetchAll(db)
            let oldDayEnd = BalanceUpdates.endOfDay(old.date)
            let january = transactions.filter { $0.date > openingDate && $0.date <= oldDayEnd }.reduce(0) { $0 + $1.amountMinorUnits }
            let value = o.valueMinorUnits ?? (old.balanceMinorUnits - january)
            var opening = BalanceSnapshot(accountId: accountId, date: openingDate, balanceMinorUnits: value, note: openingNote)
            try opening.insert(db)
            try BalanceSnapshotArchive(snapshot: old, archivedAt: now).insert(db)
            _ = try BalanceSnapshot.deleteOne(db, key: old.id)
            let difference = old.balanceMinorUnits - (value + january)
            if difference != 0 {
                let role = CategoryBuiltInRole.forAccount(kind: account.kind)
                let category = try BuiltInCategories.category(db: db, role: role)
                try ManualTransactions.add(db: db, accountId: accountId, date: old.date, description: BalanceConversion.adjustmentDescription(role),
                                           amountMinorUnits: difference, categoryId: category.id, note: BalanceConversion.adjustmentNote, allowBuiltIn: true)
                reports[accountId]?.newAdjustments.append((old.date, difference))
            }
            reports[accountId]?.oldOpening = (old.date, old.balanceMinorUnits)
            reports[accountId]?.newOpening = (openingDate, value)
        }

        // 3. Verify.
        let after = try state(db: db, accounts: accounts, rate: rate, now: now, through: monthsTo)
        let snapshots = try BalanceSnapshot.fetchAll(db)
        let transactions = try Transaction.fetchAll(db)
        var violations: [String] = []
        var recordedChecked = 0
        var unchangedChecked = 0
        var correctedMonths: [Int64: Set<String>] = [:]
        for archived in try BalanceSnapshotArchive.filter(Column("note") == SpreadsheetBalanceCorrection.correctedNote).fetchAll(db) {
            let currency = accounts.first { $0.id == archived.accountId }?.currency ?? .gbp
            let (year, month) = MonthRange.components(of: archived.date)
            let key = monthKey(year, month)
            correctedMonths[archived.accountId, default: []].insert(key)
            let end = MonthRange.of(year: year, month: month).end
            if BalanceUpdates.endOfDay(archived.date) != end {
                violations.append("\(name(archived.accountId)): corrected balance dated \(BalanceConversion.dayString(archived.date)), not a month's last day.")
            }
            let computed = NetWorthCalculator.balance(accountId: archived.accountId, at: end, snapshots: snapshots, transactions: transactions)?.native
            recordedChecked += 1
            if computed != archived.balanceMinorUnits {
                violations.append("\(name(archived.accountId)): \(key) month end is \(computed.map { Money.format($0, currency: currency) } ?? "nothing"), the spreadsheet says \(Money.format(archived.balanceMinorUnits, currency: currency)).")
            }
        }
        for account in accounts {
            guard let id = account.id else { continue }
            let currency = account.currency
            func money(_ v: Int?) -> String { v.map { Money.format($0, currency: currency) } ?? "nothing" }
            for (month, b) in before.monthEnds[id] ?? [:] where !(correctedMonths[id]?.contains(month) ?? false) {
                // A month with no data before only gains data from a new 2019 opening.
                if b == nil, reports[id]?.newOpening != nil { continue }
                unchangedChecked += 1
                let x = after.monthEnds[id]?[month] ?? nil
                if b != x { violations.append("\(account.displayName): \(month) month end was \(money(b)), now \(money(x)).") }
            }
            for (day, b) in before.dayEnds[id] ?? [:] {
                unchangedChecked += 1
                let x = after.dayEnds[id]?[day] ?? nil
                if b != x { violations.append("\(account.displayName): balance at the end of \(BalanceConversion.dayString(day)) was \(money(b)), now \(money(x)).") }
            }
            unchangedChecked += 2
            let ub = before.unbounded[id] ?? nil, ua = after.unbounded[id] ?? nil
            if ub != ua { violations.append("\(account.displayName): balance (no end date) was \(money(ub)), now \(money(ua)).") }
            let lb = before.lastActivity[id] ?? nil, la = after.lastActivity[id] ?? nil
            if lb != la { violations.append("\(account.displayName): last activity \(lb.map(BalanceConversion.dayString) ?? "never") before, \(la.map(BalanceConversion.dayString) ?? "never") after.") }
        }
        guard violations.isEmpty else { throw RedateError.invariantViolated(violations.sorted()) }

        return Report(accounts: accounts.compactMap { $0.id.flatMap { reports[$0] } }, before: before, after: after,
                      checkedRecordedCount: recordedChecked, checkedUnchangedCount: unchangedChecked,
                      reportMonths: reportMonths, years: reportYears)
    }

    static func monthKey(_ year: Int, _ month: Int) -> String { String(format: "%04d-%02d", year, month) }

    /// Every month end from Dec 2019 to `through`, every day end from `unchangedFrom` to `now`'s
    /// day, the unbounded balance, last activity and the year-end net worths.
    static func state(db: Database, accounts: [Account], rate: ExchangeRateSetting, now: Date, through: (year: Int, month: Int)) throws -> State {
        let calendar = MonthRange.calendar
        let snapshots = try BalanceSnapshot.fetchAll(db)
        let transactions = try Transaction.fetchAll(db)
        var state = State()
        var months: [(Int, Int)] = []
        var (year, month) = (2019, 12)
        while MonthRange.index(year: year, month: month) <= MonthRange.index(year: through.year, month: through.month) {
            months.append((year, month))
            month += 1
            if month > 12 { month = 1; year += 1 }
        }
        var days: [Date] = []
        var day = unchangedFrom
        while day <= now {
            days.append(BalanceUpdates.endOfDay(day))
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        for account in accounts {
            guard let id = account.id else { continue }
            let ownSnapshots = snapshots.filter { $0.accountId == id }
            let ownTransactions = transactions.filter { $0.accountId == id }
            func balance(_ date: Date?) -> Int? {
                NetWorthCalculator.balance(accountId: id, at: date, snapshots: ownSnapshots, transactions: ownTransactions)?.native
            }
            var ends: [String: Int?] = [:]
            for (y, m) in months { ends[monthKey(y, m)] = balance(MonthRange.of(year: y, month: m).end) }
            state.monthEnds[id] = ends
            var dayEnds: [Date: Int?] = [:]
            for d in days { dayEnds[d] = balance(d) }
            state.dayEnds[id] = dayEnds
            state.unbounded[id] = balance(nil)
            state.lastActivity[id] = BalanceStaleness.lastActivity(account: account, snapshots: ownSnapshots, transactions: ownTransactions, today: now)
        }
        for y in reportYears {
            state.yearEnds[y] = NetWorthCalculator.monthEndNetWorth(accounts: accounts, snapshots: snapshots, transactions: transactions, rate: rate, year: y, month: 12)
        }
        return state
    }
}

import GRDB
import Foundation

/// What's off with a property's records over a period (spec 2026-10-16 §1 "Checks").
public struct PropertyCheckReport: Equatable, Sendable {
    /// A month a tenancy ran with no issued receipt covering any of it.
    public struct MissingReceiptMonth: Hashable, Sendable {
        public var tenancyId: Int64
        /// The calendar month, `[start, end)`.
        public var month: DateInterval
    }

    /// The deposit account's balance against the tenancies' terms.
    public struct DepositCheck: Equatable, Sendable {
        /// On this day.
        public var date: Date
        /// The deposit-role accounts' balance (amount held), in the property's currency.
        public var heldMinorUnits: Int
        /// Deposit months × the rent of each tenancy running that day.
        public var expectedDepositMinorUnits: Int
        /// The same plus advance-rent months (some landlords hold both in the account).
        public var expectedWithAdvanceMinorUnits: Int

        /// How far the balance may be off and still match (rounding, bank charges): €1.
        public static let toleranceMinorUnits = 100

        /// Which reading of the terms the balance matches, within the tolerance: deposit and
        /// advance rent together first (what the account usually holds), then the deposit
        /// alone; `nil` when neither.
        public var matchedInterpretation: DepositInterpretation? {
            if abs(heldMinorUnits - expectedWithAdvanceMinorUnits) <= Self.toleranceMinorUnits { return .depositAndAdvanceRent }
            if abs(heldMinorUnits - expectedDepositMinorUnits) <= Self.toleranceMinorUnits { return .depositOnly }
            return nil
        }

        /// Held minus the matched expectation, or the nearer one when neither matches.
        public var differenceMinorUnits: Int {
            switch matchedInterpretation {
            case .depositAndAdvanceRent: return heldMinorUnits - expectedWithAdvanceMinorUnits
            case .depositOnly: return heldMinorUnits - expectedDepositMinorUnits
            case nil:
                let a = heldMinorUnits - expectedWithAdvanceMinorUnits, b = heldMinorUnits - expectedDepositMinorUnits
                return abs(a) <= abs(b) ? a : b
            }
        }

        /// The balance equals one of the two expectations.
        public var matches: Bool { matchedInterpretation != nil }
    }

    public enum DepositInterpretation: String, Codable, Sendable {
        /// Deposit (caução) months plus advance-rent months × rent.
        case depositAndAdvanceRent
        /// Deposit months × rent.
        case depositOnly
    }

    /// A recurring cost whose next occurrence is overdue.
    public struct MissingRecurringCost: Equatable, Sendable {
        public var pattern: PropertyRecurringPattern
        public var expectedDate: Date
    }

    public var monthsWithoutReceipt: [MissingReceiptMonth] = []
    /// Issued receipts not fully paid by linked credits.
    public var receiptsWithoutCredit: [RentReceipt] = []
    /// Rent credits not linked to any receipt.
    public var creditsWithoutReceipt: [Transaction] = []
    /// `nil` when the property has no deposit-role account or no tenancy runs on the day.
    public var deposit: DepositCheck?
    public var missingRecurringCosts: [MissingRecurringCost] = []

    public init() {}

    /// How many things need a look (a matching deposit counts as none).
    public var issueCount: Int {
        monthsWithoutReceipt.count + receiptsWithoutCredit.count + creditsWithoutReceipt.count + missingRecurringCosts.count
            + (deposit.map { $0.matches ? 0 : 1 } ?? 0)
    }
}

public enum PropertyChecks {
    /// Days after a recurring cost's expected date before it counts as missing.
    public static let recurringGraceDays = 15

    /// The checks for `period` (`[start, end)`), considering only what's started by `today`:
    /// months each tenancy ran without a receipt (once the month's matching window has closed); receipts without a matched credit and credits
    /// without a receipt (`RentReceiptMatching`); the deposit held on the earlier of `today`
    /// and the period's last day against the running tenancies' terms; recurring costs
    /// (`PropertyCalendar.recurringPatterns`) whose next occurrence, in the period, is more
    /// than `recurringGraceDays` overdue.
    public static func run(db: Database, propertyId: Int64, period: DateInterval, today: Date = Date()) throws -> PropertyCheckReport {
        guard let property = try Property.fetchOne(db, key: propertyId) else { throw PropertyError.propertyNotFound }
        let calendar = MonthRange.calendar
        let today = PropertyDates.day(today)
        let horizon = min(period.end, PropertyDates.nextDay(today))
        var report = PropertyCheckReport()

        // Months without a receipt.
        let tenancies = try Tenancies.all(db: db, propertyId: propertyId)
        for tenancy in tenancies {
            let receipts = try RentReceipts.receipts(db: db, tenancyId: tenancy.id!)
            let tenancyEnd = tenancy.endDate.map(PropertyDates.nextDay) ?? horizon
            let (year, month) = MonthRange.components(of: max(tenancy.startDate, period.start))
            var monthStart = MonthRange.of(year: year, month: month).start
            while monthStart < min(horizon, tenancyEnd) {
                let next = calendar.date(byAdding: .month, value: 1, to: monthStart)!
                defer { monthStart = next }
                guard next > period.start, next > tenancy.startDate else { continue }
                // Not yet: a month's receipt is only missing once its matching window
                // (`RentReceiptMatching.Options.windowDays` after the month) has closed.
                let windowCloses = calendar.date(byAdding: .day, value: RentReceiptMatching.Options().windowDays, to: next)!
                guard windowCloses <= today else { continue }
                let covered = receipts.contains { $0.periodStart < next && PropertyDates.nextDay($0.periodEnd) > monthStart }
                if !covered { report.monthsWithoutReceipt.append(.init(tenancyId: tenancy.id!, month: DateInterval(start: monthStart, end: next))) }
            }
        }

        report.receiptsWithoutCredit = try RentReceiptMatching.unmatchedReceipts(db: db, propertyId: propertyId).filter {
            $0.periodStart < horizon && PropertyDates.nextDay($0.periodEnd) > period.start
        }
        report.creditsWithoutReceipt = try RentReceiptMatching.unmatchedCredits(db: db, propertyId: propertyId).filter {
            $0.date >= period.start && $0.date < horizon
        }

        // Deposit.
        let depositAccounts = try Properties.accounts(db: db, propertyId: propertyId, role: .deposit).map(\.accountId)
        let checkDay = PropertyDates.day(horizon.addingTimeInterval(-1))
        let running = tenancies.filter { $0.covers(checkDay) }
        if !depositAccounts.isEmpty, !running.isEmpty {
            let held = try PropertyFinance.balance(db: db, property: property, conversion: try CurrencyConversion.current(db: db),
                                                   accountIds: depositAccounts, asOf: checkDay).native
            var deposit = 0, advance = 0
            for tenancy in running {
                let rent = try Tenancies.rent(db: db, tenancyId: tenancy.id!, at: checkDay) ?? 0
                deposit += tenancy.depositMonths * rent
                advance += tenancy.advanceRentMonths * rent
            }
            report.deposit = .init(date: checkDay, heldMinorUnits: held, expectedDepositMinorUnits: deposit,
                                   expectedWithAdvanceMinorUnits: deposit + advance)
        }

        // Overdue recurring costs.
        for pattern in try PropertyCalendar.recurringPatterns(db: db, propertyId: propertyId, asOf: today, dropStopped: false) {
            let expected = pattern.nextDate
            guard expected >= period.start, expected < period.end else { continue }
            let overdue = calendar.date(byAdding: .day, value: recurringGraceDays, to: expected)!
            if overdue < today { report.missingRecurringCosts.append(.init(pattern: pattern, expectedDate: expected)) }
        }
        return report
    }
}

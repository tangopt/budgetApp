import Foundation
import GRDB

/// One property as the iPhone's Property screen shows it (iPhone spec §3.7): the tenancy,
/// this month's rent, receipt and last recharge, the mortgage and what's coming up — read
/// through the Mac's property calculators (`PropertyMonthBreakdown`, `RentReceipts`,
/// `Recharges`, `MortgageRate.status`, `PropertyFinance.balance`, `MortgageHistory.progress`,
/// `PropertyCalendar`).
public struct PropertyGlance: Equatable, Sendable {
    public enum RentStatus: Equatable, Sendable {
        /// A rent credit this calendar month, on that day (the latest).
        case received(Date)
        /// Not in yet; due on that day (the day of the month the last rent came, else the 1st).
        case expected(Date)
        /// Not in more than `RentReceiptMatching.Options.windowDays` after the day it was due.
        case late(since: Date)
        /// No tenancy runs today.
        case none
    }

    public enum ReceiptStatus: Equatable, Sendable {
        /// An issued receipt covers part of this calendar month.
        case issued
        /// A tenancy runs and no receipt covers the month yet.
        case pending
        /// No tenancy runs today.
        case none
    }

    /// The latest recharge statement's status.
    public enum RechargeStatus: Equatable, Sendable {
        case paid
        case sent
        /// A draft with charges on it.
        case readyToSend
        /// A draft with nothing on it.
        case none
    }

    public struct Mortgage: Equatable, Sendable {
        public var nextInstalmentMinorUnits: Int?
        public var nextInstalmentDate: Date?
        /// What the mortgage accounts owe at the end of today, in the property's currency.
        public var outstandingMinorUnits: Int
        /// The same in pounds, at the stored rate (`PropertyFinance.balance`'s `gbp`).
        public var outstandingGBPMinorUnits: Int
        /// Nil without the amount borrowed.
        public var progress: MortgageHistory.Progress?
        /// The rate of the period in force today.
        public var ratePercent: Double?
        /// The next revision of the rate.
        public var nextReview: Date?
    }

    public var property: Property
    /// The tenancy running today (else none): its start and end (nil = ongoing).
    public var letSince: Date?
    public var contractTo: Date?
    public var rent: RentStatus
    /// This month's rent, in the property's currency: the received credit's amount; else, while
    /// it's expected or late, the tenancy's rent on the day it's due (`Tenancies.rent`). Nil
    /// without a running tenancy (or a rent recorded for it).
    public var rentMinorUnits: Int?
    public var receipt: ReceiptStatus
    /// Nil when no tenancy has a recharge statement.
    public var lastRecharge: RechargeStatus?
    /// That statement's month (its first day) and total, in the property's currency.
    public var lastRechargeMonth: Date?
    public var lastRechargeTotalMinorUnits: Int?
    /// Nil without a mortgage account.
    public var mortgage: Mortgage?
    /// The obligations over the next `comingUpDays`, by date.
    public var comingUp: [PropertyObligation]

    public static let comingUpDays = 60

    /// Every property, by name.
    public static func all(db: Database, today: Date) throws -> [PropertyGlance] {
        try Properties.all(db: db).compactMap(\.id).map { try make(db: db, propertyId: $0, today: today) }
    }

    public static func make(db: Database, propertyId: Int64, today: Date) throws -> PropertyGlance {
        guard let property = try Property.fetchOne(db, key: propertyId) else { throw PropertyError.propertyNotFound }
        let calendar = MonthRange.calendar
        let day = PropertyDates.day(today)
        let (year, month) = MonthRange.components(of: day)
        let monthStart = MonthRange.of(year: year, month: month).start
        let thisMonth = DateInterval(start: monthStart, end: calendar.date(byAdding: .month, value: 1, to: monthStart)!)

        let tenancies = try Tenancies.all(db: db, propertyId: propertyId)
        let running = tenancies.last { $0.covers(day) }

        let end = calendar.date(byAdding: .day, value: comingUpDays, to: day)!
        let rent = try rentStatus(db: db, propertyId: propertyId, running: running, thisMonth: thisMonth, today: day)
        let statement = try latestStatement(db: db, tenancies: tenancies)
        return PropertyGlance(
            property: property,
            letSince: running?.startDate,
            contractTo: running?.endDate,
            rent: rent.status,
            rentMinorUnits: rent.amount,
            receipt: try receiptStatus(db: db, running: running, thisMonth: thisMonth),
            lastRecharge: statement.map(rechargeStatus),
            lastRechargeMonth: statement?.month,
            lastRechargeTotalMinorUnits: statement?.totalMinorUnits,
            mortgage: try mortgage(db: db, property: property, today: day),
            comingUp: try PropertyCalendar.obligations(db: db, propertyId: propertyId, from: day, to: end, today: day)
        )
    }

    /// Received when this month's cash flow has a rent line (`PropertyFinance.monthBreakdown`);
    /// else, while a tenancy runs, due on the day of the month the last rent came (within the
    /// three months before) or the 1st — never before the tenancy starts — and late past the
    /// receipt matching window. (Advance-rent months play no part: the Mac uses them only for
    /// the deposit check, and a month paid ahead still has its receipt and credit.)
    /// The amount beside it: the received line's `counted.native`, else the tenancy's rent on the due day.
    static func rentStatus(db: Database, propertyId: Int64, running: Tenancy?, thisMonth: DateInterval,
                           today: Date) throws -> (status: RentStatus, amount: Int?) {
        let calendar = MonthRange.calendar
        let received = try PropertyFinance.monthBreakdown(db: db, propertyId: propertyId, interval: thisMonth).group(.rent)?.lines
            .filter { $0.counted.native > 0 }.last
        if let received { return (.received(PropertyDates.day(received.transaction.date)), received.counted.native) }
        guard let running, let tenancyId = running.id else { return (.none, nil) }

        let before = DateInterval(start: calendar.date(byAdding: .month, value: -3, to: thisMonth.start)!, end: thisMonth.start)
        let last = try PropertyFinance.monthBreakdown(db: db, propertyId: propertyId, interval: before).group(.rent)?.lines
            .filter { $0.counted.native > 0 }.last
        let length = calendar.range(of: .day, in: .month, for: thisMonth.start)!.count
        let dueDay = min(last.map { calendar.component(.day, from: $0.transaction.date) } ?? 1, length)
        let due = max(calendar.date(byAdding: .day, value: dueDay - 1, to: thisMonth.start)!, PropertyDates.day(running.startDate))
        let lateAfter = calendar.date(byAdding: .day, value: RentReceiptMatching.Options().windowDays, to: due)!
        let amount = try Tenancies.rent(db: db, tenancyId: tenancyId, at: due)
        return (today > lateAfter ? .late(since: due) : .expected(due), amount)
    }

    static func receiptStatus(db: Database, running: Tenancy?, thisMonth: DateInterval) throws -> ReceiptStatus {
        guard let tenancy = running, let tenancyId = tenancy.id else { return .none }
        let covered = try RentReceipts.receipts(db: db, tenancyId: tenancyId).contains {
            $0.periodStart < thisMonth.end && PropertyDates.nextDay($0.periodEnd) > thisMonth.start
        }
        return covered ? .issued : .pending
    }

    /// The latest month's statement across the tenancies.
    static func latestStatement(db: Database, tenancies: [Tenancy]) throws -> RechargeStatement? {
        try tenancies.compactMap(\.id).compactMap { try Recharges.statements(db: db, tenancyId: $0).first }
            .max { $0.month < $1.month }
    }

    static func rechargeStatus(_ latest: RechargeStatement) -> RechargeStatus {
        switch latest.status {
        case .paid: return .paid
        case .sent: return .sent
        case .draft: return latest.totalMinorUnits != 0 ? .readyToSend : RechargeStatus.none
        }
    }

    static func mortgage(db: Database, property: Property, today: Date) throws -> Mortgage? {
        guard let propertyId = property.id, let status = try MortgageRate.status(db: db, propertyId: propertyId, today: today) else { return nil }
        let accountIds = try Properties.accounts(db: db, propertyId: propertyId, role: .mortgage).map(\.accountId)
        let balance = try PropertyFinance.balance(db: db, property: property, conversion: try CurrencyConversion.current(db: db),
                                                  accountIds: accountIds, asOf: today)
        let owed = balance.native
        return Mortgage(nextInstalmentMinorUnits: status.nextInstalmentMinorUnits, nextInstalmentDate: status.nextDue,
                        outstandingMinorUnits: owed, outstandingGBPMinorUnits: balance.gbp,
                        progress: MortgageHistory.progress(terms: status.terms, owedMinorUnits: owed, today: today),
                        ratePercent: status.current?.ratePercent, nextReview: status.nextRevision)
    }
}

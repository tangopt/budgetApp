import GRDB
import Foundation

/// What a mortgage will owe from today to its end, payment by payment (the Overview's loan
/// chart zoomed out). Assumptions, shown with the chart: the rate charged now is held
/// constant to the end; interest is charged monthly at the annual rate ÷ 12 on what's owed,
/// paid with each instalment on the day the last one was paid; at each rate revision (the
/// property's revision months, on their 1st) the bank resets the instalment to the annuity
/// that leaves the balloon for the final instalment — with the rate unchanged this keeps the
/// loan on course; the final instalment repays everything left (the balloon). Without a final
/// day, the instalment runs on until the loan is repaid.
public enum MortgageProjection {
    public struct Input: Equatable, Sendable {
        /// Owed at the end of `asOf`, positive.
        public var owedMinorUnits: Int
        public var asOf: Date
        public var annualRatePercent: Double
        /// The instalment paid now (interest and capital).
        public var instalmentMinorUnits: Int
        /// The day of the month instalments are paid (clamped to short months).
        public var paymentDay: Int
        public var finalInstalmentDate: Date?
        public var balloonMinorUnits: Int
        public var revisionMonths: [Int]

        public init(owedMinorUnits: Int, asOf: Date, annualRatePercent: Double, instalmentMinorUnits: Int, paymentDay: Int,
                    finalInstalmentDate: Date? = nil, balloonMinorUnits: Int = 0, revisionMonths: [Int] = MortgageTerms.defaultRevisionMonths) {
            self.owedMinorUnits = owedMinorUnits
            self.asOf = asOf
            self.annualRatePercent = annualRatePercent
            self.instalmentMinorUnits = instalmentMinorUnits
            self.paymentDay = paymentDay
            self.finalInstalmentDate = finalInstalmentDate
            self.balloonMinorUnits = balloonMinorUnits
            self.revisionMonths = revisionMonths
        }
    }

    /// One projected instalment.
    public struct Payment: Equatable, Sendable {
        public var date: Date
        /// What the instalment paid (interest and capital; the last one, the balloon too).
        public var paidMinorUnits: Int
        public var interestMinorUnits: Int
        /// Owed after it.
        public var owedMinorUnits: Int
    }

    public enum End: Equatable, Sendable {
        /// Repaid with the final instalment on the day given in the terms.
        case finalInstalment
        /// Repaid by the instalments (no final day given).
        case repaid
        /// The instalment doesn't cover the interest: it never would be repaid.
        case neverRepaid
        /// Nothing owed, or the final day has passed.
        case nothingToProject
    }

    public struct Result: Equatable, Sendable {
        public var payments: [Payment]
        public var end: End
        /// The last instalment (the balloon included), when the loan ends.
        public var finalPaymentMinorUnits: Int? { end == .finalInstalment || end == .repaid ? payments.last?.paidMinorUnits : nil }
        public var finalDate: Date? { end == .finalInstalment || end == .repaid ? payments.last?.date : nil }
        public var totalInterestMinorUnits: Int { payments.reduce(0) { $0 + $1.interestMinorUnits } }
    }

    /// The most instalments projected without a final day (50 years).
    public static let maxPayments = 600

    public static func project(_ input: Input) -> Result {
        guard input.owedMinorUnits > 0, input.paymentDay >= 1 else { return Result(payments: [], end: .nothingToProject) }
        let calendar = MonthRange.calendar
        let rate = input.annualRatePercent / 1200
        let final = input.finalInstalmentDate.map(PropertyDates.day)
        if let final, final <= PropertyDates.day(input.asOf) { return Result(payments: [], end: .nothingToProject) }

        // The instalment days after `asOf`, up to the final one.
        func paymentDate(monthsAfter offset: Int) -> Date {
            let (year, month) = MonthRange.components(of: input.asOf)
            let start = calendar.date(byAdding: .month, value: offset, to: MonthRange.of(year: year, month: month).start)!
            let length = calendar.range(of: .day, in: .month, for: start)!.count
            return calendar.date(byAdding: .day, value: min(input.paymentDay, length) - 1, to: start)!
        }
        var dates: [Date] = []
        var offset = 0
        while dates.count < maxPayments {
            let date = paymentDate(monthsAfter: offset)
            offset += 1
            if date <= PropertyDates.day(input.asOf) { continue }
            if let final, date > final { break }
            dates.append(date)
        }
        // A final day past the horizon (`maxPayments`): not projected.
        if let final, dates.count == maxPayments, dates.last.map({ $0 < final }) == true {
            return Result(payments: [], end: .neverRepaid)
        }
        // A final day that isn't an instalment day: it's still the last payment.
        if let final, dates.last != final { dates.append(final) }

        var revisions = MortgageTerms.revisionDates(months: input.revisionMonths, from: PropertyDates.nextDay(input.asOf),
                                                    to: PropertyDates.nextDay(dates.last ?? input.asOf))
        var owed = input.owedMinorUnits
        var instalment = input.instalmentMinorUnits
        var payments: [Payment] = []
        for (index, date) in dates.enumerated() {
            let isLast = final != nil && index == dates.count - 1
            // The first instalment on or after a revision: reset to the annuity for what's left.
            if final != nil, let revision = revisions.first, revision <= date {
                revisions.removeAll { $0 <= date }
                let remaining = dates.count - index
                instalment = Int(BBVAFundMortgageImport.annuityPayment(balance: owed, annualRate: input.annualRatePercent, payments: remaining,
                                                                       balloon: input.balloonMinorUnits).rounded())
            }
            let interest = Int((Double(owed) * rate).rounded())
            if final == nil && instalment <= interest { return Result(payments: payments, end: .neverRepaid) }
            if isLast || owed + interest <= instalment {
                payments.append(Payment(date: date, paidMinorUnits: owed + interest, interestMinorUnits: interest, owedMinorUnits: 0))
                return Result(payments: payments, end: final == nil ? .repaid : .finalInstalment)
            }
            owed += interest - instalment
            payments.append(Payment(date: date, paidMinorUnits: instalment, interestMinorUnits: interest, owedMinorUnits: owed))
        }
        return Result(payments: payments, end: .neverRepaid)
    }

    /// Where the rate a projection uses comes from.
    public enum RateSource: Equatable, Sendable {
        /// Entered in the mortgage terms.
        case entered
        /// Worked out from the interest charged on this day: interest × 12 ÷ what was owed before.
        case derived(Date)
    }

    /// What a property's projection starts from, read from its data.
    public struct Basis: Equatable, Sendable {
        public var input: Input
        public var rateSource: RateSource
        public var terms: PropertyMortgageTerms
        public var currency: Currency
    }

    /// The projection's starting point for the property: what the mortgage accounts owe at
    /// the end of `today`, the latest instalment paid into them (and its day of the month), the
    /// rate (the terms', else the largest expense row on the loan on the latest instalment's
    /// day × 12 ÷ what was owed the day before) and
    /// the terms' final day, balloon and revision months. `nil` without a mortgage account, a
    /// balance owed, an instalment or a rate.
    public static func basis(db: Database, propertyId: Int64, today: Date) throws -> Basis? {
        guard let property = try Property.fetchOne(db, key: propertyId) else { throw PropertyError.propertyNotFound }
        let terms = try MortgageTerms.terms(db: db, propertyId: propertyId)
        let accountIds = try Properties.accounts(db: db, propertyId: propertyId, role: .mortgage).map(\.accountId)
        guard !accountIds.isEmpty else { return nil }
        let conversion = try CurrencyConversion.current(db: db)
        let day = PropertyDates.day(today)
        let owed = try PropertyFinance.balance(db: db, property: property, conversion: conversion, accountIds: accountIds, asOf: day).native
        guard owed > 0 else { return nil }
        let accounts = Dictionary(uniqueKeysWithValues: try Account.filter(accountIds.contains(Column("id"))).fetchAll(db).map { ($0.id!, $0) })
        func native(_ value: Int, _ accountId: Int64) -> Int {
            PropertyFinance.convert(value, currency: accounts[accountId]?.currency ?? property.currency, property: property, conversion: conversion).native
        }

        // The latest instalment of each account, added up; the day of the latest.
        var instalment = 0, lastDate: Date?
        for id in accountIds {
            guard let leg = try PropertyCalendar.mortgageLegs(db: db, accountId: id, before: day).last else { continue }
            instalment += native(leg.amountMinorUnits, id)
            lastDate = max(lastDate ?? leg.date, leg.date)
        }
        guard instalment > 0, let lastDate else { return nil }

        let rate: Double, source: RateSource
        if let entered = terms.annualRatePercent {
            (rate, source) = (entered, .entered)
        } else {
            // The interest charged with the latest instalment: the largest expense row on the
            // loan that day (a fee or tax charged with it, or on another day, isn't the rate).
            let expenseIds = try Category.filter(Column("type") == CategoryType.expense.rawValue && Column("builtInRole") == nil)
                .fetchAll(db).compactMap(\.id)
            let instalmentDay = PropertyDates.day(lastDate)
            guard let interest = try Transaction
                .filter(accountIds.contains(Column("accountId")) && Column("date") >= instalmentDay
                        && Column("date") < PropertyDates.nextDay(instalmentDay) && Column("amountMinorUnits") < 0
                        && expenseIds.contains(Column("categoryId")))
                .order(Column("amountMinorUnits").asc, Column("id").desc).fetchOne(db) else { return nil }
            let interestDay = PropertyDates.day(interest.date)
            let before = MonthRange.calendar.date(byAdding: .day, value: -1, to: interestDay)!
            let owedBefore = try PropertyFinance.balance(db: db, property: property, conversion: conversion, accountIds: accountIds, asOf: before).native
            guard owedBefore > 0 else { return nil }
            rate = Double(native(-interest.amountMinorUnits, interest.accountId)) * 1200 / Double(owedBefore)
            source = .derived(interestDay)
        }
        let input = Input(owedMinorUnits: owed, asOf: day, annualRatePercent: rate, instalmentMinorUnits: instalment,
                          paymentDay: MonthRange.calendar.component(.day, from: lastDate), finalInstalmentDate: terms.finalInstalmentDate,
                          balloonMinorUnits: terms.balloonMinorUnits ?? 0, revisionMonths: terms.revisionMonths)
        return Basis(input: input, rateSource: source, terms: terms, currency: property.currency)
    }
}

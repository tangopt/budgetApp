import GRDB
import Foundation

/// A rate the user gives for one revision period (the bank's notice says otherwise): it wins
/// over the rate the rules work out, from `periodStart` (a revision day) to the next revision.
public struct MortgageRateOverride: Codable, Equatable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable {
    public var id: Int64?
    public var propertyId: Int64
    /// The revision day the period starts on (a UTC midnight).
    public var periodStart: Date
    public var ratePercent: Double
    public var note: String?

    public static let databaseTableName = "mortgageRateOverride"

    public init(id: Int64? = nil, propertyId: Int64, periodStart: Date, ratePercent: Double, note: String? = nil) {
        self.id = id
        self.propertyId = propertyId
        self.periodStart = periodStart
        self.ratePercent = ratePercent
        self.note = note
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// The mortgage's rate worked out from its rules (`PropertyMortgageTerms`): for each revision
/// period, the index's fixing (by the terms' convention, rounded to the terms' decimals) plus
/// the spread — or the fixed rate, or an override the user gave for the period, which always
/// wins — and the instalment the bank resets to at the revision: the annuity, at the period's
/// rate ÷ 12, for what's owed at the revision over the instalments left, that leaves the
/// balloon for the final instalment (which repays the balloon with its month's interest).
public enum MortgageRate {
    // MARK: Index values

    /// One index's stored values, as the rules read them.
    public struct Series: Equatable, Sendable {
        public var index: InterestIndex
        /// Monthly averages by the month's 1st.
        public var monthly: [Date: Double]
        /// Daily fixings by the day.
        public var daily: [Date: Double]

        public init(index: InterestIndex, monthly: [Date: Double] = [:], daily: [Date: Double] = [:]) {
            self.index = index
            self.monthly = monthly
            self.daily = daily
        }

        /// The stored values of `index`.
        public static func load(db: Database, index: InterestIndex) throws -> Series {
            guard index != .fixed else { return Series(index: index) }
            var series = Series(index: index)
            for value in try InterestIndexValues.all(db: db, index: index) {
                switch value.period {
                case .month: series.monthly[value.date] = value.valuePercent
                case .day: series.daily[value.date] = value.valuePercent
                }
            }
            return series
        }
    }

    /// The index value a revision uses.
    public struct Fixing: Equatable, Sendable {
        public var index: InterestIndex
        public var convention: MortgageFixingConvention
        /// The month's 1st (a monthly average) or the day of the daily fixing.
        public var date: Date
        /// As stored.
        public var rawPercent: Double
        /// Rounded to the terms' decimals: what the rate adds the spread to.
        public var valuePercent: Double

        /// "Sep 2026 average" or "29 Sep 2026".
        public var dateText: String {
            switch convention {
            case .previousMonthAverage:
                let (year, month) = MonthRange.components(of: date)
                return "\(MortgageTerms.shortMonthName(month)) \(year) average"
            case .businessDaysBefore:
                return MortgageTerms.dayText(date)
            }
        }
    }

    /// Where a period's rate comes from.
    public enum Source: Equatable, Sendable {
        /// The index's fixing for the period plus the spread.
        case index(Fixing)
        /// The latest fixing known, held for a period whose own isn't published yet (projection).
        case heldIndex(Fixing)
        /// The terms' fixed rate.
        case fixed
        /// Given by the user for the period.
        case override(note: String?)
    }

    /// A revision period's rate.
    public struct PeriodRate: Equatable, Sendable {
        /// The revision day the period starts on.
        public var start: Date
        public var ratePercent: Double
        public var source: Source
        /// The terms' spread (for an index).
        public var spreadPercent: Double?

        public var fixing: Fixing? {
            switch source {
            case let .index(fixing), let .heldIndex(fixing): return fixing
            case .fixed, .override: return nil
            }
        }

        public var isHeld: Bool { if case .heldIndex = source { return true } else { return false } }

        /// "Euribor 3M 2.135% (fixed Sep 2026 average) + 1.000% = 3.135%", "Fixed 2.500%",
        /// "3.700% (given for the period)".
        public var explanation: String {
            let total = percent(ratePercent)
            switch source {
            case let .index(fixing), let .heldIndex(fixing):
                let held = isHeld ? " held" : ""
                let spread = spreadPercent.map { $0 < 0 ? " − \(percent(-$0).unbroken)" : " + \(percent($0).unbroken)" } ?? ""
                return "\(fixing.index.displayName)\(held) \(percent(fixing.valuePercent).unbroken) (fixed \(fixing.dateText.unbroken))\(spread) = \(total.unbroken)"
            case .fixed:
                return "Fixed \(total.unbroken)"
            case .override:
                return "\(total.unbroken) (given for the period)"
            }
        }
    }

    /// "3.135%": a rate as the bank writes it, three decimals.
    public static func percent(_ value: Double) -> String { String(format: "%.3f%%", value) }

    /// `value` rounded half away from zero to `decimals`.
    public static func round(_ value: Double, decimals: Int) -> Double {
        let factor = pow(10, Double(decimals))
        return (value * factor).rounded(.toNearestOrAwayFromZero) / factor
    }

    /// The index value a revision on `revision` uses under the convention: the previous
    /// month's average (`.month`, dated its 1st) or the daily fixing `businessDays` TARGET
    /// business days before (`.day`).
    public static func fixingKey(revision: Date, convention: MortgageFixingConvention, businessDays: Int) -> (period: InterestIndexPeriod, date: Date) {
        switch convention {
        case .previousMonthAverage:
            let start = MonthRange.calendar.date(byAdding: .month, value: -1, to: InterestIndexValues.key(revision, period: .month))!
            return (.month, start)
        case .businessDaysBefore:
            return (.day, TargetCalendar.businessDay(before: PropertyDates.day(revision), count: businessDays))
        }
    }

    /// The fixing for a revision on `revision`, when the series has it.
    public static func fixing(revision: Date, terms: PropertyMortgageTerms, series: Series) -> Fixing? {
        guard let index = terms.rateIndex, index != .fixed, series.index == index else { return nil }
        let key = fixingKey(revision: revision, convention: terms.fixingConvention, businessDays: terms.fixingBusinessDays)
        guard let raw = key.period == .month ? series.monthly[key.date] : series.daily[key.date] else { return nil }
        return Fixing(index: index, convention: terms.fixingConvention, date: key.date, rawPercent: raw,
                      valuePercent: round(raw, decimals: terms.indexDecimals))
    }

    /// The latest fixing the series has on or before the one `revision` would use.
    public static func latestFixing(onOrBefore revision: Date, terms: PropertyMortgageTerms, series: Series) -> Fixing? {
        guard let index = terms.rateIndex, index != .fixed, series.index == index else { return nil }
        let key = fixingKey(revision: revision, convention: terms.fixingConvention, businessDays: terms.fixingBusinessDays)
        let values = key.period == .month ? series.monthly : series.daily
        guard let date = values.keys.filter({ $0 <= key.date }).max() else { return nil }
        return Fixing(index: index, convention: terms.fixingConvention, date: date, rawPercent: values[date]!,
                      valuePercent: round(values[date]!, decimals: terms.indexDecimals))
    }

    /// The rate of the period starting on the revision day `start`: the override for it, else
    /// the fixed rate, else the fixing plus the spread; with `holdLatest`, a fixing not yet
    /// published is the latest one known (`.heldIndex`). Nil without rules or a fixing.
    public static func rate(periodStart start: Date, terms: PropertyMortgageTerms, series: Series,
                            overrides: [MortgageRateOverride] = [], holdLatest: Bool = false) -> PeriodRate? {
        let day = PropertyDates.day(start)
        if let given = overrides.first(where: { PropertyDates.day($0.periodStart) == day }) {
            return PeriodRate(start: day, ratePercent: given.ratePercent, source: .override(note: given.note), spreadPercent: terms.spreadPercent)
        }
        switch terms.rateIndex {
        case nil:
            return nil
        case .fixed?:
            return terms.annualRatePercent.map { PeriodRate(start: day, ratePercent: $0, source: .fixed, spreadPercent: nil) }
        default:
            guard let spread = terms.spreadPercent else { return nil }
            if let fixing = fixing(revision: day, terms: terms, series: series) {
                return PeriodRate(start: day, ratePercent: round(fixing.valuePercent + spread, decimals: max(terms.indexDecimals, 3)),
                                  source: .index(fixing), spreadPercent: spread)
            }
            guard holdLatest, let fixing = latestFixing(onOrBefore: day, terms: terms, series: series) else { return nil }
            return PeriodRate(start: day, ratePercent: round(fixing.valuePercent + spread, decimals: max(terms.indexDecimals, 3)),
                              source: .heldIndex(fixing), spreadPercent: spread)
        }
    }

    // MARK: Instalment and interest

    /// The instalment the bank resets to at a revision (minor units, rounded to the cent): the
    /// annuity at `annualRatePercent` ÷ 12 for `owed` that leaves `balloon`. `remaining` counts
    /// the instalments from this one to the final one, both included. With a balloon, the final
    /// instalment repays the balloon with its month's interest, so the annuity runs over the
    /// instalments before it (`remaining` − 1); without one, over all of them.
    public static func instalment(owed: Int, annualRatePercent: Double, remaining: Int, balloon: Int) -> Int? {
        let payments = balloon > 0 ? remaining - 1 : remaining
        guard payments >= 1, owed > 0 else { return nil }
        return Int(BBVAFundMortgageImport.annuityPayment(balance: owed, annualRate: annualRatePercent, payments: payments, balloon: balloon).rounded())
    }

    /// A month's interest on `owed`: 30/360 owed × rate ÷ 12; Actual/360 owed × rate × the
    /// days from `previousDue` to `due` ÷ 360 (a month of 30 without `previousDue`). Rounded
    /// to the cent as the terms say.
    public static func interest(owed: Int, annualRatePercent: Double, dayCount: MortgageDayCount, previousDue: Date?, due: Date,
                                rounding: MortgageInterestRounding) -> Int {
        let exact: Double
        switch dayCount {
        case .thirty360:
            exact = Double(owed) * annualRatePercent / 1200
        case .actual360:
            let days = previousDue.map { PropertyFinance.days(PropertyDates.day($0), PropertyDates.day(due)) } ?? 30
            exact = Double(owed) * annualRatePercent / 100 * Double(days) / 360
        }
        switch rounding {
        case .nearest: return Int(exact.rounded(.toNearestOrAwayFromZero))
        case .down: return Int(exact.rounded(.towardZero))
        }
    }

    // MARK: From the database

    /// The property's stored overrides, by period.
    public static func overrides(db: Database, propertyId: Int64) throws -> [MortgageRateOverride] {
        try MortgageRateOverride.filter(Column("propertyId") == propertyId).order(Column("periodStart")).fetchAll(db)
    }

    /// Sets (replacing any) the rate for the period starting on the revision day `periodStart`.
    @discardableResult
    public static func setOverride(db: Database, propertyId: Int64, periodStart: Date, ratePercent: Double, note: String? = nil) throws -> MortgageRateOverride {
        guard try Property.fetchOne(db, key: propertyId) != nil else { throw PropertyError.propertyNotFound }
        guard ratePercent.isFinite, (0...50).contains(ratePercent) else { throw MortgageTermsError.invalidRate }
        let day = PropertyDates.day(periodStart)
        var row = try MortgageRateOverride.filter(Column("propertyId") == propertyId && Column("periodStart") == day).fetchOne(db)
            ?? MortgageRateOverride(propertyId: propertyId, periodStart: day, ratePercent: ratePercent)
        row.ratePercent = ratePercent
        row.note = Transaction.normalizedNote(note)
        try row.save(db)
        return row
    }

    /// Removes the period's override; `false` when there was none.
    @discardableResult
    public static func removeOverride(db: Database, propertyId: Int64, periodStart: Date) throws -> Bool {
        try MortgageRateOverride.filter(Column("propertyId") == propertyId && Column("periodStart") == PropertyDates.day(periodStart)).deleteAll(db) > 0
    }

    /// The rate in force now and what comes next (Profile's Mortgage panel).
    public struct Status: Equatable, Sendable {
        public var terms: PropertyMortgageTerms
        /// The period in force on `today` (its revision on or before today).
        public var current: PeriodRate?
        /// The next revision day after today, before the final instalment.
        public var nextRevision: Date?
        /// The next instalment due on or after today, and what it will be (nil without the
        /// number of instalments left, a balance owed or a rate).
        public var nextDue: Date?
        public var nextInstalmentMinorUnits: Int?
        /// The instalments left from the next one (the final one included), when known.
        public var remainingInstalments: Int?
        public var currency: Currency
    }

    /// The stored series of the terms' index (empty for a fixed rate or none).
    public static func series(db: Database, terms: PropertyMortgageTerms) throws -> Series {
        guard let index = terms.rateIndex, index != .fixed else { return Series(index: terms.rateIndex ?? .fixed) }
        return try Series.load(db: db, index: index)
    }

    /// The revision day on or before `date` (the 1st of the latest revision month), if any in
    /// the ten years before.
    public static func periodStart(containing date: Date, months: [Int]) -> Date? {
        let from = MonthRange.calendar.date(byAdding: .year, value: -10, to: date)!
        return MortgageTerms.revisionDates(months: months, from: from, to: PropertyDates.nextDay(date)).last
    }

    /// The due days of the instalments from `from` (on or after) up to `until` (included), on
    /// `day` of each month.
    static func dueDates(from: Date, until: Date, day: Int, limit: Int = MortgageProjection.maxPayments) -> [Date] {
        var result: [Date] = []
        var offset = -1
        while result.count < limit {
            let date = MortgageTerms.dueDate(monthsAfter: offset, from: from, day: day)
            offset += 1
            if date < PropertyDates.day(from) { continue }
            if date > until { break }
            result.append(date)
        }
        return result
    }

    /// The instalments left from the one due on `due` to the final one, both included: from
    /// the number of instalments and the first one's day, else counted to the final day.
    static func remaining(terms: PropertyMortgageTerms, due: Date, paymentDay: Int) -> Int? {
        if let total = terms.totalInstalments, let number = terms.instalmentNumber(dueIn: due) {
            return total - number + 1
        }
        guard let final = terms.effectiveFinalInstalmentDate, final >= due else { return nil }
        let dates = dueDates(from: due, until: final, day: paymentDay)
        return dates.last == PropertyDates.day(final) ? dates.count : dates.count + 1
    }

    /// The rate now, the next revision and the next instalment, for the property's mortgage;
    /// nil without a mortgage account.
    public static func status(db: Database, propertyId: Int64, today: Date) throws -> Status? {
        guard let property = try Property.fetchOne(db, key: propertyId) else { throw PropertyError.propertyNotFound }
        let terms = try MortgageTerms.terms(db: db, propertyId: propertyId)
        let accountIds = try Properties.accounts(db: db, propertyId: propertyId, role: .mortgage).map(\.accountId)
        guard !accountIds.isEmpty else { return nil }
        let day = PropertyDates.day(today)
        let series = try series(db: db, terms: terms)
        let overrides = try overrides(db: db, propertyId: propertyId)
        var status = Status(terms: terms, currency: property.currency)
        if let start = periodStart(containing: day, months: terms.revisionMonths) {
            status.current = rate(periodStart: start, terms: terms, series: series, overrides: overrides)
        } else if terms.rateIndex == .fixed {
            status.current = rate(periodStart: day, terms: terms, series: series, overrides: overrides)
        }
        let final = terms.effectiveFinalInstalmentDate
        let horizon = final.map(PropertyDates.nextDay) ?? MonthRange.calendar.date(byAdding: .year, value: 2, to: day)!
        status.nextRevision = MortgageTerms.revisionDates(months: terms.revisionMonths, from: PropertyDates.nextDay(day), to: horizon).first

        // The next instalment: on the terms' payment day, else the latest instalment's.
        var paymentDay = terms.paymentDay
        if paymentDay == nil {
            let last = try accountIds.compactMap { try PropertyCalendar.mortgageLegs(db: db, accountId: $0, before: day).last?.date }.max()
            paymentDay = last.map { MonthRange.calendar.component(.day, from: $0) }
        }
        guard let paymentDay else { return status }
        guard let due = dueDates(from: day, until: MonthRange.calendar.date(byAdding: .month, value: 2, to: day)!, day: paymentDay).first,
              final.map({ due <= $0 }) ?? true else { return status }
        status.nextDue = due
        guard let remaining = remaining(terms: terms, due: due, paymentDay: paymentDay), remaining >= 1 else { return status }
        status.remainingInstalments = remaining
        // The instalment of the period the next one falls in, reset at its first instalment
        // from what was owed then (a week before it, so a late previous one is counted).
        let periodRate = periodStart(containing: due, months: terms.revisionMonths)
            .flatMap { rate(periodStart: $0, terms: terms, series: series, overrides: overrides) }
            ?? (terms.rateIndex == .fixed ? rate(periodStart: due, terms: terms, series: series, overrides: overrides) : nil)
        guard let periodRate else { return status }
        let firstDue = dueDates(from: periodRate.start, until: due, day: paymentDay).first ?? due
        let before = MonthRange.calendar.date(byAdding: .day, value: -7, to: firstDue)!
        let conversion = try CurrencyConversion.current(db: db)
        let owed = try PropertyFinance.balance(db: db, property: property, conversion: conversion, accountIds: accountIds, asOf: min(before, day)).native
        guard let firstRemaining = self.remaining(terms: terms, due: firstDue, paymentDay: paymentDay) else { return status }
        let balloon = terms.balloonMinorUnits ?? 0
        if remaining == 1 {
            // The final instalment: everything left with its month's interest.
            let owedNow = try PropertyFinance.balance(db: db, property: property, conversion: conversion, accountIds: accountIds, asOf: day).native
            status.nextInstalmentMinorUnits = owedNow + interest(owed: owedNow, annualRatePercent: periodRate.ratePercent, dayCount: terms.dayCount,
                                                                 previousDue: nil, due: due, rounding: terms.interestRounding)
        } else {
            status.nextInstalmentMinorUnits = instalment(owed: owed, annualRatePercent: periodRate.ratePercent, remaining: firstRemaining, balloon: balloon)
        }
        return status
    }

    // MARK: The bank's history

    /// One instalment as the bank charged it: the transfer into the loan and the interest row
    /// beside it, mapped to the day it was due.
    public struct ChargedInstalment: Equatable, Sendable {
        public var paidOn: Date
        public var due: Date
        public var paidMinorUnits: Int
        /// The interest (and any fee) charged with it, positive.
        public var interestMinorUnits: Int
        /// Owed before it (after the previous instalment), positive.
        public var owedBeforeMinorUnits: Int
    }

    /// The instalments paid into the mortgage accounts, each with the interest charged on its
    /// day (the expense rows on the loan) and what was owed before it, mapped to its due day
    /// (the payment day nearest to when it was paid).
    public static func chargedInstalments(db: Database, propertyId: Int64, paymentDay: Int) throws -> [ChargedInstalment] {
        guard let property = try Property.fetchOne(db, key: propertyId) else { throw PropertyError.propertyNotFound }
        let accountIds = try Properties.accounts(db: db, propertyId: propertyId, role: .mortgage).map(\.accountId)
        let conversion = try CurrencyConversion.current(db: db)
        let expenseIds = Set(try Category.filter(Column("type") == CategoryType.expense.rawValue).fetchAll(db).compactMap(\.id))
        var result: [ChargedInstalment] = []
        for accountId in accountIds {
            let legs = try PropertyCalendar.mortgageLegs(db: db, accountId: accountId, before: .distantFuture)
            for leg in legs {
                let legDay = PropertyDates.day(leg.date)
                let interest = try Transaction.filter(Column("accountId") == accountId && Column("date") >= legDay
                                                      && Column("date") < PropertyDates.nextDay(legDay) && Column("amountMinorUnits") < 0)
                    .fetchAll(db).filter { $0.categoryId.map(expenseIds.contains) ?? false }
                    .reduce(0) { $0 - $1.amountMinorUnits }
                let before = MonthRange.calendar.date(byAdding: .day, value: -1, to: legDay)!
                let owed = try PropertyFinance.balance(db: db, property: property, conversion: conversion, accountIds: [accountId], asOf: before).native
                result.append(ChargedInstalment(paidOn: legDay, due: nearestDue(to: legDay, day: paymentDay), paidMinorUnits: leg.amountMinorUnits,
                                                interestMinorUnits: interest, owedBeforeMinorUnits: owed))
            }
        }
        return result.sorted { $0.paidOn < $1.paidOn }
    }

    /// How far from its due day an instalment's debit can be and still count for it.
    public static let dueDayToleranceDays = 7

    /// The due day an instalment (or the interest charged with it) debited on `paidOn` was
    /// for: the payment day nearest to it (clamped to short months), when it's within
    /// `dueDayToleranceDays`; nil when it's further (not an instalment's). An instalment due on
    /// the 31st and debited on 1 June, the 31st being a Sunday, was May's.
    public static func dueDay(paidOn: Date, paymentDay: Int) -> Date? {
        let day = PropertyDates.day(paidOn)
        let due = nearestDue(to: day, day: paymentDay)
        return abs(PropertyFinance.days(min(due, day), max(due, day))) <= dueDayToleranceDays ? due : nil
    }

    /// The due day each instalment row among `rows` (rows on the mortgage accounts) counts
    /// on, when it isn't its own date. Only instalments shift: a transfer leg into the loan of
    /// about the usual instalment (at most 1.5 × `typicalInstalment`; any size without one)
    /// within `dueDayToleranceDays` of a payment day, and the rows on its account and day that
    /// aren't transfers (the interest charged with it). A fee on another day or an early
    /// repayment (a larger leg) keeps its date.
    public static func instalmentDueDays(rows: [Transaction], transferCategoryIds: Set<Int64>, paymentDay: Int,
                                         typicalInstalment: Int?) -> [Int64: Date] {
        struct Key: Hashable { let accountId: Int64; let day: Date }
        func isTransfer(_ row: Transaction) -> Bool { row.categoryId.map(transferCategoryIds.contains) ?? false }
        var instalmentDays: [Key: Date] = [:]
        var result: [Int64: Date] = [:]
        for row in rows where isTransfer(row) && row.amountMinorUnits > 0 {
            if let typical = typicalInstalment, typical > 0, Double(row.amountMinorUnits) > 1.5 * Double(typical) { continue }
            let day = PropertyDates.day(row.date)
            guard let due = dueDay(paidOn: day, paymentDay: paymentDay) else { continue }
            instalmentDays[Key(accountId: row.accountId, day: day)] = due
            if due != day, let id = row.id { result[id] = due }
        }
        for row in rows where !isTransfer(row) {
            let day = PropertyDates.day(row.date)
            guard let due = instalmentDays[Key(accountId: row.accountId, day: day)], due != day, let id = row.id else { continue }
            result[id] = due
        }
        return result
    }

    /// The median transfer leg into `accountIds`: the usual instalment.
    static func typicalInstalment(db: Database, accountIds: [Int64], transferCategoryIds: Set<Int64>) throws -> Int? {
        guard !accountIds.isEmpty, !transferCategoryIds.isEmpty else { return nil }
        let amounts = try Int.fetchAll(db, Transaction.filter(accountIds.contains(Column("accountId")) && Column("amountMinorUnits") > 0
                                                               && transferCategoryIds.contains(Column("categoryId")))
            .select(Column("amountMinorUnits")).order(Column("amountMinorUnits")))
        return amounts.isEmpty ? nil : amounts[amounts.count / 2]
    }

    /// The payment day (`day` of a month) nearest to `date`.
    public static func nearestDue(to date: Date, day: Int) -> Date {
        let candidates = (-1...1).map { MortgageTerms.dueDate(monthsAfter: $0, from: date, day: day) }
        return candidates.min { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) }!
    }
}

/// The TARGET2 calendar the Euribor is fixed on: weekdays, except 1 January, Good Friday,
/// Easter Monday, 1 May, 25 and 26 December.
public enum TargetCalendar {
    public static func isBusinessDay(_ date: Date) -> Bool {
        let calendar = MonthRange.calendar
        let weekday = calendar.component(.weekday, from: date)
        guard weekday != 1, weekday != 7 else { return false }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        switch (parts.month!, parts.day!) {
        case (1, 1), (5, 1), (12, 25), (12, 26): return false
        default: break
        }
        let easter = easterSunday(parts.year!)
        let day = PropertyDates.day(date)
        return day != calendar.date(byAdding: .day, value: -2, to: easter)! && day != calendar.date(byAdding: .day, value: 1, to: easter)!
    }

    /// The `count`-th business day before `date` (`date` itself when `count` is 0 and it's one).
    public static func businessDay(before date: Date, count: Int) -> Date {
        var day = PropertyDates.day(date)
        var left = count
        if left == 0 {
            while !isBusinessDay(day) { day = MonthRange.calendar.date(byAdding: .day, value: -1, to: day)! }
            return day
        }
        while left > 0 {
            day = MonthRange.calendar.date(byAdding: .day, value: -1, to: day)!
            if isBusinessDay(day) { left -= 1 }
        }
        return day
    }

    /// Easter Sunday (Gregorian; the anonymous algorithm), a UTC midnight.
    public static func easterSunday(_ year: Int) -> Date {
        let a = year % 19, b = year / 100, c = year % 100, d = b / 4, e = b % 4
        let f = (b + 8) / 25, g = (b - f + 1) / 3, h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4, l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31, day = (h + l - 7 * m + 114) % 31 + 1
        return MonthRange.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}

import GRDB
import Foundation

/// The loan before its first imported record, estimated from its terms: from the amount
/// borrowed, instalment by instalment from the first, by the loan's rules (`MortgageRate`):
/// each revision period's rate is the index fixing plus the spread (an override given for the
/// period wins), the instalment resets at the period's first instalment to the annuity over
/// the instalments left that leaves the balloon, and each month's interest is charged by the
/// terms' day count and rounding. The estimate is checked against the first real figure —
/// what the mortgage accounts owed just before the first instalment paid into them (the
/// anchor) — and the gap between the two is reported; the estimated points are adjusted by
/// the gap in proportion to how far along they are, so they start at the amount borrowed and
/// meet the real figure (the chart says so).
public enum MortgageHistory {
    /// One estimated instalment.
    public struct Instalment: Equatable, Sendable {
        /// 1 for the first instalment.
        public var number: Int
        public var due: Date
        public var ratePercent: Double
        public var paidMinorUnits: Int
        public var interestMinorUnits: Int
        /// Owed after it.
        public var owedAfterMinorUnits: Int
    }

    public enum Failure: Error, Equatable {
        /// No amount borrowed, first instalment day, number of instalments or rate rules.
        case missingTerms
        /// The index has no value for the revision period starting on this day.
        case missingFixing(Date)
    }

    /// The instalments 1 to `last` (at most the loan's number) as the rules charge them on
    /// `principal`.
    public static func reconstruct(principal: Int, terms: PropertyMortgageTerms, series: MortgageRate.Series,
                                   overrides: [MortgageRateOverride] = [], through last: Int) throws -> [Instalment] {
        guard principal > 0, let first = terms.firstInstalmentDate, let total = terms.totalInstalments, total >= 1,
              terms.hasRateRules else { throw Failure.missingTerms }
        let balloon = max(0, terms.balloonMinorUnits ?? 0)
        var owed = principal
        var periodStart: Date?
        var rate = 0.0
        var instalment = 0
        var previousDue: Date?
        var result: [Instalment] = []
        for number in stride(from: 1, through: min(last, total), by: 1) {
            let due = MortgageTerms.dueDate(monthsAfter: number - 1, first: first)
            let start = MortgageRate.periodStart(containing: due, months: terms.revisionMonths) ?? PropertyDates.day(first)
            if start != periodStart {
                periodStart = start
                guard let period = MortgageRate.rate(periodStart: start, terms: terms, series: series, overrides: overrides) else {
                    throw Failure.missingFixing(start)
                }
                rate = period.ratePercent
                if number < total {
                    instalment = MortgageRate.instalment(owed: owed, annualRatePercent: rate, remaining: total - number + 1, balloon: balloon) ?? owed
                }
            }
            let interest = MortgageRate.interest(owed: owed, annualRatePercent: rate, dayCount: terms.dayCount, previousDue: previousDue,
                                                 due: due, rounding: terms.interestRounding)
            previousDue = due
            let paid = number == total ? owed + interest : instalment
            owed += interest - paid
            result.append(Instalment(number: number, due: due, ratePercent: rate, paidMinorUnits: paid, interestMinorUnits: interest,
                                     owedAfterMinorUnits: owed))
        }
        return result
    }

    /// The first real figure: what was owed just before instalment `number` (due on `due`).
    public struct Anchor: Equatable, Sendable {
        public var number: Int
        public var due: Date
        /// The day the instalment was paid into the loan.
        public var paidOn: Date
        public var owedBeforeMinorUnits: Int

        public init(number: Int, due: Date, paidOn: Date, owedBeforeMinorUnits: Int) {
            self.number = number
            self.due = due
            self.paidOn = paidOn
            self.owedBeforeMinorUnits = owedBeforeMinorUnits
        }
    }

    /// One point of the estimated history.
    public struct Point: Equatable, Sendable {
        public var date: Date
        public var owedMinorUnits: Int
    }

    /// The history before the anchor, estimated.
    public struct Estimate: Equatable, Sendable {
        public var principalMinorUnits: Int
        /// Instalments 1 to the one before the anchor, as the rules charge them (unadjusted).
        public var instalments: [Instalment]
        public var anchor: Anchor
        /// What the estimate owes before the anchor's instalment (unadjusted).
        public var estimatedOwedBeforeMinorUnits: Int
        /// The real figure less the estimate's: positive when the bank's loan owed more.
        public var gapMinorUnits: Int { anchor.owedBeforeMinorUnits - estimatedOwedBeforeMinorUnits }
        /// The amount borrowed a month before the first instalment, then what's owed after
        /// each instalment to the one before the anchor: adjusted by a small gap in proportion
        /// (the last one meets the real figure), never rising from one to the next; a large
        /// gap (`isLargeGap`) is left as it is, for the chart to show.
        public var points: [Point]
        /// Whether the points were adjusted to meet the real figure.
        public var isAdjusted: Bool
        /// With a large gap: the amount borrowed that would land on the real figure.
        public var suggestedPrincipalMinorUnits: Int?
        /// A gap over `largeGapFraction` of the real figure: the amount borrowed (or the
        /// terms) are probably off.
        public var isLargeGap: Bool { abs(gapFraction) > MortgageHistory.largeGapFraction }
        /// The gap as a share of the real figure.
        public var gapFraction: Double {
            anchor.owedBeforeMinorUnits > 0 ? Double(gapMinorUnits) / Double(anchor.owedBeforeMinorUnits) : 0
        }
    }

    /// A gap larger than this share of the real figure isn't adjusted away: the chart asks
    /// for the amount borrowed to be checked.
    public static let largeGapFraction = 0.02

    /// The estimate up to `anchor`, from `principal`; nil when the anchor is the first instalment.
    public static func estimate(principal: Int, terms: PropertyMortgageTerms, series: MortgageRate.Series,
                                overrides: [MortgageRateOverride] = [], anchor: Anchor) throws -> Estimate? {
        guard anchor.number >= 2, let first = terms.firstInstalmentDate else { return nil }
        let instalments = try reconstruct(principal: principal, terms: terms, series: series, overrides: overrides, through: anchor.number - 1)
        let estimated = instalments.last?.owedAfterMinorUnits ?? principal
        let gap = anchor.owedBeforeMinorUnits - estimated
        let adjusts = gap != 0 && anchor.owedBeforeMinorUnits > 0
            && abs(Double(gap) / Double(anchor.owedBeforeMinorUnits)) <= largeGapFraction
        let steps = Double(instalments.count)
        var points = [Point(date: MortgageTerms.dueDate(monthsAfter: -1, first: first), owedMinorUnits: principal)]
        for (offset, instalment) in instalments.enumerated() {
            let share = adjusts ? Int((Double(gap) * Double(offset + 1) / steps).rounded(.toNearestOrAwayFromZero)) : 0
            // Never rising: a loan repaid by instalments only goes down.
            let owed = min(instalment.owedAfterMinorUnits + share, points.last!.owedMinorUnits)
            points.append(Point(date: instalment.due, owedMinorUnits: owed))
        }
        return Estimate(principalMinorUnits: principal, instalments: instalments, anchor: anchor,
                        estimatedOwedBeforeMinorUnits: estimated, points: points, isAdjusted: adjusts)
    }

    /// The principal whose estimate lands exactly on the anchor (to the cent, the nearest when
    /// none does), searched between half and twice `near`.
    public static func solvePrincipal(near: Int, terms: PropertyMortgageTerms, series: MortgageRate.Series,
                                      overrides: [MortgageRateOverride] = [], anchor: Anchor) throws -> Int {
        func owed(_ principal: Int) throws -> Int {
            try reconstruct(principal: principal, terms: terms, series: series, overrides: overrides, through: anchor.number - 1)
                .last?.owedAfterMinorUnits ?? principal
        }
        var low = max(1, near / 2), high = near * 2
        while high - low > 1 {
            let middle = (low + high) / 2
            if try owed(middle) < anchor.owedBeforeMinorUnits { low = middle } else { high = middle }
        }
        let lowGap = abs(try owed(low) - anchor.owedBeforeMinorUnits), highGap = abs(try owed(high) - anchor.owedBeforeMinorUnits)
        return lowGap <= highGap ? low : high
    }

    // MARK: From the database

    /// The first instalment paid into the mortgage accounts, mapped to its due day, and what
    /// they owed the day before it was paid; nil without one, without the first instalment's
    /// day, or when nothing was owed then (no record before it).
    public static func anchor(db: Database, propertyId: Int64, terms: PropertyMortgageTerms) throws -> Anchor? {
        guard let property = try Property.fetchOne(db, key: propertyId) else { throw PropertyError.propertyNotFound }
        guard let paymentDay = terms.paymentDay else { return nil }
        let accountIds = try Properties.accounts(db: db, propertyId: propertyId, role: .mortgage).map(\.accountId)
        let firstLeg = try accountIds.compactMap { try PropertyCalendar.mortgageLegs(db: db, accountId: $0, before: .distantFuture).first?.date }.min()
        guard let firstLeg else { return nil }
        let paidOn = PropertyDates.day(firstLeg)
        let due = MortgageRate.nearestDue(to: paidOn, day: paymentDay)
        guard let number = terms.instalmentNumber(dueIn: due) else { return nil }
        let before = MonthRange.calendar.date(byAdding: .day, value: -1, to: paidOn)!
        let owed = try PropertyFinance.balance(db: db, property: property, conversion: try CurrencyConversion.current(db: db),
                                               accountIds: accountIds, asOf: before).native
        guard owed > 0 else { return nil }
        return Anchor(number: number, due: due, paidOn: paidOn, owedBeforeMinorUnits: owed)
    }

    /// The property's estimated history before its first record: nil without an amount
    /// borrowed and the rules, an anchor after the first instalment, or the index's values
    /// for every period before it.
    public static func estimate(db: Database, propertyId: Int64) throws -> Estimate? {
        let terms = try MortgageTerms.terms(db: db, propertyId: propertyId)
        guard let principal = terms.amountBorrowedMinorUnits, principal > 0, terms.hasRateRules,
              let anchor = try anchor(db: db, propertyId: propertyId, terms: terms) else { return nil }
        let series = try MortgageRate.series(db: db, terms: terms)
        let overrides = try MortgageRate.overrides(db: db, propertyId: propertyId)
        do {
            guard var result = try estimate(principal: principal, terms: terms, series: series, overrides: overrides, anchor: anchor) else { return nil }
            if result.isLargeGap {
                result.suggestedPrincipalMinorUnits = try solvePrincipal(near: principal, terms: terms, series: series, overrides: overrides, anchor: anchor)
            }
            return result
        } catch is Failure {
            return nil
        }
    }

    // MARK: Progress

    /// How far the loan is repaid.
    public struct Progress: Equatable, Sendable {
        public var borrowedMinorUnits: Int
        public var owedMinorUnits: Int
        public var repaidMinorUnits: Int { max(0, borrowedMinorUnits - owedMinorUnits) }
        /// Repaid ÷ borrowed, 0…1.
        public var fraction: Double { borrowedMinorUnits > 0 ? min(1, max(0, Double(repaidMinorUnits) / Double(borrowedMinorUnits))) : 0 }
        /// Rounded down, so 100% means repaid.
        public var percent: Int { Int((fraction * 100).rounded(.down)) }
        /// The latest instalment due on or before today (0 before the first), and how many in all.
        public var instalmentNumber: Int?
        public var totalInstalments: Int?
    }

    /// The loan's progress on `today`, owing `owed`; nil without an amount borrowed.
    public static func progress(terms: PropertyMortgageTerms, owedMinorUnits owed: Int, today: Date) -> Progress? {
        guard let borrowed = terms.amountBorrowedMinorUnits, borrowed > 0 else { return nil }
        var progress = Progress(borrowedMinorUnits: borrowed, owedMinorUnits: owed, totalInstalments: terms.totalInstalments)
        if let first = terms.firstInstalmentDate, var number = terms.instalmentNumber(dueIn: today) {
            if MortgageTerms.dueDate(monthsAfter: number - 1, first: first) > PropertyDates.day(today) { number -= 1 }
            progress.instalmentNumber = min(max(0, number), terms.totalInstalments ?? Int.max)
        }
        return progress
    }
}

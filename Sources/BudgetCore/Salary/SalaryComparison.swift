import Foundation

/// Two salaries side by side: what the person has now and an offer. Amounts pence.
public struct SalaryComparison: Equatable, Sendable {
    public var current: SalaryResult
    public var offer: SalaryResult
    /// Offer take-home minus current, a month (negative when the offer pays less).
    public var monthlyDifference: Int
    /// Offer take-home minus current, a year.
    public var annualDifference: Int
    /// Of each extra £1 of gross pay on the offer, how much is kept, in basis points (5 800 = 58p).
    public var keepPerExtraPound: Int

    public static func make(current: SalaryResult, offer: SalaryResult) -> SalaryComparison {
        let annual = offer.takeHomeAnnual - current.takeHomeAnnual
        return SalaryComparison(
            current: current, offer: offer,
            monthlyDifference: SalaryCalculator.roundHalfUp(annual, 12),
            annualDifference: annual,
            keepPerExtraPound: offer.keepPerExtraPoundBP)
    }
}

/// Where a year's gross pay goes, for the "where the money goes" bar.
public enum SalaryBarSegments {
    /// Take-home, income tax, NI, loans and the employee pension: they add up to the gross pay.
    public static func segments(_ result: SalaryResult) -> [(label: String, pence: Int)] {
        [
            (label: "Take-home", pence: result.takeHomeAnnual),
            (label: "Income tax", pence: result.incomeTax),
            (label: "National Insurance", pence: result.employeeNI),
            (label: "Loans", pence: result.studentLoan + result.postgraduateLoan),
            (label: "Pension", pence: result.employeePension)
        ]
    }
}

extension SalaryInputs {
    /// The tax year in force on `today`, among the years the rules cover (the earliest when none
    /// has started yet).
    public static func defaultTaxYear(today: Date = Date()) -> Int {
        let years = SalaryRules.all.map(\.startYear).sorted()
        return years.last { UKTaxYear(startYear: $0).start <= today } ?? years[0]
    }

    /// A starting point to edit: £40,000 in the current tax year, England, 1257L.
    public static func typicalCurrent(today: Date = Date()) -> SalaryInputs {
        SalaryInputs(grossAnnual: 4_000_000, taxYearStart: defaultTaxYear(today: today))
    }
}

/// The salary simulator's two columns. The offer starts as a copy of the current salary; the
/// comparison is recomputed whenever either side changes.
@MainActor @Observable
public final class SalaryComparisonViewModel {
    public var current: SalaryInputs { didSet { recompute() } }
    public var offer: SalaryInputs { didSet { recompute() } }
    public private(set) var comparison: SalaryComparison

    public init(current: SalaryInputs = .typicalCurrent(), offer: SalaryInputs? = nil) {
        let offer = offer ?? current
        self.current = current
        self.offer = offer
        comparison = .make(current: SalaryCalculator.calculate(current), offer: SalaryCalculator.calculate(offer))
    }

    /// Whether each side has pay to work from.
    public var ready: (current: Bool, offer: Bool) {
        (current.grossAnnual + current.bonusAnnual > 0, offer.grossAnnual + offer.bonusAnnual > 0)
    }

    /// Back to the starting point: the typical salary on both sides.
    public func reset() {
        let start = SalaryInputs.typicalCurrent()
        current = start
        offer = start
    }

    private func recompute() {
        comparison = .make(current: SalaryCalculator.calculate(current), offer: SalaryCalculator.calculate(offer))
    }
}

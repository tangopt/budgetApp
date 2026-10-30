import SwiftUI
import BudgetCore

/// What the salary calculator decides without drawing (design review §3.4, §5 step 6): which tab, the pinned strip's
/// words, the other unit under a £/% field, the "Where the money goes" rows, and how rows lay out at large sizes.
/// Everything is derived from `SalaryInputs` and `SalaryComparison`; no figure is computed here beyond a unit
/// conversion and a share.
enum SalaryPresentation {
    /// The iPhone's two tabs.
    enum Tab: String, CaseIterable, Identifiable {
        case inputs = "Inputs", results = "Results"
        var id: String { rawValue }
    }

    /// The narrowest width that holds the inputs and the results side by side (the iPad).
    static let sideBySideWidth: CGFloat = 700

    static func showsSideBySide(width: CGFloat) -> Bool { width >= sideBySideWidth }

    /// Rows with two salaries stack (label, then Current over New) from xxxLarge up: two figure columns don't fit beside
    /// a label there, and a figure never wraps or shrinks.
    static func stacksRows(at size: DynamicTypeSize) -> Bool { size >= .xxxLarge }

    // MARK: Pinned strip

    /// "New keeps +£3,120.00 a year"; "New keeps −£480.00 a year" when the new salary leaves less; "New keeps the same a
    /// year" when equal.
    static func stripText(annualDifference: Int) -> String {
        if annualDifference == 0 { return "New keeps the same a year" }
        let amount = MoneyPresentation(minorUnits: abs(annualDifference), currency: .gbp, role: .neutral).text
        return "New keeps \(annualDifference > 0 ? "+" : "\u{2212}")\(amount) a year"
    }

    // MARK: £ and % of the other unit

    /// Under a bonus field: with % chosen "= £5,200.00", with £ chosen "= 12.5%" of the salary.
    static func bonusOtherUnit(_ inputs: SalaryInputs) -> String {
        if inputs.bonusPercentBP != nil { return poundsLine(inputs.bonusPay) }
        return percentLine(inputs.bonusAnnual, of: inputs.grossAnnual)
    }

    /// The same for a pension amount on `gross` (a yearly figure in pence).
    static func pensionOtherUnit(_ amount: PensionAmount, gross: Int) -> String {
        switch amount {
        case .percentOfGross(let bp): poundsLine(roundedShare(max(0, gross), bp))
        case .fixedAnnual(let pence): percentLine(max(0, pence), of: gross)
        }
    }

    private static func poundsLine(_ pence: Int) -> String {
        "= " + MoneyPresentation(minorUnits: pence, currency: .gbp, role: .neutral).text
    }

    private static func percentLine(_ pence: Int, of gross: Int) -> String {
        guard gross > 0, pence > 0 else { return "= 0%" }
        let percent = Double(pence) / Double(gross) * 100
        return "= " + (percent >= 100 ? "100%" : String(format: "%.1f%%", percent).replacingOccurrences(of: ".0%", with: "%"))
    }

    private static func roundedShare(_ pence: Int, _ basisPoints: Int) -> Int {
        (pence * max(0, basisPoints) + 5_000) / 10_000
    }

    // MARK: Where the money goes

    /// One slice of a year's gross pay for both salaries, with the difference (new minus current).
    struct FlowRow: Equatable, Identifiable {
        let label: String
        let current: Int
        let new: Int
        /// This slice's share of the salary's whole year, 0...1.
        let currentShare: Double
        let newShare: Double
        var difference: Int { new - current }
        var id: String { label }
    }

    /// The rows of the comparison: take-home, income tax, National Insurance, loans, pension. A slice neither salary
    /// has is left out. The two shares columns each add up to 1 (a bar is 100%).
    static func flowRows(_ comparison: SalaryComparison) -> [FlowRow] {
        let current = SalaryBarSegments.segments(comparison.current)
        let new = SalaryBarSegments.segments(comparison.offer)
        let currentTotal = max(1, current.reduce(0) { $0 + $1.pence })
        let newTotal = max(1, new.reduce(0) { $0 + $1.pence })
        return zip(current, new).compactMap { c, n in
            guard c.pence > 0 || n.pence > 0 else { return nil }
            return FlowRow(label: c.label, current: c.pence, new: n.pence,
                           currentShare: Double(c.pence) / Double(currentTotal), newShare: Double(n.pence) / Double(newTotal))
        }
    }

    // MARK: Compact choices for the narrow columns

    /// "Monthly" or "June": the Bonus paid picker's label in a column 92 pt wide.
    static func shortBonusPaid(_ payment: BonusPayment) -> String {
        guard let month = payment.month else { return "Monthly" }
        return String(BonusPayment.choices.compactMap { $0.month == month ? $0.label : nil }.first?.dropFirst(3) ?? "")
    }

    static func shortPensionMethod(_ method: PensionMethod) -> String {
        switch method {
        case .salarySacrifice: "Sacrifice"
        case .netPay: "Net pay"
        case .reliefAtSource: "At source"
        }
    }
}

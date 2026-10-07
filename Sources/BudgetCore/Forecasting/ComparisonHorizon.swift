import Foundation

/// How far the scenario lab looks ahead (spec 2026-10-08-scenario-lab-design.md, "Top bar"):
/// to the end of this year, or 2, 5 or 10 years from this month. Default 2 years.
public enum ComparisonHorizon: String, CaseIterable, Identifiable {
    case endOfThisYear
    case twoYears
    case fiveYears
    case tenYears

    public static let `default`: ComparisonHorizon = .twoYears

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .endOfThisYear: return "End of this year"
        case .twoYears: return "2 years"
        case .fiveYears: return "5 years"
        case .tenYears: return "10 years"
        }
    }

    /// The last calendar month shown: December of today's year, or today's calendar month
    /// (UTC) that many years on.
    public func endMonth(today: Date) -> (year: Int, month: Int) {
        let now = MonthRange.components(of: today)
        switch self {
        case .endOfThisYear: return (now.year, 12)
        case .twoYears: return (now.year + 2, now.month)
        case .fiveYears: return (now.year + 5, now.month)
        case .tenYears: return (now.year + 10, now.month)
        }
    }

    /// Every year from today's to the horizon's (the Grid tab's year picker, the summary's
    /// column groups).
    public func years(today: Date) -> [Int] {
        Array(MonthRange.components(of: today).year...endMonth(today: today).year)
    }
}

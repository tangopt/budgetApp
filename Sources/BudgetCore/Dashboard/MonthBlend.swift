import Foundation

public enum MonthClass: Equatable {
    /// Real transactions only.
    case actual
    /// The current calendar month, with some transactions already imported: per category,
    /// the larger of what has happened and what was expected for the whole month.
    case blended
    /// The confirmed forecast only.
    case forecast
}

/// One definition of "which months are real, which are forecast, and what is the current
/// month" for every card on the dashboard.
public enum MonthBlend {
    /// `dataThrough` is the latest transaction date (nil: no data). A clock behind the data
    /// is treated as "today = dataThrough". Months ≤ the data month are `.actual` (the same
    /// rule as the Forecast grid's `isActual`), except the current calendar month, which is
    /// `.blended` when it has data and `.forecast` when it doesn't.
    public static func classify(year: Int, month: Int, dataThrough: Date?, today: Date) -> MonthClass {
        guard let dataThrough else { return .forecast }
        let target = MonthRange.index(year: year, month: month)
        let dataMonth = index(of: dataThrough)
        let todayMonth = index(of: max(today, dataThrough))
        if target == todayMonth && dataMonth == target { return .blended }
        if target <= dataMonth && target != todayMonth { return .actual }
        return .forecast
    }

    /// The projected signed total for one category in a month. For a blended month the
    /// category is treated as an allowance (envelope): income takes the larger of actual
    /// and expected, expense (negative) the larger spend. Transfers are never blended.
    public static func projectedTotal(actual: Int, expected: Int, categoryType: CategoryType, monthClass: MonthClass) -> Int {
        switch monthClass {
        case .actual: return actual
        case .forecast: return expected
        case .blended:
            switch categoryType {
            case .income: return max(actual, expected)
            case .expense: return min(actual, expected)
            case .transfer: return actual
            }
        }
    }

    private static func index(of date: Date) -> Int {
        let parts = MonthRange.components(of: date)
        return MonthRange.index(year: parts.year, month: parts.month)
    }
}

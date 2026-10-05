import Foundation

public enum MonthClass: Equatable {
    /// Real transactions only (a closed pay month).
    case actual
    /// An open pay month that has started: per category, the larger of what has happened
    /// and what was expected for the whole month.
    case blended
    /// The confirmed forecast only.
    case forecast
}

/// How a month's projected total combines actuals and the forecast. Which class a month is
/// comes from `PayCalendar.monthClass`.
public enum MonthBlend {
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
}

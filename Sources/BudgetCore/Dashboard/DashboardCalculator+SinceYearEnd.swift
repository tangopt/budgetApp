import Foundation

/// Net worth today against last December's month end: the iPhone Accounts header's "since December" (iPhone spec
/// §3.6).
public struct NetWorthSinceYearEnd: Equatable, Sendable {
    /// The December's year (today's year − 1).
    public let year: Int
    /// Net worth at the end of that December (`DashboardCalculator.yearEndNetWorth`, actuals only).
    public let yearEndMinorUnits: Int
    /// The net worth given minus `yearEndMinorUnits`.
    public let changeMinorUnits: Int

    public init(year: Int, yearEndMinorUnits: Int, changeMinorUnits: Int) {
        self.year = year
        self.yearEndMinorUnits = yearEndMinorUnits
        self.changeMinorUnits = changeMinorUnits
    }
}

extension DashboardCalculator {
    /// `netWorthMinorUnits` (today's, as the Accounts screen shows it: `AccountsOverview.netWorthGBP`) minus the real
    /// net worth at the end of last December (`yearEndNetWorth(year − 1, includeForecast: false)`). Nil when there is
    /// no December figure (no data before it).
    public static func changeSinceLastYearEnd(_ input: DashboardInput, netWorthMinorUnits: Int) -> NetWorthSinceYearEnd? {
        let year = MonthRange.components(of: input.today).year - 1
        guard let yearEnd = yearEndNetWorth(input, year: year, includeForecast: false) else { return nil }
        return NetWorthSinceYearEnd(year: year, yearEndMinorUnits: yearEnd.valueMinorUnits,
                                    changeMinorUnits: netWorthMinorUnits - yearEnd.valueMinorUnits)
    }
}

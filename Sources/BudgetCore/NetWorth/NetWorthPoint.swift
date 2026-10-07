import Foundation

/// A net worth value (GBP minor units) at the end of a calendar month.
public struct NetWorthPoint: Equatable, Identifiable, Sendable {
    public let year: Int
    public let month: Int
    public let valueMinorUnits: Int

    public init(year: Int, month: Int, valueMinorUnits: Int) {
        self.year = year
        self.month = month
        self.valueMinorUnits = valueMinorUnits
    }

    public var id: Int { MonthRange.index(year: year, month: month) }
}

import Foundation

public struct ParsedTransaction: Equatable {
    public let date: Date
    public let rawDescription: String
    public let amountMinorUnits: Int
    /// The statement's running balance immediately after this row, when the statement has
    /// a Balance column that was mapped and readable. `nil` otherwise (always for PDFs).
    public let balanceAfterMinorUnits: Int?

    public init(date: Date, rawDescription: String, amountMinorUnits: Int, balanceAfterMinorUnits: Int? = nil) {
        self.date = date
        self.rawDescription = rawDescription
        self.amountMinorUnits = amountMinorUnits
        self.balanceAfterMinorUnits = balanceAfterMinorUnits
    }
}

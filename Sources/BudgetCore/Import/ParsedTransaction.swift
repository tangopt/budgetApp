import Foundation

public struct ParsedTransaction: Equatable {
    public let date: Date
    public let rawDescription: String
    public let amountMinorUnits: Int

    public init(date: Date, rawDescription: String, amountMinorUnits: Int) {
        self.date = date
        self.rawDescription = rawDescription
        self.amountMinorUnits = amountMinorUnits
    }
}

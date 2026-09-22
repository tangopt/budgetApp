// Sources/BudgetCore/Import/PDFLayoutConfig.swift
import Foundation

public struct PDFLayoutConfig: Codable, Equatable {
    /// Must contain exactly 3 capture groups, in order: date, description, amount.
    /// The line is expected to optionally end in "DR" (debit, negative) or "CR" (credit, positive);
    /// absence of a suffix is treated as a debit.
    public let regexPattern: String
    public let dateFormat: String

    public init(regexPattern: String, dateFormat: String) {
        self.regexPattern = regexPattern
        self.dateFormat = dateFormat
    }

    public func encoded() throws -> String {
        String(data: try JSONEncoder().encode(self), encoding: .utf8)!
    }

    public static func decode(_ json: String) throws -> PDFLayoutConfig {
        try JSONDecoder().decode(PDFLayoutConfig.self, from: Data(json.utf8))
    }
}

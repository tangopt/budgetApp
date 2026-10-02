// Sources/BudgetCore/Import/CSVColumnSuggester.swift
import Foundation

/// A best-guess CSV column mapping derived from a statement's header row.
public struct CSVColumnSuggestion: Equatable {
    public var dateColumn: Int?
    public var descriptionColumn: Int?
    /// The single signed amount column — or the debit (money out) column when
    /// `creditColumn` is also set.
    public var amountColumn: Int?
    public var creditColumn: Int?
    public var balanceColumn: Int?

    public init(dateColumn: Int? = nil, descriptionColumn: Int? = nil, amountColumn: Int? = nil, creditColumn: Int? = nil, balanceColumn: Int? = nil) {
        self.dateColumn = dateColumn
        self.descriptionColumn = descriptionColumn
        self.amountColumn = amountColumn
        self.creditColumn = creditColumn
        self.balanceColumn = balanceColumn
    }

    public var hasSeparateDebitCredit: Bool { creditColumn != nil }
}

public enum CSVColumnSuggester {
    /// Matches header names case-insensitively. Amount-like headers are classified in a
    /// fixed order (balance, credit, debit, amount) so overlapping words resolve
    /// correctly — e.g. "Debit Amount" is a debit column, not an amount column.
    public static func suggest(header: [String]) -> CSVColumnSuggestion {
        let lowered = header.map { $0.lowercased() }
        var suggestion = CSVColumnSuggestion()
        var debitColumn: Int?
        var creditColumn: Int?
        var amountOnlyColumn: Int?

        for (index, name) in lowered.enumerated() {
            if name.contains("balance") {
                if suggestion.balanceColumn == nil { suggestion.balanceColumn = index }
            } else if ["credit", "paid in", "money in"].contains(where: { name.contains($0) }) {
                if creditColumn == nil { creditColumn = index }
            } else if ["debit", "paid out", "money out", "withdrawal"].contains(where: { name.contains($0) }) {
                if debitColumn == nil { debitColumn = index }
            } else if name.contains("amount") {
                if amountOnlyColumn == nil { amountOnlyColumn = index }
            }
        }

        if let debitColumn, let creditColumn {
            suggestion.amountColumn = debitColumn
            suggestion.creditColumn = creditColumn
        } else if let amountOnlyColumn {
            suggestion.amountColumn = amountOnlyColumn
        }

        let dateIndices = lowered.indices.filter { lowered[$0].contains("date") }
        suggestion.dateColumn = dateIndices.first { lowered[$0].contains("transaction") } ?? dateIndices.first

        for keyword in ["description", "details", "narrative", "payee", "reference"] {
            if let index = lowered.firstIndex(where: { $0.contains(keyword) }) {
                suggestion.descriptionColumn = index
                break
            }
        }
        return suggestion
    }
}

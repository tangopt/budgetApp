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
    /// A fee charged on top of the amount (e.g. Revolut's "Fee").
    public var feeColumn: Int?
    /// Each row's state (e.g. Revolut's "State": COMPLETED, PENDING, REVERTED).
    public var statusColumn: Int?
    /// The account's sort code on each row (Lloyds' "Sort Code").
    public var sortCodeColumn: Int?
    /// The account's number on each row (Lloyds' "Account Number").
    public var accountNumberColumn: Int?

    public init(dateColumn: Int? = nil, descriptionColumn: Int? = nil, amountColumn: Int? = nil, creditColumn: Int? = nil, balanceColumn: Int? = nil,
                feeColumn: Int? = nil, statusColumn: Int? = nil, sortCodeColumn: Int? = nil, accountNumberColumn: Int? = nil) {
        self.dateColumn = dateColumn
        self.descriptionColumn = descriptionColumn
        self.amountColumn = amountColumn
        self.creditColumn = creditColumn
        self.balanceColumn = balanceColumn
        self.feeColumn = feeColumn
        self.statusColumn = statusColumn
        self.sortCodeColumn = sortCodeColumn
        self.accountNumberColumn = accountNumberColumn
    }

    public var hasSeparateDebitCredit: Bool { creditColumn != nil }
}

public enum CSVColumnSuggester {
    /// Matches header names case-insensitively. Amount-like headers are classified in a
    /// fixed order (balance, credit, debit, amount) so overlapping words resolve
    /// correctly — e.g. "Debit Amount" is a debit column, not an amount column. Fee and status
    /// columns match whole words only ("Fee"/"Fees", "State"/"Status"), so "Coffee" or
    /// "Statement" don't. With several date columns ("Started Date", "Completed Date") the
    /// first is chosen unless one says "transaction".
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
            } else if words(name).contains(where: { $0 == "fee" || $0 == "fees" }) {
                if suggestion.feeColumn == nil { suggestion.feeColumn = index }
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

        suggestion.statusColumn = lowered.firstIndex { words($0).contains(where: { $0 == "state" || $0 == "status" }) }
        suggestion.sortCodeColumn = sortCodeColumn(header: header)
        suggestion.accountNumberColumn = accountNumberColumn(header: header)

        for keyword in ["description", "details", "narrative", "payee", "reference"] {
            if let index = lowered.firstIndex(where: { $0.contains(keyword) }) {
                suggestion.descriptionColumn = index
                break
            }
        }
        return suggestion
    }

    /// "Sort Code", "Sort code", "Sortcode" (case-insensitive, whole header).
    public static func sortCodeColumn(header: [String]) -> Int? {
        header.firstIndex { squashed($0) == "sortcode" }
    }

    /// "Account Number", "Account No", "Account No.", "Account" (case-insensitive, whole
    /// header) — never "Account Name".
    public static func accountNumberColumn(header: [String]) -> Int? {
        header.firstIndex { ["accountnumber", "accountno", "account"].contains(squashed($0)) }
    }

    /// Lowercased letters and digits only: "Account No." → "accountno".
    private static func squashed(_ name: String) -> String {
        String(name.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func words(_ name: String) -> [Substring] {
        name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    }
}

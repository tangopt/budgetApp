// App/Import/NonGBPImportCaption.swift
import SwiftUI
import BudgetCore

/// A non-GBP account's statement is stored in its own currency; budgets and net worth convert
/// it at the stored rate (`CurrencyConversion`, `NetWorthCalculator`). Importing into one gets
/// this neutral note, shown under the dashboard import card's account picker.
struct NonGBPImportCaption: View {
    let account: Account?
    /// The stored EUR→GBP rate (`ExchangeRateSetting`).
    let eurToGbpRate: Double

    var body: some View {
        if let account, account.currency != .gbp {
            Text(Self.text(currency: account.currency, eurToGbpRate: eurToGbpRate))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func text(currency: Currency, eurToGbpRate: Double) -> String {
        "Amounts are kept in \(currency.rawValue.uppercased()) and converted to GBP at \(String(format: "%.4f", eurToGbpRate)) for budgets and net worth."
    }
}

// App/Import/CSVMappingPreview.swift
import SwiftUI
import BudgetCore

/// The first parsed transactions, exactly as the import would read them with the draft
/// mapping — so a wrong sign or date format shows up before anything is saved.
struct CSVMappingPreview: View {
    let transactions: [ParsedTransaction]
    let currency: Currency
    let showsBalance: Bool

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // Statement dates are parsed as UTC midnight (see StatementDateFormatter).
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Result preview")
                .font(.headline)
            if transactions.isEmpty {
                Text("Nothing to preview yet.")
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        Text("Date")
                        Text("Description").gridColumnAlignment(.leading)
                        Text("Amount").gridColumnAlignment(.trailing)
                        if showsBalance { Text("Balance").gridColumnAlignment(.trailing) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ForEach(transactions.indices, id: \.self) { index in
                        let transaction = transactions[index]
                        GridRow {
                            Text(Self.dayFormatter.string(from: transaction.date))
                                .monospacedDigit()
                            Text(transaction.rawDescription)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            MoneyText(minorUnits: transaction.amountMinorUnits, currency: currency)
                            if showsBalance {
                                if let balance = transaction.balanceAfterMinorUnits {
                                    Text(Money.format(balance, currency: currency))
                                        .monospacedDigit()
                                } else {
                                    Text("—").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
